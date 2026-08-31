import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'video_composer.dart';
import 'image_filter.dart';
import '../providers/photo_provider.dart';

// ================================================================
// PHOTO PROCESSOR
//
// Mengolah foto mentah dari kamera menjadi "base image" yang dipakai app:
// mirror (selfie) + batasi sisi terpanjang ke 3000px. TANPA color filter —
// filter dipilih belakangan di PreviewPage dari base ini.
//
// KENAPA ADA FILE INI (diukur 2026-08-24, foto DSLR 18MP 5184x3456):
//
//   package:image (Dart murni)          ffmpeg (native C)
//   ─────────────────────────────       ─────────────────
//   decode      2768ms                  seluruh rangkaian
//   resize       260ms                  pipe→pipe: ~860ms
//   flip         558ms
//   encode q98  1771ms
//   TOTAL       5361ms                  TOTAL      ~860ms
//
// Selisihnya ~6x, dan inilah penyumbang terbesar "jeda setelah jepret"
// (sebagai pembanding, kameranya sendiri hanya butuh ~1 detik: shutter
// 900ms + transfer USB 130ms).
//
// ffmpeg.exe sudah di-bundle untuk fitur video, jadi tidak ada dependensi
// baru. Tapi kalau karena satu dan lain hal ffmpeg tidak ada / gagal,
// kita JATUH KEMBALI ke package:image — foto jauh lebih penting daripada
// kecepatan, jadi jalur ini tidak boleh bikin sesi gagal.
// ================================================================
class PhotoProcessor {
  // Sisi terpanjang hasil akhir. 3000px pada cetak 4R ≈ 500 DPI, jauh di
  // atas kebutuhan cetak (300 DPI). Samakan dengan batas di
  // ImageFilterUtil.applyFilterSync agar kedua jalur konsisten.
  static const int maxSide = 3000;

  // Kualitas JPEG keluaran ffmpeg (skala -q:v, 1 = terbaik).
  // 2 sudah setara "visually lossless" untuk cetak dan menghasilkan file
  // ~4x lebih kecil dari encode q98 package:image → upload pun lebih cepat.
  static const String ffmpegQuality = '2';

  static bool _ffmpegUsable = true; // dimatikan setelah gagal sekali

  // Hasilkan base image. Selalu mengembalikan bytes yang bisa dipakai:
  // ffmpeg bila bisa, kalau tidak package:image.
  static Future<Uint8List> makeBase(Uint8List raw) async {
    if (_ffmpegUsable) {
      final sw = Stopwatch()..start();
      final out = await _viaFfmpeg(raw);
      if (out != null) {
        debugPrint('[PhotoProcessor] ffmpeg ${sw.elapsedMilliseconds}ms '
            '(${raw.length ~/ 1024}KB → ${out.length ~/ 1024}KB)');
        return out;
      }
      debugPrint('[PhotoProcessor] ffmpeg gagal → pakai package:image '
          '(lebih lambat) untuk seterusnya di sesi ini.');
      _ffmpegUsable = false;
    }
    return ImageFilterUtil.applyFilter(raw, PhotoFilter.none);
  }

  static Future<Uint8List?> _viaFfmpeg(Uint8List raw) async {
    final exe = VideoComposer.resolveFfmpeg();
    try {
      final p = await Process.start(exe, [
        '-y',
        '-hide_banner',
        '-loglevel', 'error',
        '-f', 'image2pipe',
        '-i', 'pipe:0',
        // JPEG Canon menyimpan thumbnail di dalam EXIF; tanpa -frames:v 1
        // demuxer bisa memperlakukannya sebagai frame kedua.
        '-frames:v', '1',
        // scale=-2 menjaga sisi kedua tetap genap (syarat beberapa encoder)
        // sekaligus mempertahankan rasio aspek.
        '-vf', 'hflip,scale=$maxSide:-2',
        '-q:v', ffmpegQuality,
        '-f', 'image2',
        'pipe:1',
      ]);

      // Tulis input & baca output BERSAMAAN. Kalau input ditulis sampai
      // selesai dulu baru output dibaca, pipe output bisa penuh (foto
      // hasilnya ratusan KB) dan kedua proses saling menunggu.
      final outFuture = _collect(p.stdout);
      final errFuture = _collect(p.stderr);
      p.stdin.add(raw);
      unawaited(p.stdin.close().catchError((_) {}));

      final code = await p.exitCode.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          p.kill();
          return -1;
        },
      );
      final out = await outFuture;
      if (code != 0 || out.isEmpty) {
        final err = String.fromCharCodes(await errFuture);
        debugPrint('[PhotoProcessor] ffmpeg exit $code: ${err.trim()}');
        return null;
      }
      return out;
    } catch (e) {
      debugPrint('[PhotoProcessor] ffmpeg error: $e');
      return null;
    }
  }

  static Future<Uint8List> _collect(Stream<List<int>> s) async {
    final chunks = <List<int>>[];
    var total = 0;
    await for (final c in s) {
      chunks.add(c);
      total += c.length;
    }
    final out = Uint8List(total);
    var off = 0;
    for (final c in chunks) {
      out.setRange(off, off + c.length, c);
      off += c.length;
    }
    return out;
  }
}
