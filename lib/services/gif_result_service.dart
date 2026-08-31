import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../providers/photo_provider.dart';
import 'api_service.dart';
import 'config_service.dart';
import 'upload_queue_service.dart';

// ================================================================
// GIF RESULT SERVICE
// Merakit GIF animasi dari foto-foto sesi, lalu mengunggahnya.
//
// Berbeda dengan video: GIF dirakit dari foto, bukan klip rekaman, jadi tetap
// bisa dibuat walau perekaman video gagal. Encoding dijalankan di isolate
// supaya UI tidak membeku.
// ================================================================

/// Lebar target GIF. Foto asli bisa >1000px; menurunkannya ke 480px memangkas
/// waktu kuantisasi warna dan ukuran file secara drastis, sementara di layar
/// HP pelanggan perbedaannya nyaris tidak terlihat.
const int _kGifWidth = 480;

/// Durasi per frame dalam 1/100 detik — disamakan dengan pratinjau di layar
/// mesin (900 ms) supaya hasil unduhan terasa sama dengan yang dilihat.
const int _kFrameDurationCs = 90;

/// Encoding GIF di isolate terpisah. Harus top-level agar bisa dipakai compute.
Uint8List? _encodeGifInIsolate(Map<String, dynamic> args) {
  final List<Uint8List> frames = (args['frames'] as List).cast<Uint8List>();
  final int targetWidth = args['width'] as int;
  final int durationCs = args['durationCs'] as int;

  // Octree jauh lebih cepat daripada quantizer neural bawaan, dan tanpa dither
  // prosesnya lebih ringan lagi — penting karena mesin photobooth menjalankan
  // ini bersamaan dengan render foto dan komposit video.
  final encoder = img.GifEncoder(
    repeat: 0,
    numColors: 256,
    quantizerType: img.QuantizerType.octree,
    dither: img.DitherKernel.none,
  );

  var added = 0;
  for (final raw in frames) {
    final decoded = img.decodeImage(raw);
    if (decoded == null) continue;

    final frame = decoded.width > targetWidth
        ? img.copyResize(decoded,
            width: targetWidth, interpolation: img.Interpolation.average)
        : decoded;

    encoder.addFrame(frame, duration: durationCs);
    added++;
  }

  if (added == 0) return null;
  return encoder.finish();
}

class GifResultService {
  static final String _backendUrl = ConfigService().baseUrl;

  /// Pastikan GIF sesuai filter terkini. Aman dipanggil berkali-kali.
  static Future<void> ensure(PhotoProvider provider,
      {bool upload = true}) async {
    if (!provider.canBuildGif) return;
    if (provider.gifProcessing) return;
    // Sudah sesuai filter terkini → tidak perlu rakit ulang.
    if (provider.finalGifPath != null &&
        provider.finalGifFilter == provider.selectedFilter) {
      return;
    }

    // Snapshot diambil SEBELUM await apa pun — dan sebelum flag processing
    // dinyalakan, supaya keluar lebih awal tidak meninggalkan flag yang macet.
    // Timer sesi bisa habis kapan saja dan memicu PhotoProvider.reset() yang
    // mengosongkan daftar foto; kalau disalin setelah panggilan jaringan di
    // bawah, daftarnya bisa keburu kosong dan GIF gagal tanpa pesan error.
    // imageData sudah berisi hasil ber-filter, jadi GIF otomatis mengikuti
    // filter yang dipilih pelanggan.
    final filter = provider.selectedFilter;
    final frames = provider.photos.map((p) => p.imageData).toList();
    if (frames.length < 2) return;

    provider.setGifProcessing(true);
    final sw = Stopwatch()..start();
    var reachedUpload = false;

    try {
      await _reportStatus(provider, 'processing');

      final bytes = await compute(_encodeGifInIsolate, <String, dynamic>{
        'frames': frames,
        'width': _kGifWidth,
        'durationCs': _kFrameDurationCs,
      });

      if (bytes == null || bytes.isEmpty) {
        debugPrint('[GIF] Encoding tidak menghasilkan data.');
        return;
      }

      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/gif_${DateTime.now().millisecondsSinceEpoch}.gif');
      await file.writeAsBytes(bytes);

      debugPrint('[GIF] Selesai dirakit: ${(bytes.length / 1024).round()} KB '
          'dalam ${sw.elapsedMilliseconds} ms');

      provider.setFinalGif(file.path, filter);
      if (upload) {
        reachedUpload = true;
        await _upload(provider, file.path);
      }
    } catch (e) {
      debugPrint('[GIF] ensure error: $e');
    } finally {
      provider.setGifProcessing(false);
      // Upload yang sukses sudah menandai 'ready' dari sisi server; kalau
      // encoding gagal sebelum sampai tahap upload, status jangan dibiarkan
      // menggantung di 'processing'.
      if (!reachedUpload) await _reportStatus(provider, 'failed');
    }

    // Filter sempat berubah saat encoding berjalan → rakit ulang sekali.
    if (provider.finalGifFilter != provider.selectedFilter) {
      await ensure(provider, upload: upload);
    }
  }

  static Future<void> _reportStatus(PhotoProvider provider, String status) async {
    try {
      if (provider.sessionUuid.isEmpty) return;
      if (provider.machineId.isEmpty) await provider.initMachineId();
      if (provider.machineId.isEmpty) return;
      await ApiService().setMediaStatus(
        sessionUuid: provider.sessionUuid,
        hwid: provider.machineId,
        gifStatus: status,
      );
    } catch (_) {
      // Transparansi UI tidak boleh menggagalkan perakitan GIF.
    }
  }

  static Future<void> _upload(PhotoProvider provider, String path) async {
    try {
      if (provider.sessionUuid.isEmpty) return;
      if (provider.machineId.isEmpty) await provider.initMachineId();
      final hwid = provider.machineId;
      if (hwid.isEmpty) return;

      final uri = Uri.parse('$_backendUrl/api/photobooth/upload/gif');
      final request = http.MultipartRequest('POST', uri)
        ..fields['session_uuid'] = provider.sessionUuid
        ..fields['hwid'] = hwid
        ..files.add(await http.MultipartFile.fromPath('gif', path,
            contentType: MediaType('image', 'gif')));

      final streamed = await request.send();
      final response = await http.Response.fromStream(streamed);

      if (response.statusCode == 200 || response.statusCode == 201) {
        debugPrint('[GIF] Upload berhasil.');
      } else {
        debugPrint('[GIF] Upload gagal: ${response.statusCode}');
        await _queueRetry(provider, path);
      }
    } catch (e) {
      debugPrint('[GIF] Upload error: $e');
      await _queueRetry(provider, path);
    }
  }

  /// Statusnya sengaja dibiarkan 'processing', bukan langsung 'failed':
  /// selama masih ada di antrean, hasilnya masih mungkin sampai. Antrean
  /// sendiri yang menandai 'failed' kalau akhirnya menyerah.
  static Future<void> _queueRetry(PhotoProvider provider, String path) async {
    await UploadQueueService.instance.enqueue(
      kind: UploadKind.gif,
      sessionUuid: provider.sessionUuid,
      sourcePath: path,
    );
  }
}
