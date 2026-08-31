import 'dart:math' as math;
import 'package:image/image.dart' as img;

// ================================================================
// KOREKSI WARNA UNTUK CETAK
//
// Dipakai bersama oleh PrintService (jalur cetak sungguhan) dan
// tools/print_calibration.dart (lembar uji), supaya lembar uji benar-benar
// memprediksi hasil cetak. Kalau keduanya punya rumus sendiri-sendiri,
// lembar ujinya jadi bohong.
//
// KENAPA PERLU KOREKSI SAMA SEKALI
// Cetakan tidak akan pernah persis sama dengan layar, dan itu fisika bukan
// bug: layar memancarkan cahaya sendiri dengan kontras tinggi, kertas hanya
// memantulkan cahaya ruangan. Foto SELALU terlihat lebih datar di kertas.
// Besaran kompensasinya harus DIUKUR di kertas lewat lembar uji, bukan
// ditebak dari layar.
//
// KENAPA RUMUSNYA DITULIS TANGAN, TIDAK PAKAI img.adjustColor
// Parameter `saturation:` di package:image 4.5.4 RUSAK: piksel netral
// (putih/abu/hitam, yaitu yang saturasinya 0) berubah jadi HITAM PEKAT —
// bahkan pada saturation: 1.0 yang mestinya tidak mengubah apa pun.
// Diverifikasi 2026-08-26:
//
//   saturation: 1.0   putih 255,255,255 -> 0,0,0
//                     abu   128,128,128 -> 0,0,0
//                     krem  212,196,170 -> 212,196,170  (piksel berwarna aman)
//
// Pada strip photobooth yang latar bingkainya putih, itu berarti bidang
// putih besar berubah jadi blok hitam. Rumus saturasi di bawah memakai
// interpolasi terhadap luminансi, yang secara alami membiarkan piksel netral
// tidak berubah (karena nilainya sama dengan luminansinya sendiri).
//
// `contrast:` dan `gamma:` di adjustColor terbukti aman, tapi tetap ditulis
// ulang di sini supaya seluruh koreksi terjadi dalam SATU lintasan piksel —
// lebih cepat dan hanya ada satu tempat untuk dinalar.
// ================================================================

/// Satu set koreksi warna untuk jalur cetak.
class PrintCorrection {
  /// 1.0 = tanpa perubahan. >1 menambah kepekatan warna.
  final double saturation;

  /// 1.0 = tanpa perubahan. >1 menambah kontras (pivot di abu tengah).
  final double contrast;

  /// 1.0 = tanpa perubahan. >1 mencerahkan midtone, <1 memekatkan.
  final double gamma;

  const PrintCorrection({
    this.saturation = 1.0,
    this.contrast = 1.0,
    this.gamma = 1.0,
  });

  /// Tanpa koreksi sama sekali.
  static const none = PrintCorrection();

  bool get isIdentity =>
      saturation == 1.0 && contrast == 1.0 && gamma == 1.0;

  @override
  String toString() => 'sat=${saturation.toStringAsFixed(2)} '
      'kon=${contrast.toStringAsFixed(2)} '
      'gam=${gamma.toStringAsFixed(2)}';
}

/// Terapkan [c] ke [src]. Mengembalikan [src] apa adanya kalau tidak ada
/// yang perlu diubah. Gambar dimodifikasi di tempat.
img.Image applyPrintCorrection(img.Image src, PrintCorrection c) {
  if (c.isIdentity) return src;

  // Tabel gamma dihitung sekali, bukan pow() per piksel per kanal —
  // untuk strip 1200x1800 itu 6,5 juta panggilan pow yang bisa dihindari.
  final needGamma = c.gamma != 1.0;
  final gammaLut = needGamma
      ? List<double>.generate(
          256, (i) => math.pow(i / 255.0, 1.0 / c.gamma).toDouble() * 255.0)
      : const <double>[];

  final needSat = c.saturation != 1.0;
  final needCon = c.contrast != 1.0;

  for (final p in src) {
    double r = p.r.toDouble();
    double g = p.g.toDouble();
    double b = p.b.toDouble();

    if (needSat) {
      // Interpolasi terhadap luminansi (Rec.709). Piksel netral punya
      // r=g=b=lum sehingga hasilnya tidak berubah — inilah yang bikin rumus
      // ini kebal terhadap bug netral-jadi-hitam di adjustColor.
      final lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
      r = lum + (r - lum) * c.saturation;
      g = lum + (g - lum) * c.saturation;
      b = lum + (b - lum) * c.saturation;
    }

    if (needCon) {
      // Pivot di 127,5 supaya midtone tetap di tempat dan hanya sebaran
      // terang-gelapnya yang melebar.
      r = (r - 127.5) * c.contrast + 127.5;
      g = (g - 127.5) * c.contrast + 127.5;
      b = (b - 127.5) * c.contrast + 127.5;
    }

    if (needGamma) {
      r = gammaLut[r.clamp(0, 255).round()];
      g = gammaLut[g.clamp(0, 255).round()];
      b = gammaLut[b.clamp(0, 255).round()];
    }

    // Clamp WAJIB di sini: tanpa ini nilai di luar 0..255 membungkus
    // (wrap) dan menghasilkan bintik-bintik warna acak di bidang terang.
    p
      ..r = r.clamp(0, 255)
      ..g = g.clamp(0, 255)
      ..b = b.clamp(0, 255);
  }

  return src;
}
