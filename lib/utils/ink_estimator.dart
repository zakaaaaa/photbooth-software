import 'package:image/image.dart' as img;

// ================================================================
// ESTIMASI PEMAKAIAN TINTA
//
// KENAPA DIHITUNG SENDIRI, BUKAN DIBACA DARI PRINTER
// EPSON L3210 adalah EcoTank dan tangkinya TIDAK BERCHIP — printer-nya
// sendiri tidak punya sensor level tinta. Diverifikasi 2026-08-27:
// Get-PrinterProperty tidak mengembalikan satu pun properti ink/level/supply,
// WMI Win32_Printer tidak punya properti tinta sama sekali, port-nya USB
// (bukan IPP yang punya atribut supply), dan Status Monitor Epson tidak
// terpasang. Status Monitor bawaan Epson pun sebenarnya hanya angka
// perkiraan yang di-reset manual setelah isi ulang, bukan hasil pengukuran.
//
// Jadi satu-satunya cara mengetahui pemakaian tinta adalah menghitungnya
// dari gambar yang KITA cetak sendiri — dan itu justru bisa cukup presisi,
// karena kita punya seluruh pikselnya sebelum dikirim.
//
// SEBERAPA AKURAT INI
// Konversi RGB->CMYK di bawah memakai rumus naif (tanpa GCR/UCR dan tanpa
// profil ICC printer), sementara driver Epson memakai separasi warnanya
// sendiri. Jadi angka ini BUKAN mililiter dan tidak boleh diperlakukan
// begitu. Yang dijamin adalah keterbandingannya: satu lembar dengan liputan
// 2x lipat memang memakai tinta sekitar 2x lipat, dan frame gelap memang
// terdeteksi jauh lebih boros daripada frame terang. Itu sudah cukup untuk
// memperkirakan kapan harus isi ulang.
//
// Kalibrasi ke mililiter dilakukan belakangan di sisi dashboard: setelah
// satu siklus isi ulang, operator tahu berapa mL yang benar-benar masuk
// untuk sekian unit liputan, dan rasionya bisa disimpan.
// ================================================================

/// Liputan tinta satu halaman, per kanal, dalam satuan "halaman penuh".
///
/// 1.0 berarti satu halaman penuh tinta pekat untuk kanal itu. Nilai wajar
/// untuk strip photobooth ada di kisaran 0,1-0,5 per kanal.
class InkCoverage {
  final double c;
  final double m;
  final double y;
  final double k;

  const InkCoverage({
    required this.c,
    required this.m,
    required this.y,
    required this.k,
  });

  static const zero = InkCoverage(c: 0, m: 0, y: 0, k: 0);

  /// Total lintas kanal — dipakai sebagai angka tunggal "seberapa boros".
  double get total => c + m + y + k;

  Map<String, dynamic> toJson() => {
        'c': double.parse(c.toStringAsFixed(5)),
        'm': double.parse(m.toStringAsFixed(5)),
        'y': double.parse(y.toStringAsFixed(5)),
        'k': double.parse(k.toStringAsFixed(5)),
      };

  factory InkCoverage.fromJson(Map<String, dynamic> j) => InkCoverage(
        c: (j['c'] as num?)?.toDouble() ?? 0,
        m: (j['m'] as num?)?.toDouble() ?? 0,
        y: (j['y'] as num?)?.toDouble() ?? 0,
        k: (j['k'] as num?)?.toDouble() ?? 0,
      );

  @override
  String toString() => 'C=${(c * 100).toStringAsFixed(1)}% '
      'M=${(m * 100).toStringAsFixed(1)}% '
      'Y=${(y * 100).toStringAsFixed(1)}% '
      'K=${(k * 100).toStringAsFixed(1)}%';
}

/// Hitung liputan tinta [image].
///
/// [sampleStep] melompati piksel untuk kecepatan. Pada strip 1200x1800
/// (2,2 juta piksel) langkah 3 menyisakan ~240 ribu sampel — selisih hasilnya
/// terhadap pemindaian penuh di bawah 0,1% sementara waktunya sepertiganya.
///
/// PENTING: panggil ini pada gambar yang BENAR-BENAR dicetak, yaitu setelah
/// koreksi warna diterapkan. Selisihnya nyata dan arahnya tidak selalu
/// intuitif — pada koreksi yang dipakai sekarang (sat 1,30 + gamma 1,15)
/// total tinta justru TURUN 4,3%, karena pencerahan gamma memangkas kanal K
/// lebih banyak daripada tambahan saturasi di CMY. Diukur pada strip
/// 1200x1801, 2026-08-27.
///
/// Nilai acuan hasil verifikasi: putih polos = 0 di semua kanal, hitam polos
/// = K 100% (CMY nol, karena black generation penuh), cyan murni = C 100%,
/// merah murni = M 100% + Y 100%.
InkCoverage estimateInkCoverage(img.Image image, {int sampleStep = 3}) {
  final step = sampleStep < 1 ? 1 : sampleStep;

  double sumC = 0, sumM = 0, sumY = 0, sumK = 0;
  int n = 0;

  for (int py = 0; py < image.height; py += step) {
    for (int px = 0; px < image.width; px += step) {
      final p = image.getPixel(px, py);
      final r = p.r / 255.0;
      final g = p.g / 255.0;
      final b = p.b / 255.0;

      // Konversi RGB -> CMYK dengan black generation penuh: seberapa banyak
      // pun warna netral yang ada, dipikul oleh kanal K. Ini mendekati
      // perilaku printer inkjet, yang memang memakai tinta hitam untuk
      // bagian netral alih-alih mencampur tiga warna.
      final maxRgb = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final k = 1.0 - maxRgb;

      if (maxRgb > 0) {
        sumC += (maxRgb - r) / maxRgb;
        sumM += (maxRgb - g) / maxRgb;
        sumY += (maxRgb - b) / maxRgb;
      }
      sumK += k;
      n++;
    }
  }

  if (n == 0) return InkCoverage.zero;
  return InkCoverage(
    c: sumC / n,
    m: sumM / n,
    y: sumY / n,
    k: sumK / n,
  );
}
