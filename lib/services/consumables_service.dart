import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:photobooth_app/utils/ink_estimator.dart';
import 'config_service.dart';
import 'license_service.dart';

// ================================================================
// PELACAK BAHAN HABIS PAKAI (kertas & tinta)
//
// KENAPA AKUMULASI DULU, BARU KIRIM
// Pemakaian bahan adalah angka yang TIDAK BOLEH HILANG: kalau satu laporan
// gagal terkirim karena internet mati, stok kertas di dashboard langsung
// meleset dan tidak akan pernah benar lagi sampai dihitung ulang manual.
// Karena itu setiap cetakan pertama-tama ditambahkan ke berkas lokal
// (`consumables_pending.json`), baru dicoba dikirim. Server hanya menerima
// DELTA, dan pending baru dikurangi setelah server benar-benar mengonfirmasi.
// Aplikasi ditutup, listrik mati, atau internet putus berhari-hari —
// hitungannya tetap utuh dan menyusul terkirim.
//
// Pola ini sengaja dibuat mirip UploadQueueService yang sudah ada di repo.
// ================================================================

/// Akumulasi pemakaian yang belum dikonfirmasi server.
class _Pending {
  int sheets;
  double c, m, y, k;

  _Pending({
    this.sheets = 0,
    this.c = 0,
    this.m = 0,
    this.y = 0,
    this.k = 0,
  });

  bool get isEmpty => sheets == 0 && c == 0 && m == 0 && y == 0 && k == 0;

  void add(int addSheets, InkCoverage ink) {
    sheets += addSheets;
    c += ink.c * addSheets;
    m += ink.m * addSheets;
    y += ink.y * addSheets;
    k += ink.k * addSheets;
  }

  /// Kurangi apa yang sudah dikonfirmasi server. Dipakai alih-alih
  /// mengosongkan begitu saja, supaya cetakan yang terjadi SEMENTARA request
  /// sedang berjalan tidak ikut terhapus.
  void subtract(_Pending sent) {
    sheets -= sent.sheets;
    c -= sent.c;
    m -= sent.m;
    y -= sent.y;
    k -= sent.k;
    if (sheets < 0) sheets = 0;
    if (c < 0) c = 0;
    if (m < 0) m = 0;
    if (y < 0) y = 0;
    if (k < 0) k = 0;
  }

  _Pending copy() => _Pending(sheets: sheets, c: c, m: m, y: y, k: k);

  Map<String, dynamic> toJson() => {
        'sheets': sheets,
        'c': c,
        'm': m,
        'y': y,
        'k': k,
      };

  factory _Pending.fromJson(Map<String, dynamic> j) => _Pending(
        sheets: (j['sheets'] as num?)?.toInt() ?? 0,
        c: (j['c'] as num?)?.toDouble() ?? 0,
        m: (j['m'] as num?)?.toDouble() ?? 0,
        y: (j['y'] as num?)?.toDouble() ?? 0,
        k: (j['k'] as num?)?.toDouble() ?? 0,
      );
}

/// Kondisi bahan habis pakai menurut server.
class ConsumableStatus {
  final int paperRemaining;
  final int paperLoaded;
  final int paperLowThreshold;
  final double inkSinceRefill;
  final double inkPageCapacity;
  final Map<String, double> inkPerChannel;

  const ConsumableStatus({
    required this.paperRemaining,
    required this.paperLoaded,
    required this.paperLowThreshold,
    required this.inkSinceRefill,
    required this.inkPageCapacity,
    required this.inkPerChannel,
  });

  bool get paperLow => paperRemaining <= paperLowThreshold;

  /// 0..1 sisa tinta menurut estimasi. Hanya berarti kalau kapasitasnya
  /// sudah dikalibrasi.
  double get inkFraction {
    if (inkPageCapacity <= 0) return 1;
    final used = inkSinceRefill / inkPageCapacity;
    return (1 - used).clamp(0.0, 1.0);
  }

  factory ConsumableStatus.fromJson(Map<String, dynamic> j) =>
      ConsumableStatus(
        paperRemaining: (j['paper_remaining'] as num?)?.toInt() ?? 0,
        paperLoaded: (j['paper_loaded'] as num?)?.toInt() ?? 0,
        paperLowThreshold: (j['paper_low_threshold'] as num?)?.toInt() ?? 20,
        inkSinceRefill: (j['ink_since_refill'] as num?)?.toDouble() ?? 0,
        inkPageCapacity: (j['ink_page_capacity'] as num?)?.toDouble() ?? 0,
        inkPerChannel: {
          'c': (j['ink_c'] as num?)?.toDouble() ?? 0,
          'm': (j['ink_m'] as num?)?.toDouble() ?? 0,
          'y': (j['ink_y'] as num?)?.toDouble() ?? 0,
          'k': (j['ink_k'] as num?)?.toDouble() ?? 0,
        },
      );
}

class ConsumablesService {
  ConsumablesService._();
  static final ConsumablesService instance = ConsumablesService._();

  static const String _fileName = 'consumables_pending.json';

  _Pending? _pending;
  File? _file;
  bool _flushing = false;
  String? _hwid;

  String get _endpoint =>
      '${ConfigService().baseUrl}/api/photobooth/consumables';

  Future<File> _resolveFile() async {
    if (_file != null) return _file!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}Photobooth');
    if (!await dir.exists()) await dir.create(recursive: true);
    _file = File('${dir.path}${Platform.pathSeparator}$_fileName');
    return _file!;
  }

  Future<_Pending> _load() async {
    if (_pending != null) return _pending!;
    try {
      final f = await _resolveFile();
      if (await f.exists()) {
        final raw = jsonDecode(await f.readAsString());
        _pending = _Pending.fromJson((raw as Map).cast<String, dynamic>());
      } else {
        _pending = _Pending();
      }
    } catch (e) {
      debugPrint('[Consumables] gagal baca pending: $e');
      _pending = _Pending();
    }
    return _pending!;
  }

  Future<void> _save() async {
    try {
      final f = await _resolveFile();
      await f.writeAsString(jsonEncode(_pending!.toJson()));
    } catch (e) {
      debugPrint('[Consumables] gagal simpan pending: $e');
    }
  }

  Future<String> _resolveHwid() async =>
      _hwid ??= await LicenseService().getHardwareId();

  /// Catat [sheets] lembar tercetak dengan liputan tinta [ink] per lembar.
  ///
  /// Dipanggil dari PrintService setelah cetak BERHASIL. Selalu tercatat
  /// lokal lebih dulu, jadi aman dipanggil walau server sedang tidak bisa
  /// dihubungi.
  Future<void> recordPrint({
    required int sheets,
    required InkCoverage ink,
  }) async {
    if (sheets <= 0) return;
    final p = await _load();
    p.add(sheets, ink);
    await _save();
    debugPrint('[Consumables] +$sheets lembar, tinta $ink '
        '-> pending ${p.sheets} lembar');
    await flush();
  }

  /// Kirim akumulasi yang tertunda ke server. Aman dipanggil kapan saja;
  /// tidak melakukan apa-apa kalau tidak ada yang tertunda atau sedang ada
  /// pengiriman lain berjalan.
  Future<void> flush() async {
    if (_flushing) return;
    final p = await _load();
    if (p.isEmpty) return;

    _flushing = true;
    // Salin dulu: cetakan yang terjadi selama request berjalan akan masuk ke
    // _pending dan TIDAK boleh ikut terhapus saat server membalas OK.
    final sending = p.copy();
    try {
      final hwid = await _resolveHwid();
      final res = await http
          .post(
            Uri.parse('$_endpoint/report'),
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'hwid': hwid,
              'sheets': sending.sheets,
              'ink': {
                'c': sending.c,
                'm': sending.m,
                'y': sending.y,
                'k': sending.k,
              },
            }),
          )
          .timeout(const Duration(seconds: 12));

      if (res.statusCode == 200) {
        p.subtract(sending);
        await _save();
        debugPrint('[Consumables] terkirim: ${sending.sheets} lembar. '
            'Sisa pending ${p.sheets}.');
      } else {
        debugPrint('[Consumables] server menolak (${res.statusCode}): '
            '${res.body}. Pending dipertahankan.');
      }
    } catch (e) {
      debugPrint('[Consumables] gagal kirim: $e. Pending dipertahankan.');
    } finally {
      _flushing = false;
    }
  }

  /// Ambil status terkini dari server (untuk ditampilkan di app).
  Future<ConsumableStatus?> fetchStatus() async {
    try {
      final hwid = await _resolveHwid();
      final res = await http.get(
        Uri.parse('$_endpoint/status?hwid=${Uri.encodeComponent(hwid)}'),
        headers: const {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] != true || body['data'] == null) return null;
      return ConsumableStatus.fromJson(
          (body['data'] as Map).cast<String, dynamic>());
    } catch (e) {
      debugPrint('[Consumables] gagal ambil status: $e');
      return null;
    }
  }

  /// Laporkan kondisi printer apa adanya (PaperOut, offline, dsb) supaya
  /// dashboard tahu tanpa menunggu cetakan berikutnya.
  Future<void> reportPrinterState({
    required String status,
    required bool blocked,
    String? reason,
    int queued = 0,
  }) async {
    try {
      final hwid = await _resolveHwid();
      await http
          .post(
            Uri.parse('$_endpoint/printer-state'),
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'hwid': hwid,
              'printer_status': status,
              'printer_blocked': blocked,
              'printer_reason': reason,
              'queued_jobs': queued,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('[Consumables] gagal lapor status printer: $e');
    }
  }
}
