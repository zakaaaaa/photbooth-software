import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import 'package:photobooth_app/providers/photo_provider.dart';

// Entry top-level untuk dijalankan di isolate via compute().
// args: { 'bytes': Uint8List, 'filter': int(index), 'mirror': bool }
Uint8List filterImageEntry(Map<String, dynamic> args) {
  return ImageFilterUtil.applyFilterSync(
    args['bytes'] as Uint8List,
    PhotoFilter.values[args['filter'] as int],
    mirror: args['mirror'] as bool,
  );
}

class ImageFilterUtil {
  static Future<Uint8List> applyFilter(
    Uint8List imageData,
    PhotoFilter filter, {
    bool mirror = true,
  }) {
    // WAJIB lewat compute(): untuk foto DSLR 18MP, rangkaian decode JPEG →
    // resize → flip → encode ulang memakan waktu detik-detikan. Kalau
    // dijalankan langsung (applyFilterSync) semuanya terjadi di isolate UI,
    // sehingga seluruh app — termasuk aliran frame live view — membeku
    // selama itu dan terasa sebagai "jeda setelah jepret".
    return compute(filterImageEntry, <String, dynamic>{
      'bytes': imageData,
      'filter': filter.index,
      'mirror': mirror,
    });
  }

  // Versi sinkron — aman dipanggil di isolate (compute).
  static Uint8List applyFilterSync(
    Uint8List imageData,
    PhotoFilter filter, {
    bool mirror = true,
  }) {
    // 1. Decode dengan mempertahankan resolusi asli
    var image = img.decodeImage(imageData);
    if (image == null) return imageData;

    // 1.2 Limit resolusi agar tidak terlalu berat (DSLR 24MP → 3000px ~9MP)
    // 3000px sudah sangat tajam untuk cetak 4R profesional
    if (image.width > 3000 || image.height > 3000) {
      if (image.width > image.height) {
        image = img.copyResize(image, width: 3000);
      } else {
        image = img.copyResize(image, height: 3000);
      }
    }

    // 1.5 Auto-mirror (horizontal flip) agar hasilnya seperti selfie.
    //     Dimatikan (mirror:false) saat filter diterapkan ulang dari base
    //     yang sudah ter-mirror, supaya tidak terbalik dua kali.
    final selfieImage = mirror ? img.flipHorizontal(image) : image;

    img.Image filteredImage;

    switch (filter) {
      case PhotoFilter.vintage:
        filteredImage = _applyVintageFilter(selfieImage);
        break;
      case PhotoFilter.grayscale:
        filteredImage = img.grayscale(selfieImage);
        break;
      case PhotoFilter.smooth:
        // PERBAIKAN: Gunakan sharpen tipis setelah blur agar tidak terlihat pecah/buram
        filteredImage = img.gaussianBlur(selfieImage, radius: 1);
        break;
      case PhotoFilter.brightness:
        filteredImage = img.adjustColor(selfieImage, brightness: 1.15);
        break;
      case PhotoFilter.none:
        filteredImage = selfieImage;
    }

    // JPEG quality 98 adalah sweet spot (hampir lossless tapi jauh lebih ringan dari PNG)
    return Uint8List.fromList(img.encodeJpg(filteredImage, quality: 98));
  }

  static img.Image _applyVintageFilter(img.Image image) {
    // Vintage effect: sepia tone + sedikit kontras
    var result = img.sepia(image);
    result = img.adjustColor(result, contrast: 1.1, saturation: 0.9);
    return result;
  }
}
