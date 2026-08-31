import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:path_provider/path_provider.dart';

import 'api_service.dart';
import 'config_service.dart';
import 'license_service.dart';

/// Jenis berkas yang bisa diantre.
enum UploadKind { photo, finalStrip, gif, video }

/// Antrean unggahan yang tahan mati listrik.
///
/// Sebelum ini setiap unggahan bersifat *fire & forget*: kalau gagal, hanya
/// dicatat ke debug log lalu dilupakan. Akibatnya foto pelanggan bisa hilang
/// dari server padahal filenya aman di laptop — dari 7 sesi berbayar sejak
/// 21 Agustus 2026, 3 di antaranya tidak punya satu foto pun di database.
///
/// Cara kerja:
///   1. Berkas yang gagal diunggah disalin ke folder staging supaya tetap ada
///      walau sumbernya di direktori sementara yang bisa dibersihkan Windows.
///   2. Pekerjaannya dicatat di `queue.json`, jadi antrean selamat saat aplikasi
///      ditutup atau laptop mati.
///   3. Satu pekerja mencoba ulang satu per satu dengan jeda menaik, supaya
///      tidak merebut bandwidth saat sesi berikutnya sedang berjalan.
class UploadQueueService {
  UploadQueueService._();
  static final UploadQueueService instance = UploadQueueService._();

  static const Duration _tickInterval = Duration(seconds: 15);

  /// Jeda sebelum percobaan berikutnya, menaik lalu mentok di 30 menit.
  static const List<Duration> _backoff = [
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(minutes: 2),
    Duration(minutes: 5),
    Duration(minutes: 15),
    Duration(minutes: 30),
  ];

  /// Setelah selama ini masih gagal, pekerjaan dilepas supaya antrean tidak
  /// menumpuk selamanya. Sesi sudah lewat berhari-hari; operator lebih baik
  /// menanganinya lewat jalur pengaduan.
  static const Duration _maxAge = Duration(days: 7);

  final List<_UploadJob> _jobs = [];
  Directory? _dir;
  Timer? _timer;
  bool _busy = false;
  bool _started = false;

  /// Dipanggil saat strip final berhasil diunggah menyusul, supaya QR unduh
  /// tetap bisa dipakai walau unggahannya baru berhasil belakangan.
  void Function(String sessionUuid, String? resultUrl)? onFinalUploaded;

  int get pendingCount => _jobs.length;

  // ── Siklus hidup ───────────────────────────────────────────────────────

  /// Panggil sekali saat aplikasi start.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      await _load();
      if (_jobs.isNotEmpty) {
        debugPrint('[QUEUE] ${_jobs.length} unggahan tertunda dari sesi sebelumnya.');
      }
    } catch (e) {
      debugPrint('[QUEUE] Gagal memuat antrean: $e');
    }
    _timer ??= Timer.periodic(_tickInterval, (_) => _drain());
    unawaited(_drain());
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _started = false;
  }

  // ── Menambah pekerjaan ─────────────────────────────────────────────────

  /// Antre satu berkas. `sourcePath` disalin dulu, jadi pemanggil bebas
  /// menghapus berkas aslinya.
  Future<void> enqueue({
    required UploadKind kind,
    required String sessionUuid,
    required String sourcePath,
    int? photoOrder,
  }) async {
    if (sessionUuid.isEmpty) {
      debugPrint('[QUEUE] Dilewati: session_uuid kosong.');
      return;
    }
    try {
      final source = File(sourcePath);
      if (!await source.exists()) {
        debugPrint('[QUEUE] Dilewati: berkas tidak ada — $sourcePath');
        return;
      }

      final dir = await _stagingDir();
      final id = '${DateTime.now().millisecondsSinceEpoch}_'
          '${kind.name}_${photoOrder ?? 0}';
      final staged = File('${dir.path}/$id${_extFor(kind)}');
      await source.copy(staged.path);

      // Satu berkas per (sesi, jenis, urutan) — kalau sebuah foto diantre dua
      // kali, yang lama dibuang supaya server tidak menerima duplikat.
      _jobs.removeWhere((j) {
        final same = j.sessionUuid == sessionUuid &&
            j.kind == kind &&
            j.photoOrder == photoOrder;
        if (same) unawaited(_deleteStaged(j.stagedPath));
        return same;
      });

      _jobs.add(_UploadJob(
        id: id,
        kind: kind,
        sessionUuid: sessionUuid,
        stagedPath: staged.path,
        photoOrder: photoOrder,
        createdAt: DateTime.now(),
        nextAttemptAt: DateTime.now().add(_backoff.first),
      ));
      await _save();
      debugPrint('[QUEUE] Diantre: ${kind.name} sesi $sessionUuid '
          '(total ${_jobs.length}).');
    } catch (e) {
      debugPrint('[QUEUE] Gagal mengantre: $e');
    }
  }

  // ── Pekerja ────────────────────────────────────────────────────────────

  Future<void> _drain() async {
    if (_busy || _jobs.isEmpty) return;
    _busy = true;
    try {
      final now = DateTime.now();

      // Buang yang sudah terlalu tua sebelum mencoba lagi.
      final expired = _jobs.where((j) => now.difference(j.createdAt) > _maxAge).toList();
      for (final job in expired) {
        debugPrint('[QUEUE] Menyerah setelah ${_maxAge.inDays} hari: '
            '${job.kind.name} sesi ${job.sessionUuid}');
        await _reportGaveUp(job);
        await _remove(job);
      }

      final due = _jobs.firstWhereOrNull((j) => !j.nextAttemptAt.isAfter(now));
      if (due == null) return;

      final ok = await _send(due);
      if (ok) {
        await _remove(due);
        debugPrint('[QUEUE] Berhasil menyusul: ${due.kind.name} '
            'sesi ${due.sessionUuid} (sisa ${_jobs.length}).');
      } else {
        due.attempts += 1;
        final wait = _backoff[due.attempts.clamp(0, _backoff.length - 1)];
        due.nextAttemptAt = DateTime.now().add(wait);
        await _save();
        debugPrint('[QUEUE] Percobaan ${due.attempts} gagal untuk '
            '${due.kind.name}; coba lagi dalam ${wait.inSeconds}s.');
      }
    } catch (e) {
      debugPrint('[QUEUE] Kesalahan pekerja: $e');
    } finally {
      _busy = false;
    }
  }

  Future<bool> _send(_UploadJob job) async {
    try {
      final file = File(job.stagedPath);
      if (!await file.exists()) {
        debugPrint('[QUEUE] Berkas staging hilang, pekerjaan dibuang: ${job.stagedPath}');
        return true; // tidak ada gunanya dicoba lagi
      }

      final hwid = await LicenseService().getHardwareId();
      if (hwid.isEmpty) {
        debugPrint('[QUEUE] HWID kosong, tunda.');
        return false;
      }

      final uri = Uri.parse('${ConfigService().baseUrl}${_pathFor(job.kind)}');
      final request = http.MultipartRequest('POST', uri)
        ..fields['session_uuid'] = job.sessionUuid
        ..fields['hwid'] = hwid;
      if (job.photoOrder != null) {
        request.fields['photo_order'] = job.photoOrder.toString();
      }
      request.files.add(await http.MultipartFile.fromPath(
        _fieldFor(job.kind),
        job.stagedPath,
        contentType: _mimeFor(job.kind),
      ));

      // Batas waktu dipasang pada KEDUA tahap. Kalau hanya pembacaan respons
      // yang dibatasi, koneksi yang menggantung saat mengirim akan menahan
      // `_busy` selamanya dan seluruh antrean ikut membeku.
      const limit = Duration(minutes: 3);
      final streamed = await request.send().timeout(limit);
      final response =
          await http.Response.fromStream(streamed).timeout(limit);

      if (response.statusCode == 200 || response.statusCode == 201) {
        if (job.kind == UploadKind.finalStrip) {
          String? url;
          try {
            url = jsonDecode(response.body)['url'] as String?;
          } catch (_) {}
          onFinalUploaded?.call(job.sessionUuid, url);
        }
        return true;
      }

      // Sesi tidak dikenal / berkas ditolak: mencoba lagi tidak akan menolong.
      if (response.statusCode == 400 || response.statusCode == 404) {
        debugPrint('[QUEUE] Ditolak permanen (${response.statusCode}) untuk '
            '${job.kind.name} sesi ${job.sessionUuid}: ${response.body}');
        await _reportGaveUp(job);
        return true;
      }

      debugPrint('[QUEUE] Server menjawab ${response.statusCode}.');
      return false;
    } catch (e) {
      debugPrint('[QUEUE] Gagal mengirim: $e');
      return false;
    }
  }

  /// GIF & video punya penanda status di database supaya halaman unduh tahu
  /// harus berhenti menunggu. Baru ditandai gagal saat antrean benar-benar
  /// menyerah — selama masih diantre, statusnya biarkan 'processing'.
  Future<void> _reportGaveUp(_UploadJob job) async {
    if (job.kind != UploadKind.gif && job.kind != UploadKind.video) return;
    try {
      final hwid = await LicenseService().getHardwareId();
      if (hwid.isEmpty) return;
      await ApiService().setMediaStatus(
        sessionUuid: job.sessionUuid,
        hwid: hwid,
        gifStatus: job.kind == UploadKind.gif ? 'failed' : null,
        videoStatus: job.kind == UploadKind.video ? 'failed' : null,
      );
    } catch (_) {
      // Penanda status bukan alasan untuk menggagalkan pembersihan antrean.
    }
  }

  // ── Penyimpanan ────────────────────────────────────────────────────────

  Future<Directory> _stagingDir() async {
    if (_dir != null) return _dir!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/Photobooth/_upload_queue');
    if (!await dir.exists()) await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  File _queueFile(Directory dir) => File('${dir.path}/queue.json');

  Future<void> _load() async {
    final dir = await _stagingDir();
    final file = _queueFile(dir);
    if (!await file.exists()) return;
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return;
    final list = jsonDecode(raw) as List<dynamic>;
    _jobs
      ..clear()
      ..addAll(list
          .map((e) => _UploadJob.fromJson(e as Map<String, dynamic>))
          .whereType<_UploadJob>());
  }

  Future<void> _save() async {
    try {
      final dir = await _stagingDir();
      await _queueFile(dir)
          .writeAsString(jsonEncode(_jobs.map((j) => j.toJson()).toList()));
    } catch (e) {
      debugPrint('[QUEUE] Gagal menyimpan antrean: $e');
    }
  }

  Future<void> _remove(_UploadJob job) async {
    _jobs.remove(job);
    await _deleteStaged(job.stagedPath);
    await _save();
  }

  Future<void> _deleteStaged(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  // ── Peta per jenis ─────────────────────────────────────────────────────

  static String _pathFor(UploadKind k) => switch (k) {
        UploadKind.photo => '/api/photobooth/upload',
        UploadKind.finalStrip => '/api/photobooth/upload/final',
        UploadKind.gif => '/api/photobooth/upload/gif',
        UploadKind.video => '/api/photobooth/upload/video',
      };

  static String _fieldFor(UploadKind k) => switch (k) {
        UploadKind.photo || UploadKind.finalStrip => 'photo',
        UploadKind.gif => 'gif',
        UploadKind.video => 'video',
      };

  static MediaType _mimeFor(UploadKind k) => switch (k) {
        UploadKind.photo => MediaType('image', 'jpeg'),
        UploadKind.finalStrip => MediaType('image', 'png'),
        UploadKind.gif => MediaType('image', 'gif'),
        UploadKind.video => MediaType('video', 'mp4'),
      };

  static String _extFor(UploadKind k) => switch (k) {
        UploadKind.photo => '.jpg',
        UploadKind.finalStrip => '.png',
        UploadKind.gif => '.gif',
        UploadKind.video => '.mp4',
      };
}

class _UploadJob {
  _UploadJob({
    required this.id,
    required this.kind,
    required this.sessionUuid,
    required this.stagedPath,
    required this.createdAt,
    required this.nextAttemptAt,
    this.photoOrder,
    this.attempts = 0,
  });

  final String id;
  final UploadKind kind;
  final String sessionUuid;
  final String stagedPath;
  final int? photoOrder;
  final DateTime createdAt;
  int attempts;
  DateTime nextAttemptAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'session_uuid': sessionUuid,
        'staged_path': stagedPath,
        'photo_order': photoOrder,
        'created_at': createdAt.toIso8601String(),
        'next_attempt_at': nextAttemptAt.toIso8601String(),
        'attempts': attempts,
      };

  static _UploadJob? fromJson(Map<String, dynamic> j) {
    try {
      return _UploadJob(
        id: j['id'] as String,
        kind: UploadKind.values.firstWhere((k) => k.name == j['kind']),
        sessionUuid: j['session_uuid'] as String,
        stagedPath: j['staged_path'] as String,
        photoOrder: j['photo_order'] as int?,
        createdAt: DateTime.parse(j['created_at'] as String),
        nextAttemptAt: DateTime.parse(j['next_attempt_at'] as String),
        attempts: (j['attempts'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

extension _FirstWhereOrNull<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
