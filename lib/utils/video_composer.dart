import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show consolidateHttpClientResponseBytes;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import '../providers/photo_provider.dart';

// ================================================================
// VIDEO COMPOSER
// Menyusun klip video tiap foto ke posisi slot-nya (seperti strip foto)
// lalu menimpa overlay frame, menghasilkan satu MP4 — via ffmpeg.
//
// Catatan: ffmpeg.exe WAJIB tersedia. Letakkan ffmpeg.exe di salah satu:
//   - folder yang sama dengan executable aplikasi (rilis)
//   - <root proyek>/tools/ffmpeg.exe atau <root proyek>/ffmpeg.exe (dev)
//   - atau set env FFMPEG_PATH
// Bila tidak ditemukan, dipakai 'ffmpeg' dari PATH.
// ================================================================
class _Placement {
  final String clipPath;
  final double x, y, w, h, rotationDeg;
  _Placement(this.clipPath, this.x, this.y, this.w, this.h, this.rotationDeg);
}

class VideoComposer {
  // Skala output relatif ukuran frame (kualitas vs beban encode).
  static const double _scale = 2.0;

  // Cari lokasi ffmpeg.exe.
  static String resolveFfmpeg() {
    final env = Platform.environment['FFMPEG_PATH'];
    if (env != null && env.isNotEmpty && File(env).existsSync()) return env;

    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    final String cwd = Directory.current.path;
    final List<String> candidates = [
      '$exeDir/ffmpeg.exe',
      '$exeDir/data/flutter_assets/assets/bin/ffmpeg.exe',
      '$cwd/ffmpeg.exe',
      '$cwd/tools/ffmpeg.exe',
      '$cwd/assets/bin/ffmpeg.exe',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return 'ffmpeg'; // fallback ke PATH
  }

  static int _even(double v) {
    int n = v.round();
    return n.isOdd ? n + 1 : n;
  }

  // Filter warna ffmpeg yang setara dengan filter foto (null = none).
  static String? _ffmpegFilter(PhotoFilter f) {
    switch (f) {
      case PhotoFilter.vintage:
        // sepia + sedikit kontras & saturasi turun (mirip _applyVintageFilter)
        return 'colorchannelmixer=.393:.769:.189:0:.349:.686:.168:0:'
            '.272:.534:.131:0,eq=contrast=1.1:saturation=0.9';
      case PhotoFilter.grayscale:
        return 'hue=s=0';
      case PhotoFilter.smooth:
        return 'gblur=sigma=1.2';
      case PhotoFilter.brightness:
        return 'eq=brightness=0.08';
      case PhotoFilter.none:
        return null;
    }
  }

  // Daftar penempatan klip (frame units) sesuai mode slot.
  static List<_Placement> _placements(PhotoProvider provider) {
    final List<_Placement> out = [];
    final photos = provider.photos;

    if (provider.hasCustomSlots) {
      for (final slot in provider.photoSlots) {
        final int idx = slot.photoIndex.clamp(0, photos.length - 1);
        final clip = photos[idx].videoPath;
        if (clip == null) continue;
        out.add(_Placement(
            clip, slot.x, slot.y, slot.width, slot.height, slot.rotation));
      }
    } else {
      final layout = provider.selectedLayout;
      final int count = provider.targetPhotoCount;
      final int cols = count == 3 ? 1 : 2;
      final int rows = (count / cols).ceil();
      final double w = provider.selectedFrameWidth;
      final double h = provider.selectedFrameHeight;

      final double paddedW = w - layout.leftPadding - layout.rightPadding;
      final double paddedH = h - layout.topPadding - layout.bottomPadding;
      final double cellW =
          (paddedW - (cols - 1) * layout.horizontalSpacing) / cols;
      final double cellH =
          (paddedH - (rows - 1) * layout.verticalSpacing) / rows;

      for (int i = 0; i < photos.length && i < count; i++) {
        final clip = photos[i].videoPath;
        if (clip == null) continue;
        final int col = i % cols;
        final int row = i ~/ cols;
        final double dx =
            layout.leftPadding + col * (cellW + layout.horizontalSpacing);
        final double dy =
            layout.topPadding + row * (cellH + layout.verticalSpacing);
        out.add(_Placement(clip, dx, dy, cellW, cellH, 0));
      }
    }
    return out;
  }

  // Siapkan file PNG frame overlay (dari asset/jaringan) ke file sementara.
  // Menerima path asset, bukan provider, supaya tidak membaca ulang state yang
  // bisa sudah dibersihkan saat unduhan frame masih berjalan.
  static Future<String?> _prepareFrameFile(String? asset) async {
    if (asset == null) return null;
    try {
      Uint8List bytes;
      if (asset.startsWith('http')) {
        final client = HttpClient();
        final req = await client.getUrl(Uri.parse(asset));
        final resp = await req.close();
        bytes = await consolidateHttpClientResponseBytes(resp);
      } else {
        final data = await rootBundle.load(asset);
        bytes = data.buffer.asUint8List();
      }
      final tmp = await getTemporaryDirectory();
      final f = File(
          '${tmp.path}/frame_overlay_${DateTime.now().millisecondsSinceEpoch}.png');
      await f.writeAsBytes(bytes);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  /// Komposit video hasil → mengembalikan path MP4, atau null bila gagal.
  ///
  /// PENTING: seluruh data yang dibutuhkan disalin dari provider di awal, SEBELUM
  /// `await` pertama. Timer sesi bisa habis kapan saja dan memicu
  /// `PhotoProvider.reset()` yang mengosongkan foto serta dimensi frame. Kalau
  /// state dibaca ulang di tengah proses, render bisa gagal diam-diam atau
  /// memakai ukuran frame cadangan yang salah — video pelanggan hilang padahal
  /// mereka sudah membayar.
  static Future<String?> compose(PhotoProvider provider) async {
    if (!provider.hasAllVideoClips) return null;

    // ── Snapshot (sinkron, tidak boleh ada await di antaranya) ──
    final placements = _placements(provider);
    final int outW = _even(provider.selectedFrameWidth * _scale);
    final int outH = _even(provider.selectedFrameHeight * _scale);
    final String? frameAsset = provider.selectedFrameAsset;
    final PhotoFilter filter = provider.selectedFilter;
    // ── Mulai sini provider tidak disentuh lagi ──

    if (placements.isEmpty) return null;

    final String? framePath = await _prepareFrameFile(frameAsset);

    // Susun argumen ffmpeg.
    final List<String> args = ['-y'];

    // input 0 = background putih
    args.addAll(
        ['-f', 'lavfi', '-i', 'color=c=white:s=${outW}x$outH:r=25:d=30']);

    // input 1..N = klip (satu input per penempatan)
    for (final p in placements) {
      args.addAll(['-i', p.clipPath]);
    }

    // input frame (opsional), di-loop sebagai gambar diam
    int frameInputIndex = -1;
    if (framePath != null) {
      frameInputIndex = placements.length + 1;
      args.addAll(['-loop', '1', '-i', framePath]);
    }

    // filter warna sesuai filter terpilih (diterapkan ke tiap klip)
    final String? colorFilter = _ffmpegFilter(filter);

    // filter_complex
    final StringBuffer fc = StringBuffer();
    String last = '0:v'; // mulai dari background

    for (int i = 0; i < placements.length; i++) {
      final p = placements[i];
      final int inIdx = i + 1; // input klip
      final int dw = _even(p.w * _scale);
      final int dh = _even(p.h * _scale);
      final double cx = (p.x + p.w / 2) * _scale;
      final double cy = (p.y + p.h / 2) * _scale;

      final String vtag = 'v$i';
      // mirror + cover-scale + crop ke ukuran slot + (filter warna)
      fc.write('[$inIdx:v]hflip,'
          'scale=$dw:$dh:force_original_aspect_ratio=increase,'
          'crop=$dw:$dh,setsar=1');
      if (colorFilter != null) fc.write(',$colorFilter');

      int ovW = dw, ovH = dh;
      if (p.rotationDeg.abs() > 0.01) {
        final double rad = p.rotationDeg * math.pi / 180.0;
        final double c = math.cos(rad).abs();
        final double s = math.sin(rad).abs();
        ovW = (dw * c + dh * s).ceil();
        ovH = (dw * s + dh * c).ceil();
        fc.write(',rotate=$rad:c=none:ow=$ovW:oh=$ovH');
      }
      fc.write('[$vtag];');

      final int ox = (cx - ovW / 2).round();
      final int oy = (cy - ovH / 2).round();
      final String outTag =
          (i == placements.length - 1 && frameInputIndex < 0)
              ? 'outv'
              : 'tmp$i';
      // shortest=1 WAJIB: tanpa ini durasi output mengikuti background putih
      // (30s) sehingga encode ~6x lebih lama. Dengan ini durasi = klip (~5s).
      fc.write('[$last][$vtag]overlay=$ox:$oy:shortest=1[$outTag];');
      last = outTag;
    }

    // overlay frame paling atas
    if (frameInputIndex >= 0) {
      fc.write('[$frameInputIndex:v]scale=$outW:$outH[fr];');
      fc.write('[$last][fr]overlay=0:0:shortest=1[outv];');
      last = 'outv';
    }

    final tmp = await getTemporaryDirectory();
    final outPath =
        '${tmp.path}/video_result_${DateTime.now().millisecondsSinceEpoch}.mp4';

    args.addAll([
      '-filter_complex', fc.toString(),
      '-map', '[outv]',
      '-an', // tanpa audio
      '-c:v', 'libx264',
      '-preset', 'ultrafast',
      '-pix_fmt', 'yuv420p',
      '-movflags', '+faststart',
      '-r', '25',
      '-shortest',
      outPath,
    ]);

    final ffmpeg = resolveFfmpeg();
    try {
      final result = await Process.run(ffmpeg, args);
      if (result.exitCode != 0) {
        // ignore: avoid_print
        print('[VideoComposer] ffmpeg gagal (${result.exitCode}): '
            '${result.stderr.toString().split('\n').take(8).join('\n')}');
        return null;
      }
      if (!File(outPath).existsSync()) return null;
      return outPath;
    } catch (e) {
      // ignore: avoid_print
      print('[VideoComposer] ffmpeg error: $e');
      return null;
    } finally {
      if (framePath != null) {
        try {
          await File(framePath).delete();
        } catch (_) {}
      }
    }
  }
}
