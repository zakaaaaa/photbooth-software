// Periksa hasil cetak TANPA membuang kertas.
//
// Alat ini membangun PDF dengan aturan geometri yang sama seperti
// lib/services/print_service.dart, lalu melaporkan angka-angka yang
// menentukan bagus-tidaknya hasil cetak: DPI efektif di atas kertas, berapa
// persen halaman terisi, apakah gambar diputar, dan berapa besar spool file
// yang dikirim ke printer.
//
// Ukuran halaman default (288x432 pt, margin 0) BUKAN tebakan — itu yang
// benar-benar dilaporkan driver EPSON L3210 lewat GetDeviceCaps setelah
// tools/setup-printer.ps1 dijalankan:
//
//   Device DPI     : 756 x 756       (720 x 1,05 -> bleed borderless)
//   PHYSICAL page  : 3024 x 4536 px  = 101,6 x 152,4 mm
//   PRINTABLE area : 3024 x 4536 px  = identik -> margin nol
//
// Untuk memeriksa ulang angka itu di mesin lain, jalankan dulu:
//   powershell -ExecutionPolicy Bypass -File tools\setup-printer.ps1
// lalu baca ukuran halaman dari baris log '[Print] halaman driver:' saat app
// mencetak.
//
// Jalankan:
//   dart run tools/bench_print.dart [strip.png] [lebar_pt] [tinggi_pt]
//
// Tanpa argumen, ia mengambil strip terbaru dari
//   Documents\Photobooth\History
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

// Harus sama dengan PrintService.jpegQuality.
const int kJpegQuality = 95;
// Harus sama dengan PrintService.minAcceptableDpi.
const double kMinAcceptableDpi = 280;

double fitScore(double imageRatio, double pageRatio) {
  if (imageRatio <= 0 || pageRatio <= 0) return 0;
  return imageRatio > pageRatio ? pageRatio / imageRatio : imageRatio / pageRatio;
}

File? latestStrip() {
  final home = Platform.environment['USERPROFILE'];
  if (home == null) return null;
  final dir = Directory('$home\\Documents\\Photobooth\\History');
  if (!dir.existsSync()) return null;
  final pngs = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.png'))
      .toList();
  if (pngs.isEmpty) return null;
  pngs.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
  return pngs.first;
}

Future<void> main(List<String> args) async {
  final file = args.isNotEmpty ? File(args[0]) : latestStrip();
  if (file == null || !file.existsSync()) {
    stderr.writeln('Tidak menemukan strip PNG. '
        'Beri path-nya: dart run tools/bench_print.dart <file.png>');
    exit(1);
  }

  // Ukuran halaman fisik dari driver, dalam point (1/72 inci).
  final pageW = args.length > 1 ? double.parse(args[1]) : 4.0 * 72.0;
  final pageH = args.length > 2 ? double.parse(args[2]) : 6.0 * 72.0;

  final source = file.readAsBytesSync();
  print('sumber   : ${file.path}');
  print('ukuran   : ${(source.length / 1024).round()} KB');

  final sw = Stopwatch()..start();
  final decoded = img.decodeImage(source);
  if (decoded == null) {
    stderr.writeln('Gagal decode gambar.');
    exit(1);
  }
  final tDecode = sw.elapsedMilliseconds;

  final pageRatio = pageW / pageH;
  final imageRatio = decoded.width / decoded.height;
  final rotate =
      fitScore(1 / imageRatio, pageRatio) > fitScore(imageRatio, pageRatio) + 0.001;

  sw.reset();
  final oriented = rotate ? img.copyRotate(decoded, angle: 90) : decoded;
  final jpeg = img.encodeJpg(oriented, quality: kJpegQuality);
  final tEncode = sw.elapsedMilliseconds;

  final w = oriented.width;
  final h = oriented.height;
  final finalRatio = w / h;
  final fit = fitScore(finalRatio, pageRatio);

  final pageWIn = pageW / 72.0;
  final pageHIn = pageH / 72.0;
  // Sisi mana yang menyentuh tepi kertas menentukan DPI efektif.
  final dpi = finalRatio > pageRatio ? w / pageWIn : h / pageHIn;

  sw.reset();
  final doc = pw.Document();
  final page = PdfPageFormat(pageW, pageH, marginAll: 0);
  doc.addPage(
    pw.Page(
      pageFormat: page,
      build: (_) => pw.Container(
        width: double.infinity,
        height: double.infinity,
        alignment: pw.Alignment.center,
        color: PdfColors.white,
        child: pw.Image(pw.MemoryImage(jpeg), fit: pw.BoxFit.contain),
      ),
    ),
  );
  final pdf = await doc.save();
  final tPdf = sw.elapsedMilliseconds;

  final out = File('${Directory.systemTemp.path}\\photobooth_print_check.pdf');
  out.writeAsBytesSync(pdf);

  // Berapa mm gambar benar-benar tercetak, dan berapa sisa putih di tepi.
  final printedWIn = finalRatio > pageRatio ? pageWIn : pageHIn * finalRatio;
  final printedHIn = finalRatio > pageRatio ? pageWIn / finalRatio : pageHIn;
  final slackW = (pageWIn - printedWIn) * 25.4;
  final slackH = (pageHIn - printedHIn) * 25.4;

  print('');
  print('-- gambar --------------------------------------------------');
  print('  piksel        : ${decoded.width}x${decoded.height} '
      '(rasio ${imageRatio.toStringAsFixed(4)})');
  print('  diputar 90    : $rotate'
      '${rotate ? '  -> jadi ${w}x$h' : ''}');
  print('');
  print('-- halaman driver ------------------------------------------');
  print('  point         : ${pageW.toStringAsFixed(1)} x ${pageH.toStringAsFixed(1)}');
  print('  inci          : ${pageWIn.toStringAsFixed(3)} x ${pageHIn.toStringAsFixed(3)}'
      '  (rasio ${pageRatio.toStringAsFixed(4)})');
  print('  mm            : ${(pageWIn * 25.4).toStringAsFixed(1)} x '
      '${(pageHIn * 25.4).toStringAsFixed(1)}');
  print('');
  print('-- hasil di kertas -----------------------------------------');
  print('  DPI efektif   : ${dpi.toStringAsFixed(0)}'
      '${dpi < kMinAcceptableDpi ? '   << DI BAWAH ${kMinAcceptableDpi.round()}, hasil akan lembek' : '   OK'}');
  print('  mengisi       : ${(fit * 100).toStringAsFixed(2)}% halaman'
      '${fit < 0.95 ? '   << rasio kertas & frame tidak cocok' : '   OK'}');
  print('  sisa putih    : ${slackW.toStringAsFixed(2)} mm horizontal, '
      '${slackH.toStringAsFixed(2)} mm vertikal');
  final maxSlack = math.max(slackW, slackH);
  if (maxSlack > 0.01) {
    print('                  (borderless Epson meluberkan ~2,5 mm per sisi,');
    print('                   jadi sisa ${maxSlack.toStringAsFixed(2)} mm ini '
        '${maxSlack < 2.5 ? 'TERTELAN bleed - tidak akan terlihat' : 'AKAN terlihat sebagai garis putih'})');
  }
  print('');
  print('-- biaya & keluaran ----------------------------------------');
  print('  decode PNG    : ${tDecode}ms');
  print('  encode JPEG   : ${tEncode}ms  -> ${(jpeg.length / 1024).round()} KB');
  print('  bangun PDF    : ${tPdf}ms  -> ${(pdf.length / 1024).round()} KB spool');
  print('  PDF disimpan  : ${out.path}');
  print('');
  print('Buka PDF itu untuk melihat persis apa yang dikirim ke printer.');
}
