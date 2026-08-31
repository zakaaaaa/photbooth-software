// Buat LEMBAR UJI KOREKSI WARNA — satu kertas 4R berisi beberapa varian
// koreksi bersebelahan, lengkap dengan labelnya.
//
// KENAPA ADA ALAT INI
// Cetakan tidak akan pernah persis sama dengan layar: layar memancarkan
// cahaya sendiri dengan kontras tinggi, kertas hanya memantulkan cahaya
// ruangan. Foto SELALU terlihat lebih datar di kertas. Yang bisa dilakukan
// adalah mengkompensasinya dengan koreksi di sisi cetak — dan besarannya
// harus DIUKUR di kertas, bukan ditebak dari layar.
//
// Menebak satu per satu berarti membuang satu lembar per percobaan. Alat ini
// memuat semua varian dalam SATU lembar, jadi tinggal ditunjuk mana yang
// paling mendekati layar.
//
// CARA PAKAI
//   dart run tools/print_calibration.dart [strip.png]
//
// Hasilnya ditulis ke folder History sebagai entri bernama "kalibrasi-...",
// SENGAJA, supaya bisa dicetak lewat tombol "Cetak Ulang" di halaman
// diagnostik. Itu penting: dengan begitu lembar uji melewati jalur cetak
// yang PERSIS SAMA dengan cetakan pelanggan (PrintService -> driver). Kalau
// dicetak lewat Acrobat/Edge, setelannya beda dan hasilnya tidak bisa
// dijadikan acuan.
//
// Setelah memilih, pasang nilainya di PrintService.printCorrection.
import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:photobooth_app/utils/print_color.dart';

/// Satu varian koreksi yang diuji.
///
/// Koreksinya lewat applyPrintCorrection — fungsi yang SAMA dengan yang
/// dipakai PrintService saat mencetak sungguhan. Itu yang membuat lembar uji
/// ini bisa dipercaya: apa yang kamu pilih di kertas persis itu yang nanti
/// keluar. JANGAN ganti ke img.adjustColor — parameter `saturation:`-nya
/// mengubah semua piksel netral jadi hitam pekat (lihat catatan di
/// lib/utils/print_color.dart).
class Variant {
  final String label;
  final PrintCorrection correction;
  const Variant(this.label, this.correction);
}

// Sengaja merentang ke DUA arah (lebih terang & lebih pekat) supaya
// kertasnya yang memutuskan, bukan tebakan. Nomor dipakai sebagai label
// karena angka lebih gampang disebut daripada membaca parameter kecil-kecil.
const variants = <Variant>[
  Variant('1 ASLI', PrintCorrection.none),
  Variant('2 SAT+30', PrintCorrection(saturation: 1.30)),
  Variant('3 SAT+30 KON+20',
      PrintCorrection(saturation: 1.30, contrast: 1.20)),
  Variant('4 SAT+30 TERANG',
      PrintCorrection(saturation: 1.30, gamma: 1.15)),
  Variant('5 SAT+30 KON+20 PEKAT',
      PrintCorrection(saturation: 1.30, contrast: 1.20, gamma: 0.88)),
  Variant('6 SAT+50 KON+30',
      PrintCorrection(saturation: 1.50, contrast: 1.30)),
];

File? latestStrip(String dir) {
  final d = Directory(dir);
  if (!d.existsSync()) return null;
  final pngs = d
      .listSync()
      .whereType<File>()
      .where((f) =>
          f.path.toLowerCase().endsWith('.png') &&
          !f.path.contains('kalibrasi-'))
      .toList();
  if (pngs.isEmpty) return null;
  pngs.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
  return pngs.first;
}

void main(List<String> args) {
  final home = Platform.environment['USERPROFILE'];
  final historyDir = '$home\\Documents\\Photobooth\\History';

  final srcFile = args.isNotEmpty ? File(args[0]) : latestStrip(historyDir);
  if (srcFile == null || !srcFile.existsSync()) {
    stderr.writeln('Tidak menemukan strip. '
        'Beri path: dart run tools/print_calibration.dart <file.png>');
    exit(1);
  }

  final strip = img.decodeImage(srcFile.readAsBytesSync());
  if (strip == null) {
    stderr.writeln('Gagal decode ${srcFile.path}');
    exit(1);
  }
  print('sumber : ${srcFile.path}  (${strip.width}x${strip.height})');

  // Ambil satu potongan yang MEWAKILI: harus berisi kulit, dinding, dan
  // baju gelap sekaligus — tiga hal yang paling menunjukkan masalah warna.
  // Sepertiga bagian atas strip biasanya memuat ketiganya.
  final cropH = (strip.height * 0.26).round();
  final cropW = (strip.width * 0.46).round();
  final sample = img.copyCrop(strip,
      x: (strip.width * 0.04).round(),
      y: (strip.height * 0.10).round(),
      width: cropW,
      height: cropH);

  // Lembar 4R 300 DPI, potret — sama dengan keluaran FrameComposer.
  const sheetW = 1200, sheetH = 1800;
  final sheet = img.Image(width: sheetW, height: sheetH)
    ..clear(img.ColorRgb8(255, 255, 255));

  const cols = 2, rows = 3;
  const margin = 26, labelH = 40, gap = 14;
  final cellW = (sheetW - margin * 2 - gap * (cols - 1)) ~/ cols;
  final cellH = (sheetH - margin * 2 - gap * (rows - 1)) ~/ rows;
  final imgH = cellH - labelH;

  final black = img.ColorRgb8(0, 0, 0);
  final gray = img.ColorRgb8(140, 140, 140);

  for (int i = 0; i < variants.length && i < cols * rows; i++) {
    final v = variants[i];
    final cx = margin + (i % cols) * (cellW + gap);
    final cy = margin + (i ~/ cols) * (cellH + gap);

    // Koreksi diterapkan pada potongan berukuran akhir, bukan sebelum
    // resize — supaya persis seperti yang nanti terjadi di PrintService.
    final scaled = img.copyResize(sample,
        width: cellW, height: imgH, interpolation: img.Interpolation.cubic);
    final out = applyPrintCorrection(scaled, v.correction);

    img.compositeImage(sheet, out, dstX: cx, dstY: cy);
    img.drawRect(sheet,
        x1: cx, y1: cy, x2: cx + cellW - 1, y2: cy + imgH - 1, color: gray);
    img.drawString(sheet, v.label,
        font: img.arial24, x: cx + 2, y: cy + imgH + 8, color: black);
  }

  img.drawString(sheet, 'LEMBAR UJI KOREKSI WARNA CETAK',
      font: img.arial14, x: margin, y: sheetH - 30, color: gray);
  img.drawString(sheet, 'Pilih nomor yang paling mendekati layar',
      font: img.arial14, x: margin, y: sheetH - 14, color: gray);

  final stamp = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final name = 'kalibrasi-${stamp.millisecondsSinceEpoch}_'
      '${stamp.year}${two(stamp.month)}${two(stamp.day)}_'
      '${two(stamp.hour)}${two(stamp.minute)}${two(stamp.second)}.png';
  final outFile = File('$historyDir\\$name');
  outFile.writeAsBytesSync(img.encodePng(sheet));

  print('');
  print('Lembar uji dibuat: ${outFile.path}');
  print('  ${sheetW}x$sheetH px (300 DPI di 4R), ${variants.length} varian');
  for (final v in variants) {
    print('    ${v.label.padRight(24)} ${v.correction}');
  }
  print('');
  print('LANGKAH BERIKUTNYA:');
  print('  1. Buka halaman diagnostik di app (riwayat akan memuat entri ini)');
  print('  2. Tekan CETAK ULANG pada entri "kalibrasi-..."');
  print('     -> lewat jalur cetak yang sama persis dengan cetakan pelanggan');
  print('  3. Lihat kertasnya, pilih nomor yang paling mendekati layar');
}
