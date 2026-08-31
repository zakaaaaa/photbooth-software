import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:photobooth_app/services/consumables_service.dart';
import 'package:photobooth_app/utils/ink_estimator.dart';
import 'package:photobooth_app/utils/print_color.dart';

// ================================================================
// PRINT SERVICE
//
// PEMBAGIAN TUGAS YANG WAJIB DIPAHAMI SEBELUM MENGUBAH FILE INI
// (diukur di mesin photobooth + EPSON L3210, 2026-08-26):
//
// Media type, kualitas cetak, dan borderless TIDAK BISA diatur dari Dart.
// package:printing di Windows hanya mengisi DEVMODE untuk orientasi dan
// ukuran kertas (lihat printing-5.14.2/windows/print_job.cpp), dan dengan
// usePrinterSettings:true ia mengirim `dm = nullptr` sehingga Windows
// memakai DEFAULT DRIVER apa adanya.
//
//   Driver printer (tools/setup-printer.ps1)  -> kertas, media type,
//                                                kualitas, borderless
//   File ini                                  -> ukuran & isi halaman PDF
//   FrameComposer.targetLongSidePx            -> resolusi piksel gambar
//
// Karena itu file ini SENGAJA memakai usePrinterSettings:true dan mengambil
// ukuran halaman dari argumen `format` yang dikirim balik driver lewat
// onLayout — bukan dari konstanta. Kode lama membuang argumen itu dan
// memaksa PdfPageFormat 4x6 padahal default driver-nya Letter, sehingga
// halaman 4x6 di-fit ke lembar Letter dengan profil tinta kertas biasa.
//
// Soal borderless: driver Epson SUDAH melakukan bleed-nya sendiri. Diukur
// lewat GetDeviceCaps, mode borderless menaikkan DC dari 720 ke 756 dpi —
// tepat 1,05x — lalu meluberkan 5% itu ke luar kertas. Jadi JANGAN memakai
// BoxFit.cover atau menambah overfill di sini; nanti gambarnya terpotong
// dua kali. BoxFit.contain adalah yang benar.
// ================================================================

/// Hasil penyiapan gambar untuk satu ukuran halaman tertentu.
class _PreparedImage {
  final Uint8List bytes;
  final int width;
  final int height;
  final bool rotated;

  /// Estimasi tinta untuk SATU lembar gambar ini.
  final InkCoverage ink;

  const _PreparedImage({
    required this.bytes,
    required this.width,
    required this.height,
    required this.rotated,
    required this.ink,
  });
}

/// Dijalankan di isolate lewat compute(). Decode PNG hasil FrameComposer
/// (2,2MP — sekitar 300ms, cukup untuk terasa nge-freeze kalau dibiarkan di
/// isolate UI seperti kode lama) lalu keluarkan JPEG.
///
/// Kenapa JPEG dan bukan PNG apa adanya: PdfImage.file di package:pdf
/// menempelkan byte JPEG APA ADANYA ke dalam PDF (DCTDecode, tanpa diproses
/// ulang), sementara PNG dibongkar jadi RGB mentah + Flate — hasilnya spool
/// file berkali-kali lebih besar dan satu kali decode package:image lagi di
/// dalam pdf. Encoder-nya default yuv444 (tanpa chroma subsampling) jadi
/// tepian warna tetap tajam.
///
/// Mengembalikan Map, bukan Uint8List, karena satu lintasan isolate ini
/// menghasilkan DUA hal: bytes JPEG untuk printer dan estimasi liputan
/// tintanya. Memisahkannya jadi dua compute() berarti decode gambar dua kali.
Map<String, dynamic> prepareForPageEntry(Map<String, dynamic> args) {
  final Uint8List source = args['bytes'] as Uint8List;
  final bool rotate = args['rotate'] as bool;
  final int rawW = args['rawW'] as int;
  final int rawH = args['rawH'] as int;

  // rawW > 0 berarti sumbernya RGBA mentah langsung dari kanvas
  // (FrameComposer.composeForPrint) — tidak perlu decode sama sekali.
  // Jalur berbentuk PNG/JPEG masih dipakai cetak ulang dari History.
  final decoded = rawW > 0
      ? img.Image.fromBytes(
          width: rawW,
          height: rawH,
          bytes: source.buffer,
          order: img.ChannelOrder.rgba,
        )
      : img.decodeImage(source);

  if (decoded == null) {
    return {'jpeg': source, 'ink': InkCoverage.zero.toJson()};
  }

  final oriented = rotate ? img.copyRotate(decoded, angle: 90) : decoded;

  // Koreksi cetak diterapkan HANYA di sini — di salinan yang menuju printer.
  // Bytes asli yang di-upload dan diunduh pelanggan tidak tersentuh.
  final corrected = applyPrintCorrection(
    oriented,
    PrintCorrection(
      saturation: args['sat'] as double,
      contrast: args['con'] as double,
      gamma: args['gam'] as double,
    ),
  );

  // Dihitung SETELAH koreksi — itulah gambar yang benar-benar kena tinta.
  // Selisihnya nyata dan arahnya tidak selalu intuitif: pada koreksi yang
  // dipakai sekarang (sat 1,30 + gamma 1,15) total tinta justru turun 4,3%,
  // karena pencerahan gamma memangkas kanal K lebih banyak daripada tambahan
  // saturasi di CMY. Diukur pada strip 1200x1801, 2026-08-27.
  final ink = estimateInkCoverage(corrected);

  return {
    'jpeg': Uint8List.fromList(
      img.encodeJpg(corrected, quality: PrintService.jpegQuality),
    ),
    'ink': ink.toJson(),
  };
}

/// Kondisi printer hasil pemeriksaan langsung ke spooler Windows.
class PrinterHealth {
  final String status;
  final int jobCount;

  /// true = job baru akan masuk antrian tapi TIDAK akan tercetak.
  final bool blocked;

  /// Kalimat siap tampil untuk operator, null kalau sehat.
  final String? reason;

  const PrinterHealth({
    required this.status,
    required this.jobCount,
    required this.blocked,
    this.reason,
  });

  static const PrinterHealth unknown =
      PrinterHealth(status: 'Unknown', jobCount: 0, blocked: false);
}

class PrintService {
  static final PrintService _instance = PrintService._internal();
  factory PrintService() => _instance;
  PrintService._internal();

  /// Sebab kegagalan cetak terakhir, siap ditampilkan ke operator.
  /// null kalau cetak terakhir berhasil.
  String? lastPrintError;

  /// Status spooler yang berarti job akan MENUMPUK, bukan tercetak.
  ///
  /// Daftar ini ada karena `Printer.isAvailable` dari package:printing TIDAK
  /// bisa dipakai untuk ini. Mask-nya di windows/print_job.cpp hanya
  /// NOT_AVAILABLE | ERROR | OFFLINE | PAUSED — PRINTER_STATUS_PAPER_OUT
  /// tidak termasuk. Akibatnya (kejadian nyata 21-24 Agustus 2026): printer
  /// nyangkut PaperOut sejak 21 Agustus, isAvailable tetap true, 8 sesi
  /// pelanggan masuk antrian dan tidak satu pun keluar — sementara app
  /// menampilkan "Terkirim ke printer!" setiap kali.
  /// Kunci = nilai enum PrinterStatus dari Get-Printer, huruf kecil semua.
  static const Map<String, String> _blockingStatuses = {
    'paperout': 'Kertas habis atau belum terpasang benar',
    'paperjam': 'Kertas macet di dalam printer',
    'paperproblem': 'Ada masalah kertas',
    'manualfeed': 'Printer menunggu kertas dimasukkan manual',
    'outputbinfull': 'Penampung hasil cetak penuh',
    'offline': 'Printer offline',
    'error': 'Printer dalam kondisi error',
    'notavailable': 'Printer tidak tersedia',
    'paused': 'Antrian printer sedang di-pause',
    'dooropen': 'Penutup printer terbuka',
    'userinterventionrequired': 'Printer butuh tindakan manual',
    'notoner': 'Tinta habis',
    'outofmemory': 'Memori printer penuh',
  };

  /// Tanya langsung ke spooler Windows lewat PowerShell — satu-satunya sumber
  /// yang jujur soal PaperOut. Pola shell-out ke PowerShell ini sudah dipakai
  /// di diagnostic_page untuk deteksi kamera.
  ///
  /// Sengaja TIDAK fatal: kalau probe-nya sendiri gagal, kembalikan `unknown`
  /// dan biarkan cetak jalan. Lebih baik mencoba mencetak daripada menolak
  /// sesi pelanggan gara-gara alat diagnostiknya yang bermasalah.
  Future<PrinterHealth> checkHealth(String printerName) async {
    if (!Platform.isWindows) return PrinterHealth.unknown;
    try {
      // Sengaja TANPA tanda kutip ganda di dalam perintah, dan hasilnya
      // dikeluarkan sebagai dua baris polos. Menyisipkan `"` ke dalam
      // argumen `powershell -Command` gampang rusak oleh cara Windows
      // menyusun ulang command line dari daftar argumen.
      final escaped = printerName.replaceAll("'", "''");
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r"$p = Get-Printer -Name '" +
            escaped +
            r"' -ErrorAction Stop; $p.PrinterStatus; $p.JobCount",
      ]).timeout(const Duration(seconds: 6));

      final lines = result.stdout
          .toString()
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      if (lines.length < 2) return PrinterHealth.unknown;

      final status = lines[0];
      final jobCount = int.tryParse(lines[1]) ?? 0;

      // PrinterStatus bisa gabungan, mis. "Normal, PaperOut".
      String? reason;
      for (final token in status.toLowerCase().split(RegExp(r'[,\s]+'))) {
        final hit = _blockingStatuses[token];
        if (hit != null) {
          reason = hit;
          break;
        }
      }

      return PrinterHealth(
        status: status,
        jobCount: jobCount,
        blocked: reason != null,
        reason: reason,
      );
    } catch (e) {
      debugPrint('[Print] gagal cek status printer: $e');
      return PrinterHealth.unknown;
    }
  }

  /// Kualitas JPEG yang ditempelkan ke PDF. 95 sudah visually lossless untuk
  /// cetak — driver tetap melakukan halftone/dither di 756 dpi, jauh lebih
  /// kasar daripada artefak JPEG q95.
  static const int jpegQuality = 95;

  /// Koreksi warna yang diterapkan HANYA pada salinan yang menuju printer.
  /// Bytes asli yang di-upload / diunduh pelanggan tidak pernah tersentuh.
  ///
  /// Nilai ini BUKAN tebakan — dipilih dari lembar uji 6 varian yang dicetak
  /// di kertas sungguhan lewat jalur cetak ini juga (varian 4, 2026-08-27).
  /// Cetakan selalu lebih datar daripada layar karena layar memancarkan
  /// cahaya sendiri sementara kertas hanya memantulkan cahaya ruangan;
  /// angka ini yang mengkompensasinya.
  ///
  /// Untuk menyetel ulang (ganti kertas, ganti tinta, ganti printer):
  ///   dart run tools/print_calibration.dart
  /// lalu cetak entri "kalibrasi-..." lewat tombol Cetak Ulang di halaman
  /// diagnostik, dan pasang nomor yang paling pas di sini.
  static PrintCorrection printCorrection = const PrintCorrection(
    saturation: 1.30,
    gamma: 1.15,
  );

  /// DPI minimum yang dianggap layak cetak. Di bawah ini hasil terasa lembek,
  /// dan peringatan dimunculkan di log supaya ketahuan saat debugging alih-alih
  /// baru terlihat setelah kertas terpakai.
  static const double minAcceptableDpi = 280;

  /// Printer virtual — jangan pernah jadi fallback otomatis. Tanpa daftar ini,
  /// `printers.first` bisa saja "Microsoft Print to PDF" dan hasil sesi
  /// pelanggan hilang ke sebuah file tanpa ada yang sadar.
  static const List<String> _virtualPrinterMarkers = [
    'print to pdf',
    'onenote',
    'xps document writer',
    'fax',
    'pdfcreator',
    'send to',
  ];

  static bool _isVirtual(Printer p) {
    final n = p.name.toLowerCase();
    return _virtualPrinterMarkers.any(n.contains);
  }

  /// Seberapa penuh gambar berasio [imageRatio] mengisi halaman berasio
  /// [pageRatio] dengan BoxFit.contain. 1.0 = pas sempurna.
  static double _fitScore(double imageRatio, double pageRatio) {
    if (imageRatio <= 0 || pageRatio <= 0) return 0;
    return imageRatio > pageRatio
        ? pageRatio / imageRatio
        : imageRatio / pageRatio;
  }

  /// Alur cetak utama photobooth.
  ///
  /// Sengaja TIDAK menerima BuildContext: dulu ada tapi tidak pernah dipakai,
  /// dan keberadaannya memicu peringatan use_build_context_synchronously di
  /// pemanggil yang harus meng-await render resolusi tinggi lebih dulu.
  Future<bool> printStrip(
    Uint8List imageBytes, {
    String sessionUuid = 'history',
    int copies = 1,
    String printerKeyword = 'epson',
    String paperSize = '4R',
    bool allowSystemDialogFallback = true,
    // Diisi kalau [imageBytes] adalah RGBA mentah dari FrameComposer, bukan
    // berkas ter-encode. Menghindari satu putaran encode+decode PNG penuh.
    int rawWidth = 0,
    int rawHeight = 0,
  }) async {
    if (copies <= 0) return false;

    final bool isRaw = rawWidth > 0 && rawHeight > 0;
    // Untuk berkas ter-encode, ukuran dibaca dari header saja — tidak perlu
    // decode penuh hanya untuk tahu dimensinya.
    final probe =
        isRaw ? null : img.findDecoderForData(imageBytes)?.startDecode(imageBytes);
    final srcW = isRaw ? rawWidth : (probe?.width ?? 1);
    final srcH = isRaw ? rawHeight : (probe?.height ?? 1);

    // Dipakai sebagai tebakan awal dan untuk platform non-Windows. Di Windows
    // nilai sebenarnya selalu datang dari driver lewat onLayout.
    final expectedFormat = _expectedFormat(paperSize);

    // Cache: penyiapan gambar cukup sekali walau dicetak beberapa lembar.
    _PreparedImage? prepared;
    PdfPageFormat? preparedFor;

    Future<Uint8List> buildDoc(PdfPageFormat driverFormat) async {
      // Pakai margin asli dari driver. Saat borderless margin-nya 0 (sudah
      // diverifikasi: PHYSICALOFFSET 0,0), jadi gambar mengisi penuh halaman.
      // Kalau borderless dimatikan, margin unprintable-nya dihormati sehingga
      // tepi desain tidak terpotong diam-diam.
      final page = PdfPageFormat(
        driverFormat.width,
        driverFormat.height,
        marginLeft: driverFormat.marginLeft,
        marginTop: driverFormat.marginTop,
        marginRight: driverFormat.marginRight,
        marginBottom: driverFormat.marginBottom,
      );

      if (prepared == null || preparedFor != page) {
        final pageRatio = page.availableWidth / page.availableHeight;
        final imageRatio = srcW / srcH;

        // Putar HANYA kalau memutar benar-benar mengisi halaman lebih banyak.
        // Kode lama memutar setiap gambar landscape tanpa melihat halamannya,
        // jadi strip landscape di kertas landscape pun ikut terputar dan malah
        // mengecil.
        final rotate = _fitScore(1 / imageRatio, pageRatio) >
            _fitScore(imageRatio, pageRatio) + 0.001;

        final result = await compute(prepareForPageEntry, <String, dynamic>{
          'bytes': imageBytes,
          'rotate': rotate,
          'rawW': isRaw ? rawWidth : 0,
          'rawH': isRaw ? rawHeight : 0,
          // Dikirim sebagai angka polos, bukan objek — argumen compute()
          // harus bisa diserialisasi antar isolate.
          'sat': printCorrection.saturation,
          'con': printCorrection.contrast,
          'gam': printCorrection.gamma,
        });

        prepared = _PreparedImage(
          bytes: result['jpeg'] as Uint8List,
          width: rotate ? srcH : srcW,
          height: rotate ? srcW : srcH,
          rotated: rotate,
          ink: InkCoverage.fromJson(
              (result['ink'] as Map).cast<String, dynamic>()),
        );
        preparedFor = page;

        _logGeometry(paperSize: paperSize, page: page, prepared: prepared!);
      }

      final doc = pw.Document();
      final image = pw.MemoryImage(prepared!.bytes);
      doc.addPage(
        pw.Page(
          pageFormat: page,
          build: (_) => pw.Container(
            width: double.infinity,
            height: double.infinity,
            alignment: pw.Alignment.center,
            color: PdfColors.white,
            // contain, BUKAN cover — driver sudah menambah bleed 5% sendiri.
            child: pw.Image(image, fit: pw.BoxFit.contain),
          ),
        ),
      );
      return doc.save();
    }

    lastPrintError = null;
    final targetPrinter = await _resolvePrinter(printerKeyword);
    bool printSuccess = false;
    int sheetsPrinted = 0;

    if (targetPrinter != null) {
      debugPrint('[Print] printer terpilih: ${targetPrinter.name} '
          '(default=${targetPrinter.isDefault}, '
          'tersedia=${targetPrinter.isAvailable})');

      // PRA-CETAK: jangan pernah kirim job ke antrian yang tersumbat.
      // Job yang masuk ke sana hanya menumpuk diam-diam.
      final health = await checkHealth(targetPrinter.name);
      debugPrint('[Print] status spooler: ${health.status} '
          '(antrian ${health.jobCount} job)');

      if (health.blocked) {
        lastPrintError = '${health.reason}. '
            'Perbaiki dulu di printer, cetakan tidak akan keluar.';
        debugPrint('[Print] DIBATALKAN: ${health.status} -> ${health.reason}. '
            'Job sengaja tidak dikirim supaya tidak menumpuk di antrian.');
        // Dashboard perlu tahu SEKARANG, bukan menunggu cetakan berikutnya —
        // justru saat printer bermasalah inilah operator harus ditegur.
        unawaited(ConsumablesService.instance.reportPrinterState(
          status: health.status,
          blocked: true,
          reason: health.reason,
          queued: health.jobCount,
        ));
        return false;
      }

      // Antrian yang terus menebal padahal printer "normal" adalah gejala
      // job zombie seperti yang terjadi 21-24 Agustus 2026.
      if (health.jobCount >= 3) {
        debugPrint('[Print] PERINGATAN: ${health.jobCount} job masih mengantre '
            'sebelum job ini dikirim. Kalau cetakan tidak keluar, bersihkan '
            'antrian printer — kemungkinan ada job yang nyangkut.');
      }

      try {
        for (int i = 0; i < copies; i++) {
          final res = await Printing.directPrintPdf(
            printer: targetPrinter,
            onLayout: buildDoc,
            format: expectedFormat,
            // WAJIB true: inilah yang membuat kertas 4x6 / photo glossy /
            // HighQuality / borderless dari default driver ikut terpakai.
            // Lihat tools/setup-printer.ps1.
            usePrinterSettings: true,
          );
          if (res) {
            printSuccess = true;
            // Dihitung per lembar, bukan sekali di akhir — kalau lembar ke-3
            // dari 5 gagal, stok yang dilaporkan tetap benar.
            sheetsPrinted++;
          }
          if (i < copies - 1) {
            await Future.delayed(const Duration(milliseconds: 500));
          }
        }
      } catch (e) {
        lastPrintError = 'Gagal mengirim ke printer: $e';
        debugPrint('[Print] directPrintPdf error: $e');
      }

      // PASCA-CETAK: directPrintPdf hanya menjamin job berhasil DI-SPOOL,
      // bukan tercetak. Beri jeda sebentar lalu pastikan printer tidak
      // langsung jatuh ke kondisi error begitu job masuk.
      if (printSuccess) {
        await Future.delayed(const Duration(milliseconds: 1200));
        final after = await checkHealth(targetPrinter.name);
        unawaited(ConsumablesService.instance.reportPrinterState(
          status: after.status,
          blocked: after.blocked,
          reason: after.reason,
          queued: after.jobCount,
        ));
        if (after.blocked) {
          lastPrintError = '${after.reason}. '
              'Job sudah masuk antrian tapi belum tercetak.';
          debugPrint('[Print] job ter-spool tapi printer jadi '
              '${after.status} -> ${after.reason}');
          printSuccess = false;
        } else {
          debugPrint('[Print] pasca-cetak OK: ${after.status} '
              '(antrian ${after.jobCount} job)');
        }
      }
    } else {
      lastPrintError =
          'Printer "$printerKeyword" tidak ditemukan. Cek kabel dan daya.';
      debugPrint('[Print] tidak ada printer fisik yang cocok dengan '
          '"$printerKeyword" — cetak langsung dilewati.');
    }

    if (!printSuccess && allowSystemDialogFallback) {
      try {
        await Printing.layoutPdf(
          onLayout: buildDoc,
          name: 'Photobooth_$sessionUuid',
          format: expectedFormat,
          usePrinterSettings: true,
        );
        printSuccess = true;
      } catch (e) {
        debugPrint('[Print] layoutPdf fallback error: $e');
      }
    }

    // Catat pemakaian HANYA untuk lembar yang benar-benar tercetak, dan hanya
    // kalau pemeriksaan pasca-cetak tidak membatalkannya. Job yang mengendap
    // di antrian tidak memakai kertas maupun tinta — menghitungnya akan
    // membuat stok di dashboard meleset ke bawah terus.
    if (printSuccess && sheetsPrinted > 0 && prepared != null) {
      unawaited(ConsumablesService.instance.recordPrint(
        sheets: sheetsPrinted,
        ink: prepared!.ink,
      ));
    }

    return printSuccess;
  }

  /// Pilih printer fisik. Prioritas: cocok kata kunci & siap -> cocok kata
  /// kunci -> default -> printer fisik pertama yang siap. Printer virtual
  /// tidak pernah dipilih otomatis.
  Future<Printer?> _resolvePrinter(String keyword) async {
    try {
      final printers = await Printing.listPrinters();
      final physical = printers.where((p) => !_isVirtual(p)).toList();
      if (physical.isEmpty) return null;

      final key = keyword.trim().toLowerCase();
      final matches = key.isEmpty
          ? const <Printer>[]
          : physical.where((p) => p.name.toLowerCase().contains(key)).toList();

      Printer? pick(List<Printer> list) {
        for (final p in list) {
          if (p.isAvailable) return p;
        }
        return list.isEmpty ? null : list.first;
      }

      return pick(matches) ??
          pick(physical.where((p) => p.isDefault).toList()) ??
          pick(physical);
    } catch (e) {
      debugPrint('[Print] gagal scan printer: $e');
      return null;
    }
  }

  /// Perkiraan ukuran halaman dari setelan aplikasi. Di Windows ini hanya
  /// tebakan awal; ukuran final selalu diambil dari driver di onLayout.
  PdfPageFormat _expectedFormat(String paperSize) {
    switch (paperSize.toUpperCase()) {
      case 'A4':
        return PdfPageFormat.a4.copyWith(
            marginLeft: 0, marginTop: 0, marginRight: 0, marginBottom: 0);
      case 'A5':
        return PdfPageFormat.a5.copyWith(
            marginLeft: 0, marginTop: 0, marginRight: 0, marginBottom: 0);
      case '4R':
      default:
        // 4R = 4x6 inci = 101,6 x 152,4 mm, sama persis dengan
        // ns0000:Fullsize4x6 di driver Epson.
        return const PdfPageFormat(4.0 * 72.0, 6.0 * 72.0, marginAll: 0);
    }
  }

  /// Satu baris log yang memuat semua yang dibutuhkan saat hasil cetak
  /// bermasalah: ukuran halaman yang BENAR-BENAR dilaporkan driver, dan DPI
  /// efektif gambar di atas kertas itu.
  void _logGeometry({
    required String paperSize,
    required PdfPageFormat page,
    required _PreparedImage prepared,
  }) {
    final contentWIn = page.availableWidth / 72.0;
    final contentHIn = page.availableHeight / 72.0;
    final imageRatio = prepared.width / prepared.height;
    final pageRatio = page.availableWidth / page.availableHeight;
    final fit = _fitScore(imageRatio, pageRatio);

    // Sisi mana yang menyentuh tepi menentukan DPI efektif.
    final dpi = imageRatio > pageRatio
        ? prepared.width / contentWIn
        : prepared.height / contentHIn;

    debugPrint(
      '[Print] halaman driver: '
      '${contentWIn.toStringAsFixed(2)}x${contentHIn.toStringAsFixed(2)} in '
      '(${(contentWIn * 25.4).toStringAsFixed(1)}x'
      '${(contentHIn * 25.4).toStringAsFixed(1)} mm) '
      'margin=${page.marginLeft.toStringAsFixed(1)}/'
      '${page.marginTop.toStringAsFixed(1)}/'
      '${page.marginRight.toStringAsFixed(1)}/'
      '${page.marginBottom.toStringAsFixed(1)}pt | '
      'gambar ${prepared.width}x${prepared.height} '
      'rotated=${prepared.rotated} | '
      'DPI efektif=${dpi.toStringAsFixed(0)} | '
      'fit=${(fit * 100).toStringAsFixed(1)}% | '
      'koreksi ${printCorrection.isIdentity ? "tidak ada" : printCorrection}',
    );

    if (dpi < minAcceptableDpi) {
      debugPrint('[Print] PERINGATAN: DPI efektif ${dpi.toStringAsFixed(0)} '
          'di bawah ${minAcceptableDpi.toStringAsFixed(0)} — hasil cetak akan '
          'terlihat lembek. Naikkan FrameComposer.targetLongSidePx.');
    }
    if (fit < 0.95) {
      debugPrint('[Print] PERINGATAN: gambar hanya mengisi '
          '${(fit * 100).toStringAsFixed(0)}% halaman. Rasio kertas dan rasio '
          'frame tidak cocok — periksa apakah default driver masih di '
          '$paperSize (jalankan tools/setup-printer.ps1).');
    }
  }
}
