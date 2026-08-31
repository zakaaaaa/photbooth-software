import 'dart:io';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/foundation.dart'
    show compute, consolidateHttpClientResponseBytes;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import '../providers/photo_provider.dart';

// ================================================================
// FRAME COMPOSER
// Merangkai foto + slot + frame overlay menjadi satu PNG final.
// Dipakai oleh CameraPage (render awal) dan PreviewPage (render ulang
// setelah filter dipilih). Logika identik dengan render lama di camera.
// ================================================================
/// Hasil render kanvas sebelum di-encode: RGBA mentah beserta dimensinya.
class RenderedStrip {
  final Uint8List rgba;
  final int width;
  final int height;

  const RenderedStrip({
    required this.rgba,
    required this.width,
    required this.height,
  });
}

class FrameComposer {
  static const double _deg2rad = 3.141592653589793 / 180;

  // Encode PNG di background isolate agar tidak blok UI thread.
  static Uint8List _encodePngInIsolate(Map<String, dynamic> args) {
    final int width = args['width'] as int;
    final int height = args['height'] as int;
    final Uint8List raw = args['raw'] as Uint8List;
    final image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: raw.buffer,
      order: img.ChannelOrder.rgba,
    );
    return Uint8List.fromList(img.encodePng(image));
  }

  /// Sisi terpanjang hasil render, dalam piksel.
  ///
  /// 1800 px = 6 inci x 300 DPI, yaitu standar cetak foto di kertas 4R.
  ///
  /// KENAPA BUKAN ANGKA SKALA TETAP (diukur 2026-08-26): dulu di sini ada
  /// `const double scale = 2.5`, dan pada frame default 344x515 itu
  /// menghasilkan 860x1287 px. Di kertas 4R angka itu cuma **215 DPI** —
  /// di bawah standar cetak, dan hasilnya terlihat lembek. Skala tetap juga
  /// membuat DPI ikut berubah-ubah setiap template punya ukuran logis beda.
  /// Sekarang skalanya diturunkan dari target DPI, bukan sebaliknya.
  ///
  /// Bahan bakunya cukup: foto sumber dibatasi 3000 px sisi terpanjang
  /// (PhotoProcessor.maxSide), sementara satu slot pada strip 3 foto hanya
  /// perlu sekitar 1100x800 px di 300 DPI.
  ///
  /// JANGAN naikkan angka ini untuk memperbaiki hasil cetak — pakai
  /// [printLongSidePx]. Nilai ini dipakai di jalur preview/upload, dan
  /// `compose()` dipanggil ULANG setiap pelanggan mengganti filter
  /// (preview_page) dengan spinner menunggu. Diukur 2026-08-27, encode PNG
  /// saja: 1800px = 1,27s, 2400px = 2,34s, 4536px = 6,60s per ganti filter.
  /// Ukuran PNG-nya juga ikut naik (1,8MB -> 7,6MB) padahal berkas itulah
  /// yang diunggah dan diunduh pelanggan — PNG 9MB pernah ditolak proxy
  /// gambar Gmail saat pengiriman email.
  static int targetLongSidePx = 1800;

  /// Sisi terpanjang khusus jalur CETAK. 3000 px = 500 DPI di kertas 4R.
  ///
  /// Dipisah dari [targetLongSidePx] supaya ketajaman cetak bisa dinaikkan
  /// TANPA memperlambat pergantian filter dan tanpa menggemukkan berkas
  /// unduhan pelanggan.
  ///
  /// Plafon kerasnya 4536 px (756 DPI): itu raster fisik driver Epson untuk
  /// 4R di mode borderless (PHYSICAL page 3024x4536, terukur lewat
  /// GetDeviceCaps). Lebih dari itu langsung dibuang driver.
  ///
  /// Foto sumber bukan penghalang: pada 3000 px satu sel foto jadi ~860x465,
  /// sementara sumbernya dibatasi 3000 px (PhotoProcessor.maxSide) — masih
  /// jauh di atas kebutuhan.
  static int printLongSidePx = 3000;

  /// Render frame final dari state [provider] → bytes PNG.
  /// Dipakai jalur preview & upload, pada [targetLongSidePx].
  static Future<Uint8List> compose(PhotoProvider provider) async {
    final strip = await _renderRaw(provider, targetLongSidePx);
    return compute(_encodePngInIsolate, {
      'width': strip.width,
      'height': strip.height,
      'raw': strip.rgba,
    });
  }

  /// Render khusus CETAK pada [printLongSidePx], dikembalikan sebagai RGBA
  /// mentah — SENGAJA tidak di-encode ke PNG.
  ///
  /// PrintService toh mengubahnya jadi JPEG, jadi encode PNG di tengah jalan
  /// hanya biaya buang: pada 3000 px itu 3,3 detik dan 4,1 MB yang langsung
  /// dibuang lagi. Menyerahkan RGBA mentah juga menghemat satu decode PNG di
  /// dalam isolate cetak.
  static Future<RenderedStrip> composeForPrint(PhotoProvider provider) =>
      _renderRaw(provider, printLongSidePx);

  static Future<RenderedStrip> _renderRaw(
      PhotoProvider provider, int longSidePx) async {
    final double frameW = provider.selectedFrameWidth;
    final double frameH = provider.selectedFrameHeight;

    // Skala diturunkan dari sisi terpanjang supaya DPI hasilnya sama untuk
    // semua template, apa pun ukuran logisnya. Tidak pernah memperkecil.
    final double longSide = frameW > frameH ? frameW : frameH;
    final double scale =
        longSide <= 0 ? 1.0 : (longSidePx / longSide).clamp(1.0, 12.0);

    // Bulatkan dimensi piksel LEBIH DULU, lalu pakai nilai bulat itu sebagai
    // ukuran kanvas. Kalau tidak, Rect kanvas (misal 1202,3 px) dan
    // picture.toImage() yang memotong ke int akan beda sepersekian piksel dan
    // menyisakan garis transparan di tepi kanan/bawah.
    final int wPx = (frameW * scale).round();
    final int hPx = (frameH * scale).round();
    final double w = wPx.toDouble();
    final double h = hPx.toDouble();

    // 4R = 6 inci sisi panjang; dipakai hanya untuk melaporkan DPI di log.
    debugPrint('[FrameComposer] frame ${frameW.toStringAsFixed(0)}x'
        '${frameH.toStringAsFixed(0)} x${scale.toStringAsFixed(3)} '
        '-> ${wPx}x$hPx px (~${(longSidePx / 6).round()} DPI di 4R)');

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));

    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);

    // PATH A: Custom slots dari web editor
    if (provider.hasCustomSlots) {
      final List<ui.Image> decodedPhotos = [];
      for (int pi = 0; pi < provider.photos.length; pi++) {
        final codec =
            await ui.instantiateImageCodec(provider.photos[pi].imageData);
        final frame = await codec.getNextFrame();
        decodedPhotos.add(frame.image);
      }

      for (int si = 0; si < provider.photoSlots.length; si++) {
        final slot = provider.photoSlots[si];
        final int pidx = slot.photoIndex.clamp(0, decodedPhotos.length - 1);
        final image = decodedPhotos[pidx];

        final double dx = slot.x * scale;
        final double dy = slot.y * scale;
        final double dw = slot.width * scale;
        final double dh = slot.height * scale;

        final double srcRatio = image.width / image.height.toDouble();
        final double dstRatio = dw / dh;
        double srcX = 0, srcY = 0;
        double srcW = image.width.toDouble();
        double srcH = image.height.toDouble();

        if (srcRatio > dstRatio) {
          srcW = srcH * dstRatio;
          srcX = (image.width - srcW) / 2;
        } else {
          srcH = srcW / dstRatio;
          srcY = 0;
        }

        if (slot.rotation != 0) {
          final double cx = dx + dw / 2;
          final double cy = dy + dh / 2;
          canvas.save();
          canvas.translate(cx, cy);
          canvas.rotate(slot.rotation * _deg2rad);
          canvas.translate(-cx, -cy);
        }

        canvas.drawImageRect(
          image,
          Rect.fromLTWH(srcX, srcY, srcW, srcH),
          Rect.fromLTWH(dx, dy, dw, dh),
          Paint()..filterQuality = FilterQuality.high,
        );

        if (slot.rotation != 0) canvas.restore();
      }

      // PATH B: Fallback FrameLayout (grid hardcoded)
    } else {
      final layout = provider.selectedLayout;
      final int count = provider.targetPhotoCount;
      final int cols = count == 3 ? 1 : 2;
      final int rows = (count / cols).ceil();

      final lTop = layout.topPadding * scale;
      final lBottom = layout.bottomPadding * scale;
      final lLeft = layout.leftPadding * scale;
      final lRight = layout.rightPadding * scale;
      final lHSpace = layout.horizontalSpacing * scale;
      final lVSpace = layout.verticalSpacing * scale;

      final double paddedW = w - lLeft - lRight;
      final double paddedH = h - lTop - lBottom;
      final double cellW = (paddedW - (cols - 1) * lHSpace) / cols;
      final double cellH = (paddedH - (rows - 1) * lVSpace) / rows;

      for (int i = 0; i < provider.photos.length && i < count; i++) {
        final col = i % cols;
        final row = i ~/ cols;
        final dx = lLeft + col * (cellW + lHSpace);
        final dy = lTop + row * (cellH + lVSpace);

        final codec =
            await ui.instantiateImageCodec(provider.photos[i].imageData);
        final frame = await codec.getNextFrame();
        final image = frame.image;

        final double srcRatio = image.width / image.height.toDouble();
        final double dstRatio = cellW / cellH;
        double srcX = 0, srcY = 0;
        double srcW = image.width.toDouble();
        double srcH = image.height.toDouble();

        if (srcRatio > dstRatio) {
          srcW = srcH * dstRatio;
          srcX = (image.width - srcW) / 2;
        } else {
          srcH = srcW / dstRatio;
          srcY = 0;
        }

        canvas.drawImageRect(
          image,
          Rect.fromLTWH(srcX, srcY, srcW, srcH),
          Rect.fromLTWH(dx, dy, cellW, cellH),
          Paint()..filterQuality = FilterQuality.high,
        );
      }
    }

    // FRAME OVERLAY
    if (provider.selectedFrameAsset != null) {
      final frameUrl = provider.selectedFrameAsset!;
      Uint8List frameBytes;

      if (frameUrl.startsWith('http')) {
        final httpClient = HttpClient();
        final request = await httpClient.getUrl(Uri.parse(frameUrl));
        final response = await request.close();
        frameBytes = await consolidateHttpClientResponseBytes(response);
      } else {
        final data = await rootBundle.load(frameUrl);
        frameBytes = data.buffer.asUint8List();
      }

      final codec = await ui.instantiateImageCodec(frameBytes);
      final frame = await codec.getNextFrame();
      canvas.drawImageRect(
        frame.image,
        Rect.fromLTWH(0, 0, frame.image.width.toDouble(),
            frame.image.height.toDouble()),
        Rect.fromLTWH(0, 0, w, h),
        Paint()..filterQuality = FilterQuality.high,
      );
    }

    final picture = recorder.endRecording();
    final uiImage = await picture.toImage(wPx, hPx);

    final byteData =
        await uiImage.toByteData(format: ui.ImageByteFormat.rawRgba);
    uiImage.dispose();
    if (byteData == null) throw Exception('toByteData null');

    return RenderedStrip(
      rgba: byteData.buffer.asUint8List(),
      width: wPx,
      height: hPx,
    );
  }
}
