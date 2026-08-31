import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:photobooth_app/screens/splash_screen.dart';
import 'package:photobooth_app/services/license_service.dart';
import 'package:photobooth_app/services/config_service.dart';
import 'package:photobooth_app/services/history_service.dart';
import 'package:photobooth_app/services/print_service.dart';

class DiagnosticPage extends StatefulWidget {
  const DiagnosticPage({super.key});

  @override
  State<DiagnosticPage> createState() => _DiagnosticPageState();
}

class _DiagnosticPageState extends State<DiagnosticPage>
    with TickerProviderStateMixin {
  // ── State ──
  String _hwid = '';

  // Camera
  _CheckStatus _cameraStatus = _CheckStatus.loading;
  String _cameraMessage = 'Mendeteksi kamera...';

  // Printer
  _CheckStatus _printerStatus = _CheckStatus.loading;
  String _printerMessage = 'Mendeteksi printer...';
  List<_PrinterInfo> _printers = [];

  // History
  _CheckStatus _photosStatus = _CheckStatus.loading;
  String _photosMessage = 'Mengambil riwayat strip...';
  List<_HistoryItem> _historyItems = [];

  // Server
  _CheckStatus _serverStatus = _CheckStatus.loading;
  String _serverMessage = 'Mengecek koneksi server...';

  // Animation
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;
  late AnimationController _pulseController;

  String get _backendUrl => ConfigService().baseUrl;

  @override
  void initState() {
    super.initState();

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    _fadeController.forward();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _runAllChecks();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  // ================================================================
  // RUN ALL CHECKS
  // ================================================================
  Future<void> _runAllChecks() async {
    // Get HWID first — needed for photo fetch
    final licenseService = LicenseService();
    _hwid = await licenseService.getHardwareId();

    // Run checks in parallel
    await Future.wait([
      _checkCamera(),
      _checkPrinters(),
      _checkServer(),
    ]);

    // Photos depend on server being reachable
    await _checkRecentPhotos();
  }

  // ================================================================
  // 1. CAMERA CHECK
  // ================================================================
  Future<void> _checkCamera() async {
    try {
      if (Platform.isMacOS) {
        // camera_macos — we can't list cameras without initializing the view,
        // so we check via system_profiler CLI
        final result =
            await Process.run('system_profiler', ['SPCameraDataType']);
        final output = result.stdout.toString();

        if (output.contains('Camera') ||
            output.contains('FaceTime') ||
            output.contains('USB')) {
          // Extract camera name
          final lines = output.split('\n');
          String name = 'Camera Terdeteksi';
          for (final line in lines) {
            final trimmed = line.trim();
            if (trimmed.isNotEmpty &&
                !trimmed.startsWith('Camera') &&
                !trimmed.contains(':') &&
                trimmed != 'Camera:') {
              // Usually the camera name is an indented line without a colon
            }
            if (trimmed.contains('Model ID:') ||
                trimmed.contains('Unique ID:')) {
              continue;
            }
            // Find the first line that looks like a device name
            if (trimmed.isNotEmpty &&
                !trimmed.startsWith('SPCameraDataType') &&
                !trimmed.contains('Model ID') &&
                !trimmed.contains('Unique ID') &&
                !trimmed.contains(':') &&
                lines.indexOf(line) > 1) {
              name = trimmed;
              break;
            }
          }

          if (mounted) {
            setState(() {
              _cameraStatus = _CheckStatus.success;
              _cameraMessage = name;
            });
          }
        } else {
          if (mounted) {
            setState(() {
              _cameraStatus = _CheckStatus.error;
              _cameraMessage = 'Tidak ada kamera terdeteksi';
            });
          }
        }
      } else if (Platform.isWindows) {
        // Windows — use PowerShell to detect cameras
        final result = await Process.run('powershell', [
          '-Command',
          'Get-PnpDevice -Class Camera -Status OK | Select-Object -ExpandProperty FriendlyName'
        ]);
        final output = result.stdout.toString().trim();

        if (output.isNotEmpty && !output.contains('Error')) {
          final cameras = output
              .split('\n')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList();

          if (mounted) {
            setState(() {
              _cameraStatus = _CheckStatus.success;
              _cameraMessage =
                  '${cameras.first}${cameras.length > 1 ? ' (+${cameras.length - 1} lainnya)' : ''}';
            });
          }
        } else {
          // Fallback: try WMIC
          final wmic = await Process.run('cmd', [
            '/c',
            'wmic path Win32_PnPEntity where "PNPClass=\'Camera\' OR PNPClass=\'Image\'" get Name /format:list'
          ]);
          final wmicOutput = wmic.stdout.toString().trim();
          final nameMatch = RegExp(r'Name=(.+)').firstMatch(wmicOutput);

          if (nameMatch != null) {
            if (mounted) {
              setState(() {
                _cameraStatus = _CheckStatus.success;
                _cameraMessage = nameMatch.group(1)!.trim();
              });
            }
          } else {
            if (mounted) {
              setState(() {
                _cameraStatus = _CheckStatus.error;
                _cameraMessage = 'Tidak ada kamera terdeteksi';
              });
            }
          }
        }
      } else {
        if (mounted) {
          setState(() {
            _cameraStatus = _CheckStatus.error;
            _cameraMessage = 'Platform tidak didukung';
          });
        }
      }
    } catch (e) {
      debugPrint('❌ Camera check error: $e');
      if (mounted) {
        setState(() {
          _cameraStatus = _CheckStatus.error;
          _cameraMessage = 'Gagal mendeteksi kamera: $e';
        });
      }
    }
  }

  // ================================================================
  // 2. PRINTER CHECK
  // ================================================================
  Future<void> _checkPrinters() async {
    try {
      final printers = await Printing.listPrinters();

      if (printers.isEmpty) {
        if (mounted) {
          setState(() {
            _printerStatus = _CheckStatus.error;
            _printerMessage = 'Tidak ada printer terdeteksi';
          });
        }
        return;
      }

      final printerList = printers.map((p) {
        return _PrinterInfo(
          name: p.name,
          isDefault: p.isDefault,
          isAvailable: p.isAvailable,
        );
      }).toList();

      // Sort: available + default first
      printerList.sort((a, b) {
        if (a.isDefault && !b.isDefault) return -1;
        if (!a.isDefault && b.isDefault) return 1;
        if (a.isAvailable && !b.isAvailable) return -1;
        return 0;
      });

      if (mounted) {
        setState(() {
          _printers = printerList;
          _printerStatus = printerList.any((p) => p.isAvailable)
              ? _CheckStatus.success
              : _CheckStatus.warning;
          _printerMessage = printerList.any((p) => p.isAvailable)
              ? '${printerList.where((p) => p.isAvailable).length} printer tersedia'
              : 'Printer ditemukan tapi tidak tersedia';
        });
      }
    } catch (e) {
      debugPrint('❌ Printer check error: $e');
      if (mounted) {
        setState(() {
          _printerStatus = _CheckStatus.error;
          _printerMessage = 'Gagal mendeteksi printer: $e';
        });
      }
    }
  }

  // ================================================================
  // 3. SERVER CHECK
  // ================================================================
  Future<void> _checkServer() async {
    try {
      final response = await http
          .get(Uri.parse('$_backendUrl/api/frames?hwid=warmup'))
          .timeout(const Duration(seconds: 8));

      if (mounted) {
        if (response.statusCode == 200 ||
            response.statusCode == 422 ||
            response.statusCode == 404) {
          setState(() {
            _serverStatus = _CheckStatus.success;
            _serverMessage = 'Server terhubung (OK)';
          });
        } else {
          setState(() {
            _serverStatus = _CheckStatus.warning;
            _serverMessage = 'Server merespon: ${response.statusCode}';
          });
        }
      }
    } on TimeoutException {
      if (mounted) {
        setState(() {
          _serverStatus = _CheckStatus.error;
          _serverMessage = 'Server timeout (>8s)';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _serverStatus = _CheckStatus.error;
          _serverMessage = 'Tidak bisa terhubung ke server';
        });
      }
    }
  }

  // ================================================================
  // 4. HISTORY CHECK (Local + Server)
  // ================================================================
  Future<void> _checkRecentPhotos() async {
    debugPrint("🔍 Starting Recent Photos check...");
    if (_hwid.isEmpty) {
      debugPrint("❌ HWID is empty, cannot fetch photos.");
      if (mounted) {
        setState(() {
          _photosStatus = _CheckStatus.error;
          _photosMessage = 'HWID tidak terdeteksi';
        });
      }
      return;
    }

    try {
      // 1. Ambil dari lokal (Prioritas)
      debugPrint("💾 Fetching local history...");
      final localStrips = await HistoryService().getLocalHistory();
      debugPrint("✅ Found ${localStrips.length} local strips.");

      final List<_HistoryItem> items = localStrips
          .map((s) => _HistoryItem(
                url: s.path,
                isLocal: true,
                sessionCode: s.sessionUuid,
                createdAt: s.timestamp.toIso8601String(),
                localBytes: s.bytes,
              ))
          .toList();

      // 2. Ambil dari server
      try {
        final cleanedHwid = _hwid.trim();
        final apiUrl =
            '${ConfigService().baseUrl}/api/photobooth/photos/recent?hwid=${Uri.encodeComponent(cleanedHwid)}&limit=50';
        debugPrint("🌐 Fetching server history from: $apiUrl");

        final response = await http
            .get(Uri.parse(apiUrl))
            .timeout(const Duration(seconds: 12));

        debugPrint("📡 Server Response Status: ${response.statusCode}");

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final List<dynamic> photos = data['data'] ?? data['photos'] ?? [];
          debugPrint("✅ Found ${photos.length} photos on server data.");

          int addedCount = 0;
          for (var p in photos) {
            final String finalUrl =
                p['result_url'] ?? p['photo_url'] ?? p['url'] ?? '';
            final String code =
                p['transaction_code'] ?? p['session_code'] ?? '';
            final String serverDate = p['created_at'] ?? '';

            if (finalUrl.isEmpty || code.isEmpty) {
              debugPrint(
                  "⚠️ Skipping invalid photo data: url=$finalUrl code=$code");
              continue;
            }

            // debugPrint("🔗 Server Entry: $code -> Transformed: $finalUrl");

            if (!items.any((item) => item.sessionCode == code)) {
              items.add(_HistoryItem(
                url: finalUrl,
                isLocal: false,
                sessionCode: code,
                createdAt: serverDate,
              ));
              addedCount++;
            }
          }
          debugPrint("✨ Added $addedCount new UNIQUE server sessions.");
        } else {
          debugPrint("❌ Server error ${response.statusCode}: ${response.body}");
        }
      } catch (e) {
        debugPrint("⚠️ Gagal sync server history: $e");
      }

      // 3. GLOBAL SORT (Urutkan dari yang terbaru)
      debugPrint("⚖️ Sorting all history items by date descending...");
      items.sort((a, b) {
        try {
          final dateA = DateTime.parse(a.createdAt);
          final dateB = DateTime.parse(b.createdAt);
          return dateB.compareTo(dateA);
        } catch (e) {
          return 0; // Gagal parsing, biarkan urutan asli
        }
      });

      if (items.isNotEmpty) {
        debugPrint(
            "📅 Newest item: ${items.first.sessionCode} (isLocal: ${items.first.isLocal})");
        debugPrint("📅 URL: ${items.first.url}");
      }

      debugPrint("🏁 Final history count: ${items.length}");

      if (mounted) {
        setState(() {
          _historyItems = items;
          _photosStatus =
              items.isEmpty ? _CheckStatus.warning : _CheckStatus.success;
          _photosMessage = items.isEmpty
              ? 'Belum ada riwayat strip'
              : 'Ditemukan ${items.length} strip (Local + Server)';
        });
      }
    } catch (e) {
      debugPrint("🚨 Global History Check Error: $e");
      if (mounted) {
        setState(() {
          _photosStatus = _CheckStatus.error;
          _photosMessage = 'Gagal mengambil riwayat: $e';
        });
      }
    }
  }

  Future<void> _reprintStrip(_HistoryItem item) async {
    final pageContext = context;
    showDialog(
      context: pageContext,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 12),
            Text("Mempersiapkan Cetak Ulang...",
                style: TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );

    try {
      Uint8List? bytes;
      if (item.isLocal && item.localBytes != null) {
        bytes = item.localBytes;
        debugPrint("Reprinting from local storage...");
      } else {
        debugPrint("Downloading from server for reprint: ${item.url}");
        final resp = await http
            .get(Uri.parse(item.url))
            .timeout(const Duration(seconds: 15));
        if (resp.statusCode == 200) {
          bytes = resp.bodyBytes;
          debugPrint("Download success: ${bytes.length} bytes");
        } else {
          debugPrint("Download failed: ${resp.statusCode} - ${resp.body}");
          throw Exception(
              "Server returns ${resp.statusCode}. Image might not be ready yet.");
        }
      }

      if (pageContext.mounted) Navigator.pop(pageContext);

      if (bytes != null) {
        if (!pageContext.mounted) return;
        // Cetak ulang memakai PNG 300 DPI dari History apa adanya — state
        // provider sesi itu sudah tidak ada, jadi tidak bisa dirender ulang
        // di 500 DPI seperti jalur cetak normal.
        final success = await PrintService().printStrip(
          bytes,
          sessionUuid: item.sessionCode,
        );

        if (success && pageContext.mounted) {
          ScaffoldMessenger.of(pageContext).showSnackBar(
            const SnackBar(
              content: Text('Cetak ulang berhasil dikirim!'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        throw Exception("Gagal mendapatkan data gambar");
      }
    } catch (e) {
      if (pageContext.mounted) Navigator.pop(pageContext);
      debugPrint("Reprint Error: $e");
      if (pageContext.mounted) {
        ScaffoldMessenger.of(pageContext).showSnackBar(
          SnackBar(
            content: Text('Gagal cetak ulang: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ================================================================`r`n  // TEST PRINT
  // ================================================================
  Future<void> _testPrint(_PrinterInfo printer) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: Colors.white),
      ),
    );

    try {
      final printers = await Printing.listPrinters();
      Printer? target;
      for (final p in printers) {
        if (p.name == printer.name) {
          target = p;
          break;
        }
      }
      if (target == null) {
        throw Exception('Printer "${printer.name}" tidak ditemukan lagi.');
      }

      await Printing.directPrintPdf(
        printer: target,
        // WAJIB sama dengan PrintService.printStrip. Kalau di sini false,
        // plugin mengirim DEVMODE buatan sendiri dan setelan default driver
        // (4x6 / photo glossy / HighQuality / borderless) TIDAK terpakai —
        // test print-nya jadi bohong: kelihatan beda dari cetak sungguhan.
        usePrinterSettings: true,
        onLayout: _generateTestPage,
      );

      if (mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Test print dikirim ke ${printer.name}'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Gagal print: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ================================================================
  // HALAMAN KALIBRASI CETAK
  //
  // Dibangun dari [format] — ukuran halaman fisik yang DILAPORKAN DRIVER,
  // bukan konstanta. Jadi halaman ini sekaligus membuktikan setelan driver
  // sedang benar atau tidak:
  //
  //   * Angka mm di tengah harus terbaca 101,6 x 152,4 untuk kertas 4R.
  //     Kalau tertulis 216 x 279, driver masih di Letter -> jalankan
  //     tools\setup-printer.ps1.
  //   * Bingkai luar dan 4 sudutnya sengaja digambar TEPAT di tepi halaman.
  //     Borderless aktif  -> bingkai terpotong habis / nyaris tak terlihat.
  //     Borderless mati   -> ada margin putih dan bingkainya utuh.
  //   * Tangga abu-abu menunjukkan apakah media type sudah benar. Di profil
  //     "Plain paper" langkah-langkah gelapnya menyatu jadi satu blok hitam
  //     dan tinta melebar; di profil photo glossy tiap langkah terpisah.
  // ================================================================
  Future<Uint8List> _generateTestPage(PdfPageFormat format) async {
    final doc = pw.Document();
    final wMm = format.width / 72.0 * 25.4;
    final hMm = format.height / 72.0 * 25.4;
    final marginless = format.marginLeft == 0 &&
        format.marginTop == 0 &&
        format.marginRight == 0 &&
        format.marginBottom == 0;

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(format.width, format.height, marginAll: 0),
        build: (_) => pw.Stack(
          children: [
            // Bingkai tepat di tepi halaman — penanda borderless.
            pw.Positioned.fill(
              child: pw.Container(
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.black, width: 2),
                ),
              ),
            ),
            pw.Positioned.fill(
              child: pw.Padding(
                padding: const pw.EdgeInsets.all(14),
                child: pw.Column(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text('PHOTOBOOTH — TES KALIBRASI',
                            style: pw.TextStyle(
                                fontSize: 13,
                                fontWeight: pw.FontWeight.bold)),
                        pw.SizedBox(height: 6),
                        pw.Text(
                            'Halaman driver: ${wMm.toStringAsFixed(1)} x '
                            '${hMm.toStringAsFixed(1)} mm',
                            style: const pw.TextStyle(fontSize: 9)),
                        pw.Text(
                            'Margin: ${marginless ? "0 (borderless aktif)" : "ada margin — borderless MATI"}',
                            style: const pw.TextStyle(fontSize: 9)),
                        pw.Text(
                            '4R seharusnya: 101.6 x 152.4 mm',
                            style: const pw.TextStyle(fontSize: 9)),
                      ],
                    ),

                    // Tangga abu-abu: pemeriksa media type & tinta.
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text('Tangga abu-abu (tiap langkah harus beda)',
                            style: const pw.TextStyle(fontSize: 8)),
                        pw.SizedBox(height: 3),
                        pw.Row(
                          children: List.generate(11, (i) {
                            final v = (255 * (1 - i / 10)).round();
                            return pw.Expanded(
                              child: pw.Container(
                                height: 26,
                                color: PdfColor.fromInt(
                                    0xFF000000 | (v << 16) | (v << 8) | v),
                              ),
                            );
                          }),
                        ),
                        pw.SizedBox(height: 10),
                        pw.Text('Warna dasar',
                            style: const pw.TextStyle(fontSize: 8)),
                        pw.SizedBox(height: 3),
                        pw.Row(
                          children: [
                            PdfColors.cyan,
                            PdfColors.pink,
                            PdfColors.yellow,
                            PdfColors.red,
                            PdfColors.green,
                            PdfColors.blue,
                          ]
                              .map((c) => pw.Expanded(
                                  child: pw.Container(height: 26, color: c)))
                              .toList(),
                        ),
                      ],
                    ),

                    pw.Text(
                      'Bingkai hitam menempel di tepi halaman. Kalau borderless '
                      'aktif, bingkai ini terpotong habis. Kalau masih terlihat '
                      'utuh dengan pinggiran putih, borderless belum menyala.',
                      style: const pw.TextStyle(fontSize: 7.5),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return doc.save();
  }

  // ================================================================
  // NAVIGATION
  // ================================================================
  void _proceedToApp() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const SplashScreen()),
    );
  }

  bool get _allPassed =>
      _cameraStatus == _CheckStatus.success &&
      _printerStatus != _CheckStatus.error &&
      _serverStatus == _CheckStatus.success;

  bool get _allDone =>
      _cameraStatus != _CheckStatus.loading &&
      _printerStatus != _CheckStatus.loading &&
      _serverStatus != _CheckStatus.loading &&
      _photosStatus != _CheckStatus.loading;

  // ================================================================
  // BUILD
  // ================================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background retro
          Image.asset(
            'assets/images/splash_background.png',
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(color: Colors.black),
          ),
          // Overlay gelap
          Container(color: Colors.black.withValues(alpha: 0.4)),
          // Konten
          FadeTransition(
            opacity: _fadeAnimation,
            child: Row(
              children: [
                // ── LEFT PANEL: Checks ──
                Expanded(
                  flex: 3,
                  child: Padding(
                    padding: const EdgeInsets.all(40),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Header
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: Colors.black,
                                  width: 3,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black,
                                    offset: Offset(4, 4),
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.monitor_heart,
                                color: Colors.black,
                                size: 28,
                              ),
                            ),
                            const SizedBox(width: 20),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'System Diagnostic',
                                  style: TextStyle(
                                    fontFamily: 'Poppins',
                                    color: Colors.white,
                                    fontSize: 28,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.0,
                                    shadows: [
                                      Shadow(
                                        color: Colors.black,
                                        offset: Offset(3, 3),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: SelectableText(
                                    'HWID: ${_hwid.isNotEmpty ? _hwid : 'detecting...'}',
                                    style: const TextStyle(
                                      fontFamily: 'Poppins',
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),

                        const SizedBox(height: 36),

                        // ── Check cards ──
                        Expanded(
                          child: ListView(
                            children: [
                              // 1. Server
                              _buildCheckCard(
                                icon: Icons.dns_outlined,
                                title: 'Server Connection',
                                message: _serverMessage,
                                status: _serverStatus,
                                accentColor: const Color(0xFF6C63FF),
                              ),

                              const SizedBox(height: 12),

                              // 2. Camera
                              _buildCheckCard(
                                icon: Icons.camera_alt_outlined,
                                title: 'Camera Driver',
                                message: _cameraMessage,
                                status: _cameraStatus,
                                accentColor: const Color(0xFF00BFA5),
                                trailing: _cameraStatus == _CheckStatus.success
                                    ? Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF00BFA5)
                                              .withValues(alpha: 0.1),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          Platform.isMacOS
                                              ? 'macOS'
                                              : 'Windows',
                                          style: const TextStyle(
                                            color: Color(0xFF00BFA5),
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      )
                                    : null,
                              ),

                              const SizedBox(height: 12),

                              // 3. Printer
                              _buildCheckCard(
                                icon: Icons.print_outlined,
                                title: 'Printer Driver',
                                message: _printerMessage,
                                status: _printerStatus,
                                accentColor: const Color(0xFFFF6B6B),
                                expandedContent: _printers.isNotEmpty
                                    ? Column(
                                        children: _printers.map((p) {
                                          return _buildPrinterRow(p);
                                        }).toList(),
                                      )
                                    : null,
                              ),

                              const SizedBox(height: 12),

                              // 4. Recent Photos
                              _buildCheckCard(
                                icon: Icons.photo_library_outlined,
                                title: 'Recent Photos',
                                message: _photosMessage,
                                status: _photosStatus,
                                accentColor: const Color(0xFFFFB74D),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 20),

                        // ── Bottom buttons ──
                        Row(
                          children: [
                            // Refresh
                            _buildActionButton(
                              icon: Icons.refresh,
                              label: 'Re-check',
                              onTap: () {
                                setState(() {
                                  _cameraStatus = _CheckStatus.loading;
                                  _printerStatus = _CheckStatus.loading;
                                  _serverStatus = _CheckStatus.loading;
                                  _photosStatus = _CheckStatus.loading;
                                  _cameraMessage = 'Mendeteksi kamera...';
                                  _printerMessage = 'Mendeteksi printer...';
                                  _serverMessage = 'Mengecek koneksi server...';
                                  _photosMessage = 'Mengambil foto terakhir...';
                                  _printers = [];
                                  _historyItems = [];
                                });
                                _runAllChecks();
                              },
                              color: Colors.white,
                              textColor: Colors.black,
                            ),

                            const SizedBox(width: 12),

                            // Continue
                            Expanded(
                              child: AnimatedBuilder(
                                animation: _pulseController,
                                builder: (context, child) {
                                  final glow = _allPassed && _allDone
                                      ? _pulseController.value * 0.3
                                      : 0.0;
                                  return Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      boxShadow: _allPassed && _allDone
                                          ? [
                                              BoxShadow(
                                                color: const Color(0xFF00BFA5)
                                                    .withValues(alpha: glow),
                                                blurRadius: 20,
                                                spreadRadius: 2,
                                              )
                                            ]
                                          : [],
                                    ),
                                    child: child,
                                  );
                                },
                                child: _buildActionButton(
                                  icon: Icons.arrow_forward_rounded,
                                  label: _allDone
                                      ? (_allPassed
                                          ? 'Lanjutkan'
                                          : 'Perlu Perbaikan')
                                      : 'Checking...',
                                  onTap: (_allDone && _allPassed)
                                      ? _proceedToApp
                                      : null,
                                  color: _allDone
                                      ? (_allPassed
                                          ? const Color(0xFF00BFA5) // Teal
                                          : const Color(0xFFFF9800)) // Orange
                                      : Colors.grey[300]!,
                                  textColor:
                                      _allDone ? Colors.white : Colors.black38,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                // ── RIGHT PANEL: Recent photos grid ──
                Container(
                  width: 360,
                  margin: const EdgeInsets.all(20),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.black,
                      width: 4,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black,
                        offset: Offset(6, 6),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.history,
                            color: Colors.black87,
                            size: 16,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Riwayat Strip (Owner Only)',
                            style: TextStyle(
                              fontFamily: 'Poppins',
                              color: Colors.black87,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: _photosStatus == _CheckStatus.loading
                            ? const Center(
                                child: CircularProgressIndicator(
                                  color: Colors.black45,
                                  strokeWidth: 3,
                                ),
                              )
                            : _historyItems.isEmpty
                                ? const Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.photo_library_outlined,
                                          color: Colors.black26,
                                          size: 48,
                                        ),
                                        SizedBox(height: 12),
                                        Text(
                                          'Belum ada riwayat',
                                          style: TextStyle(
                                            color: Colors.black54,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                : ListView.separated(
                                    padding: const EdgeInsets.only(bottom: 20),
                                    itemCount: _historyItems.length,
                                    separatorBuilder: (_, __) =>
                                        const SizedBox(height: 16),
                                    itemBuilder: (ctx, i) {
                                      final item = _historyItems[i];
                                      return _buildHistoryCard(item, i);
                                    },
                                  ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ================================================================
  // UI BUILDERS
  // ================================================================
  Widget _buildCheckCard({
    required IconData icon,
    required String title,
    required String message,
    required _CheckStatus status,
    required Color accentColor,
    Widget? trailing,
    Widget? expandedContent,
  }) {
    final Color statusColor;
    final IconData statusIcon;

    switch (status) {
      case _CheckStatus.loading:
        statusColor = Colors.white38;
        statusIcon = Icons.hourglass_empty;
        break;
      case _CheckStatus.success:
        statusColor = const Color(0xFF4CAF50);
        statusIcon = Icons.check_circle;
        break;
      case _CheckStatus.warning:
        statusColor = const Color(0xFFFF9800);
        statusIcon = Icons.warning_amber_rounded;
        break;
      case _CheckStatus.error:
        statusColor = const Color(0xFFFF5252);
        statusIcon = Icons.cancel;
        break;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: status == _CheckStatus.loading ? Colors.grey[800] : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.black,
          width: 3,
        ),
        boxShadow: const [
          BoxShadow(
            color: Colors.black,
            offset: Offset(4, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: accentColor, size: 18),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontFamily: 'Poppins',
                        color: status == _CheckStatus.loading
                            ? Colors.white
                            : Colors.black,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      message,
                      style: TextStyle(
                        fontFamily: 'Poppins',
                        color: status == _CheckStatus.loading
                            ? Colors.white70
                            : Colors.black87,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing,
              ],
              const SizedBox(width: 8),
              status == _CheckStatus.loading
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: accentColor.withValues(alpha: 0.5),
                      ),
                    )
                  : Icon(statusIcon, color: statusColor, size: 20),
            ],
          ),
          if (expandedContent != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: 12, left: 4, right: 4),
              child: expandedContent,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPrinterRow(_PrinterInfo printer) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.black, width: 1.5),
              color: printer.isAvailable
                  ? const Color(0xFF4CAF50)
                  : Colors.grey[400],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              printer.name,
              style: TextStyle(
                fontFamily: 'Poppins',
                color: printer.isAvailable ? Colors.black87 : Colors.black38,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (printer.isDefault)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black12,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'DEFAULT',
                style: TextStyle(
                  color: Colors.black54,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          if (printer.isAvailable) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => _testPrint(printer),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF6B6B).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: const Color(0xFFFF6B6B).withValues(alpha: 0.2),
                  ),
                ),
                child: const Text(
                  'Test Print',
                  style: TextStyle(
                    color: Color(0xFFFF6B6B),
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHistoryCard(_HistoryItem item, int index) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black, width: 2.5),
        boxShadow: const [BoxShadow(color: Colors.black, offset: Offset(4, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Strip Preview
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(13)),
            child: AspectRatio(
              aspectRatio: 1 / 1.5, // Menyerupai strip vertikal
              child: item.isLocal
                  ? Image.file(
                      File(item.url),
                      fit: BoxFit.cover,
                      alignment: Alignment.topCenter,
                    )
                  : Image.network(
                      item.url,
                      fit: BoxFit.cover,
                      alignment: Alignment.topCenter,
                      loadingBuilder: (_, child, prog) => prog == null
                          ? child
                          : const Center(child: CircularProgressIndicator()),
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.broken_image, size: 40),
                    ),
            ),
          ),

          // Info & Action
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      item.isLocal ? '💾 LOKAL' : '☁️ SERVER',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: item.isLocal ? Colors.blue : Colors.orange,
                      ),
                    ),
                    Text(
                      _formatDate(item.createdAt),
                      style:
                          const TextStyle(fontSize: 9, color: Colors.black54),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'ID: ${item.sessionCode}',
                  style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 12),

                // Reprint Button
                GestureDetector(
                  onTap: () => _reprintStrip(item),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF6B6B),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.black, width: 2),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.print, color: Colors.white, size: 14),
                        SizedBox(width: 8),
                        Text(
                          'CETAK ULANG',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    required Color color,
    required Color textColor,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: onTap == null ? Colors.grey[300] : color,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Colors.black,
            width: 3,
          ),
          boxShadow: const [
            BoxShadow(
              color: Colors.black,
              offset: Offset(4, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: textColor, size: 18),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Poppins',
                color: textColor,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(String dateStr) {
    try {
      final dt = DateTime.parse(dateStr).toLocal();
      return '${dt.day}/${dt.month}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return dateStr;
    }
  }
}

// ================================================================
// MODELS
// ================================================================
enum _CheckStatus { loading, success, warning, error }

class _PrinterInfo {
  final String name;
  final bool isDefault;
  final bool isAvailable;

  _PrinterInfo({
    required this.name,
    required this.isDefault,
    required this.isAvailable,
  });
}

class _HistoryItem {
  final String url;
  final bool isLocal;
  final String sessionCode;
  final String createdAt;
  final Uint8List? localBytes;

  _HistoryItem({
    required this.url,
    required this.isLocal,
    required this.sessionCode,
    required this.createdAt,
    this.localBytes,
  });
}
