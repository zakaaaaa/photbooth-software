import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' as http_parser;
import 'package:webview_windows/webview_windows.dart';
import 'package:photobooth_app/providers/app_config_provider.dart';
import 'package:photobooth_app/providers/photo_provider.dart';
import 'package:photobooth_app/screens/splash_screen.dart';
import 'package:photobooth_app/screens/video_result_page.dart';
import 'package:photobooth_app/services/config_service.dart';
import 'package:photobooth_app/services/history_service.dart';
import 'package:photobooth_app/services/print_service.dart';
import 'package:photobooth_app/utils/frame_composer.dart';
import 'package:photobooth_app/services/api_service.dart';
import 'package:photobooth_app/services/license_service.dart';
import 'package:photobooth_app/services/upload_queue_service.dart';
import 'package:photobooth_app/services/queue_service.dart';

// ============================================================
// TOP-LEVEL ISOLATE FUNCTION — encode PNG di background thread
// ── FIX UTAMA: tidak blok UI thread ──
// ============================================================
Uint8List _encodePngInIsolate(Map<String, dynamic> args) {
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

// ============================================================
// MAIN PAGE
// ============================================================
// ── Palet desain konsisten (warm / rounded) ──
const Color _kCream = Color(0xFFFFF6E6);
const Color _kRed1 = Color(0xFFC23A2A);
const Color _kRed2 = Color(0xFFA62D1D);
const Color _kBrown = Color(0xFF7A4636);
const Color _kTextBrown = Color(0xFF5A3A2A);

class PreviewPrintPage extends StatefulWidget {
  final bool autoPrint;
  const PreviewPrintPage({super.key, this.autoPrint = false});

  @override
  State<PreviewPrintPage> createState() => _PreviewPrintPageState();
}

class _PreviewPrintPageState extends State<PreviewPrintPage> {
  static final String _frontendUrl = ConfigService().frontendUrl;
  bool _autoPrinted = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoPrint) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _autoPrintOnce());
    }
  }

  Future<void> _autoPrintOnce() async {
    if (_autoPrinted || !mounted) return;
    _autoPrinted = true;
    final appConfig = Provider.of<AppConfigProvider>(context, listen: false);
    await _doPrint(appConfig.autoPrintCopies);
  }

  // ── Kirim perintah print sebanyak [copies] dari hasil render final ──
  Future<void> _doPrint(int copies) async {
    if (copies <= 0) return;
    final provider = Provider.of<PhotoProvider>(context, listen: false);
    final appConfig = Provider.of<AppConfigProvider>(context, listen: false);

    if (provider.finalImageBytes == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("Menyiapkan foto, coba lagi sebentar...")));
      }
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(color: Colors.white),
          SizedBox(height: 12),
          Text("Mengirim ke printer...",
              style: TextStyle(color: Colors.white, fontFamily: 'Quicksand')),
        ]),
      ),
    );

    try {
      // Render ULANG khusus cetak, di FrameComposer.printLongSidePx (500 DPI)
      // alih-alih memakai finalImageBytes yang cuma 300 DPI. Sengaja hanya di
      // sini: menaikkan resolusi global akan ikut memperlambat setiap
      // pergantian filter dan menggemukkan berkas unduhan pelanggan.
      //
      // Kalau render ulang gagal karena sebab apa pun, jatuh kembali ke
      // finalImageBytes — cetak 300 DPI jauh lebih baik daripada sesi gagal.
      RenderedStrip? hires;
      try {
        final sw = Stopwatch()..start();
        hires = await FrameComposer.composeForPrint(provider);
        debugPrint('[Print] render cetak ${hires.width}x${hires.height} '
            'dalam ${sw.elapsedMilliseconds}ms');
      } catch (e) {
        debugPrint('[Print] render resolusi tinggi gagal, '
            'pakai hasil 300 DPI: $e');
      }

      final success = await PrintService().printStrip(
        hires?.rgba ?? provider.finalImageBytes!,
        sessionUuid: provider.sessionUuid,
        copies: copies,
        printerKeyword: appConfig.preferredPrinterKeyword,
        paperSize: appConfig.paperSize,
        rawWidth: hires?.width ?? 0,
        rawHeight: hires?.height ?? 0,
      );

      if (success) {
        await HistoryService()
            .saveToHistory(provider.sessionUuid, provider.finalImageBytes!);
      }

      if (!mounted) return;
      Navigator.pop(context); // tutup loading

      // Tampilkan sebab sebenarnya kalau ada. Tanpa ini, kegagalan seperti
      // antrian tersumbat karena PaperOut hanya terlihat sebagai "coba lagi"
      // dan operator tidak pernah tahu harus memperbaiki apa.
      final reason = PrintService().lastPrintError;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(success
            ? "✅ Terkirim ke printer!"
            : "❌ ${reason ?? 'Gagal mencetak. Coba lagi.'}"),
        backgroundColor: success ? Colors.green : Colors.redAccent,
        duration: Duration(seconds: success ? 3 : 7),
      ));
    } catch (e) {
      if (mounted) Navigator.pop(context);
      debugPrint("Print error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text("Error printer: $e"),
            backgroundColor: Colors.redAccent));
      }
    }
  }

  // ── Bayar cetakan tambahan (qty) lalu kirim print ──
  Future<void> _payAndPrintAdditional(int qty) async {
    if (qty <= 0) return;

    final provider = Provider.of<PhotoProvider>(context, listen: false);
    final appConfig = Provider.of<AppConfigProvider>(context, listen: false);
    final totalAmount = qty * appConfig.extraPrintPrice;
    final extraUuid =
        "${provider.sessionUuid}-extra-${DateTime.now().millisecondsSinceEpoch}";
    final hwid = await LicenseService().getHardwareId();

    // Terisi begitu baris sesi ada di server tapi belum dibayar. Dikosongkan
    // hanya kalau benar-benar lunas; selain itu ditutup di blok finally.
    String? sesiBelumDibayar;

    try {
      final started = await ApiService().startSession(extraUuid,
          hwid: hwid,
          paymentMethod: 'qris',
          transactionType: 'extra_print',
          extraPrintCount: qty);
      if (!started) throw Exception("Gagal terhubung ke server pembayaran.");
      sesiBelumDibayar = extraUuid;

      final paymentUrl =
          await ApiService().generatePaymentLink(extraUuid, hwid: hwid);
      if (paymentUrl == null) {
        throw Exception("Gagal membuat link pembayaran.");
      }

      if (!mounted) return;
      final paid = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => _ExtraPaymentDialog(
          paymentUrl: paymentUrl,
          sessionUuid: extraUuid,
          amount: totalAmount,
          hwid: hwid,
        ),
      );

      if (paid == true) {
        sesiBelumDibayar = null;
        if (mounted) await _doPrint(qty);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text("Error: ${e.toString()}"),
            backgroundColor: Colors.redAccent));
      }
    } finally {
      // Dialog ditutup tanpa bayar, link gagal dibuat, atau halaman keburu
      // dilepas — tanpa ini barisnya tertinggal 'pending' selamanya.
      // Server menanyakan DOKU dulu, jadi pembayaran yang webhook-nya telat
      // tetap tercatat lunas, bukan ikut dibatalkan.
      if (sesiBelumDibayar != null) {
        ApiService().abandonSession(sesiBelumDibayar, hwid: hwid);
      }
    }
  }

  // ── Popup "Tambah Cetakan" bergaya panel keyboard ──
  void _showAddPrintPopup() {
    final appConfig = Provider.of<AppConfigProvider>(context, listen: false);
    int qty = 1;

    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          final int total = qty * appConfig.extraPrintPrice;
          return Dialog(
            backgroundColor: Colors.transparent,
            elevation: 0,
            child: Container(
              width: 420,
              padding: const EdgeInsets.fromLTRB(26, 22, 26, 26),
              decoration: BoxDecoration(
                color: _kBrown,
                borderRadius: BorderRadius.circular(24),
                boxShadow: const [
                  BoxShadow(
                      color: Colors.black54,
                      blurRadius: 24,
                      offset: Offset(0, 12)),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text("Tambah Cetakan",
                      style: TextStyle(
                          fontFamily: 'Quicksand',
                          fontWeight: FontWeight.w700,
                          color: _kCream,
                          fontSize: 24)),
                  const SizedBox(height: 22),
                  // Pemilih jumlah
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _qtyButton("−", () {
                        if (qty > 1) setSt(() => qty--);
                      }),
                      Container(
                        width: 90,
                        alignment: Alignment.center,
                        child: Text("$qty",
                            style: const TextStyle(
                                fontFamily: 'Quicksand',
                                fontWeight: FontWeight.w700,
                                color: _kCream,
                                fontSize: 40)),
                      ),
                      _qtyButton("+", () => setSt(() => qty++)),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text("Total: Rp$total",
                        style: const TextStyle(
                            fontFamily: 'Quicksand',
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFFFE3A6),
                            fontSize: 20)),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: _PrintPillButton(
                          label: "Batal",
                          primary: false,
                          expand: true,
                          onTap: () => Navigator.pop(ctx),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        flex: 3,
                        child: _PrintPillButton(
                          label: "Bayar & Cetak",
                          expand: true,
                          onTap: () {
                            Navigator.pop(ctx);
                            _payAndPrintAdditional(qty);
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _qtyButton(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _kCream,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))
          ],
        ),
        child: Text(label,
            style: const TextStyle(
                fontFamily: 'Quicksand',
                fontWeight: FontWeight.w700,
                color: _kTextBrown,
                fontSize: 30)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final photoProvider = Provider.of<PhotoProvider>(context);
    final sessionUuid = photoProvider.sessionUuid;
    final appConfig = Provider.of<AppConfigProvider>(context, listen: false);
    final String qrUrl = '$_frontendUrl/download/$sessionUuid';
    // Render & upload hasil akhir berjalan di latar belakang sejak CameraPage,
    // jadi halaman ini bisa terbuka sebelum filenya sampai di server.
    final bool resultReady = photoProvider.finalUploaded;
    final bool resultFailed = photoProvider.finalUploadFailed;

    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, c) {
          final double w = c.maxWidth;
          final double h = c.maxHeight;
          final double iconSize = (h * 0.17).clamp(90.0, 180.0);
          final double logoH = (h * 0.19).clamp(80.0, 200.0);
          const double colGap = 100.0;
          final double rowGap = (w * 0.04).clamp(28.0, 96.0);

          final Widget leftCol = Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _PrintIconButton(
                asset: 'assets/images/foto.png',
                label: 'Foto',
                size: iconSize,
                onTap: () => _navigateTo(context, const PhotoPreviewPage()),
              ),
              const SizedBox(height: colGap),
              _PrintIconButton(
                // video.png = gambar GIF (sesuai visual)
                asset: 'assets/images/video.png',
                label: 'GIF',
                size: iconSize,
                onTap: () => _navigateTo(context, const GifPreviewPage()),
              ),
            ],
          );

          final Widget rightCol = Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _PrintIconButton(
                // gif.png = gambar clapper/video (sesuai visual)
                asset: 'assets/images/gif.png',
                label: 'Video',
                size: iconSize,
                onTap: () => _navigateTo(context, const VideoResultPage()),
              ),
              if (appConfig.extraPrintEnabled) ...[
                const SizedBox(height: colGap),
                _PrintIconButton(
                  asset: 'assets/images/cetak.png',
                  label: 'Tambah\nPrint',
                  size: iconSize,
                  onTap: _showAddPrintPopup,
                ),
              ],
            ],
          );

          return Stack(
            fit: StackFit.expand,
            children: [
              // 1. BACKGROUND
              Image.asset('assets/images/bgpreview.png', fit: BoxFit.cover),

              // 2. LOGO atas tengah
              Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: EdgeInsets.only(top: h * 0.03),
                  child: Image.asset('assets/images/logo.png',
                      height: logoH, fit: BoxFit.contain),
                ),
              ),

              // 3. Foto/GIF — QR "Unduh Softfile" — Video/Tambah Print
              //    dikelompokkan terpusat agar tombol dekat dengan panel QR.
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    leftCol,
                    SizedBox(width: rowGap),
                    if (appConfig.downloadQrEnabled)
                      _buildQrPanel(qrUrl, resultReady, resultFailed),
                    SizedBox(width: rowGap),
                    rightCol,
                  ],
                ),
              ),

              // 4. Tombol Selesai (tengah bawah, hijau)
              Positioned(
                left: 0,
                right: 0,
                bottom: 26,
                child: Center(
                  child: _PrintPillButton(
                    label: "Selesai",
                    primary: false,
                    color: const Color(0xFF4FAE5A),
                    onTap: () {
                      final provider =
                          Provider.of<PhotoProvider>(context, listen: false);

                      // Tutup tiket antrean lalu biarkan server memanggil
                      // orang berikutnya. Sengaja tanpa await: pelanggan yang
                      // sudah selesai tidak boleh menunggu jaringan hanya untuk
                      // kembali ke layar awal, dan QueueService melepas
                      // tiketnya sendiri apa pun hasil panggilan ini.
                      if (QueueService.instance.aktif != null) {
                        QueueService.instance.selesai(
                          provider.machineId,
                          sessionUuid: provider.sessionUuid,
                        );
                      }

                      provider.reset();
                      Navigator.of(context).pushAndRemoveUntil(
                        MaterialPageRoute(
                            builder: (_) => const SplashScreen()),
                        (r) => false,
                      );
                    },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // Panel QR "Unduh Softfile" bergaya panel keyboard (brown rounded).
  // [ready] false = hasil akhir belum tersimpan di server; QR diredupkan agar
  // pelanggan tidak memindainya ke halaman unduh yang masih kosong.
  Widget _buildQrPanel(String qrUrl, bool ready, bool failed) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      decoration: BoxDecoration(
        color: _kBrown,
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [
          BoxShadow(
              color: Colors.black54, blurRadius: 22, offset: Offset(0, 12)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text("Unduh Softfile",
              style: TextStyle(
                  fontFamily: 'Quicksand',
                  fontWeight: FontWeight.w700,
                  color: _kCream,
                  fontSize: 22)),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SizedBox(
              width: 210,
              height: 210,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // QR tetap dirender walau belum siap, supaya ukuran panel
                  // tidak melompat saat status berubah.
                  Opacity(
                    opacity: ready ? 1.0 : 0.12,
                    child: QrImageView(
                      data: qrUrl,
                      version: QrVersions.auto,
                      size: 210.0,
                      backgroundColor: Colors.white,
                      gapless: false,
                    ),
                  ),
                  if (!ready && !failed)
                    const SizedBox(
                      width: 34,
                      height: 34,
                      child: CircularProgressIndicator(
                          strokeWidth: 3, color: _kBrown),
                    ),
                  if (failed)
                    const Icon(Icons.wifi_off_rounded,
                        size: 38, color: _kTextBrown),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
              ready
                  ? "Scan untuk unduh"
                  : failed
                      ? "Gagal terkirim — buka menu Foto"
                      : "Menyiapkan file...",
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontFamily: 'Quicksand',
                  fontWeight: FontWeight.w500,
                  color: ready
                      ? const Color(0xFFFFE3A6)
                      : const Color(0xFFD9BE8C),
                  fontSize: 13)),
        ],
      ),
    );
  }

  void _navigateTo(BuildContext context, Widget page) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => page));
}

// ============================================================
// WIDGET HELPERS
// ============================================================
// Tombol icon (gambar + label) bergaya konsisten, animasi hover/press.
class _PrintIconButton extends StatefulWidget {
  final String asset;
  final String label;
  final double size;
  final VoidCallback onTap;
  const _PrintIconButton({
    required this.asset,
    required this.label,
    required this.size,
    required this.onTap,
  });
  @override
  State<_PrintIconButton> createState() => _PrintIconButtonState();
}

class _PrintIconButtonState extends State<_PrintIconButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final double scale = _pressed ? 0.94 : (_hover ? 1.10 : 1.0);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: scale,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    BoxShadow(
                      color:
                          Colors.black.withValues(alpha: _hover ? 0.45 : 0.3),
                      blurRadius: _hover ? 20 : 10,
                      offset: Offset(0, _hover ? 10 : 6),
                    ),
                  ],
                ),
                child: Image.asset(widget.asset,
                    width: widget.size,
                    height: widget.size,
                    fit: BoxFit.contain),
              ),
              SizedBox(height: widget.size * 0.09),
              Text(
                widget.label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Quicksand',
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  height: 1.05,
                  fontSize: (widget.size * 0.19).clamp(16.0, 28.0),
                  letterSpacing: 0.5,
                  shadows: const [
                    Shadow(
                        offset: Offset(0, 2),
                        blurRadius: 8,
                        color: Colors.black87),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Tombol pill konsisten: primary (gradient merah) / secondary (coklat).
class _PrintPillButton extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final Color? color;
  final bool expand;
  const _PrintPillButton({
    required this.label,
    required this.onTap,
    this.primary = true,
    this.color,
    this.expand = false,
  });
  @override
  State<_PrintPillButton> createState() => _PrintPillButtonState();
}

class _PrintPillButtonState extends State<_PrintPillButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onTap != null;
    final double scale = _pressed ? 0.96 : (_hover ? 1.04 : 1.0);
    final Gradient? gradient = widget.primary
        ? LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: _hover
                ? const [Color(0xFFD0452F), Color(0xFFB23320)]
                : const [_kRed1, _kRed2],
          )
        : null;

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled
            ? (_) {
                setState(() => _pressed = false);
                widget.onTap!();
              }
            : null,
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            width: widget.expand ? double.infinity : null,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            alignment: widget.expand ? Alignment.center : null,
            decoration: BoxDecoration(
              gradient: gradient,
              color: widget.primary ? null : (widget.color ?? _kBrown),
              borderRadius: BorderRadius.circular(40),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: _hover ? 16 : 9,
                  offset: Offset(0, _hover ? 8 : 5),
                ),
              ],
            ),
            child: Text(
              widget.label,
              style: const TextStyle(
                fontFamily: 'Quicksand',
                fontWeight: FontWeight.w700,
                color: Colors.white,
                fontSize: 19,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// PAGE 1: PHOTO PREVIEW
// ── FIX UTAMA: RepaintBoundary di LUAR FittedBox ──
// ============================================================
class PhotoPreviewPage extends StatefulWidget {
  const PhotoPreviewPage({super.key});
  @override
  State<PhotoPreviewPage> createState() => _PhotoPreviewPageState();
}

class _PhotoPreviewPageState extends State<PhotoPreviewPage> {
  final GlobalKey _globalKey = GlobalKey();
  bool _isUploading = false;
  bool _isUploaded = false;
  String _uploadStatus = '';
  static final String _backendUrl = ConfigService().baseUrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _waitForFrameAndCapture());
  }

  Future<void> _waitForFrameAndCapture() async {
    final provider = Provider.of<PhotoProvider>(context, listen: false);
    final frameUrl = provider.selectedFrameAsset;

    debugPrint('⏱ [0] _waitForFrameAndCapture — frameUrl: $frameUrl');

    if (frameUrl != null && frameUrl.startsWith('http')) {
      debugPrint('⏱ [0a] Pre-loading frame image dari network...');
      try {
        await precacheImage(NetworkImage(frameUrl), context);
        debugPrint('⏱ [0b] Frame image ready di cache ✅');
      } catch (e) {
        debugPrint('⚠️ [0b] precacheImage gagal: $e — lanjut capture saja');
      }
    }

    if (mounted) {
      await Future.delayed(const Duration(milliseconds: 200));
      _captureAndUpload();
    }
  }

  Future<void> _captureAndUpload() async {
    if (_isUploaded) return;
    final provider = Provider.of<PhotoProvider>(context, listen: false);

    if (provider.finalImageBytes != null) {
      debugPrint(
          '🚀 [Optimized] Menggunakan hasil render asli dari CameraPage...');
      await _uploadFinalResult(provider.finalImageBytes!, provider.sessionUuid);
      return;
    }

    setState(() {
      _isUploading = true;
      _uploadStatus = 'Merender foto...';
    });

    try {
      final boundary = _globalKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;

      if (boundary == null) {
        setState(() {
          _isUploading = false;
          _uploadStatus = 'Gagal capture widget.';
        });
        return;
      }

      final frameW = provider.selectedFrameWidth;
      final renderW = boundary.size.width;
      final ratio = (frameW / renderW).clamp(1.0, 4.0);

      final uiImage = await boundary.toImage(pixelRatio: ratio);
      final byteData =
          await uiImage.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) throw Exception('toByteData null');
      final rawBytes = byteData.buffer.asUint8List();

      if (mounted) setState(() => _uploadStatus = 'Encoding PNG...');
      final pngBytes = await compute(_encodePngInIsolate, {
        'width': uiImage.width,
        'height': uiImage.height,
        'raw': rawBytes,
      });

      if (!mounted) return;
      provider.setFinalImageBytes(pngBytes);

      await _uploadFinalResult(pngBytes, provider.sessionUuid);
    } catch (e) {
      debugPrint('❌ Capture/Upload error: $e');
      if (mounted) {
        setState(() {
          _isUploading = false;
          _uploadStatus = 'Gagal render/upload.';
        });
      }
    }
  }

  Future<void> _uploadFinalResult(
      Uint8List pngBytes, String sessionUuid) async {
    final sw = Stopwatch()..start();
    if (mounted) setState(() => _uploadStatus = 'Mengupload ke server...');

    try {
      final provider = Provider.of<PhotoProvider>(context, listen: false);
      if (provider.machineId.isEmpty) {
        await provider.initMachineId();
      }
      final hwid = provider.machineId;
      if (hwid.isEmpty) {
        throw Exception('HWID kosong, upload final dibatalkan.');
      }

      final tempDir = await getTemporaryDirectory();
      final tempFile = File(
          '${tempDir.path}/result_${DateTime.now().millisecondsSinceEpoch}.png');
      await tempFile.writeAsBytes(pngBytes);

      // 💾 Simpan ke history lokal (Owner Dashboard)
      await HistoryService().saveToHistory(sessionUuid, pngBytes);

      final uri = Uri.parse('$_backendUrl/api/photobooth/upload/final');
      final request = http.MultipartRequest('POST', uri)
        ..fields['session_uuid'] = sessionUuid
        ..fields['hwid'] = hwid
        ..files.add(await http.MultipartFile.fromPath('photo', tempFile.path,
            contentType: http_parser.MediaType('image', 'png')));

      final streamed = await request.send();
      final response = await http.Response.fromStream(streamed);

      if (response.statusCode != 200 && response.statusCode != 201) {
        // Antre dulu sebelum berkas sementaranya dihapus — strip final ini
        // hasil yang dibayar pelanggan, tidak boleh menguap karena wifi
        // sedang buruk. Antrean mencoba lagi sampai berhasil.
        await UploadQueueService.instance.enqueue(
          kind: UploadKind.finalStrip,
          sessionUuid: sessionUuid,
          sourcePath: tempFile.path,
        );
      }

      try {
        await tempFile.delete();
      } catch (_) {}

      if (response.statusCode == 200 || response.statusCode == 201) {
        debugPrint(
            '✅ Upload berhasil! status: ${response.statusCode} (${sw.elapsedMilliseconds}ms)');
        // Bagikan ke provider supaya panel QR ikut terbuka kuncinya.
        String? resultUrl;
        try {
          resultUrl = jsonDecode(response.body)['url'] as String?;
        } catch (_) {}
        provider.setFinalUploaded(resultUrl);
        if (mounted) {
          setState(() {
            _isUploaded = true;
            _isUploading = false;
            _uploadStatus = '';
          });
        }
      } else {
        throw Exception('Upload Failed: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint("❌ Upload error: $e");
      if (mounted) {
        Provider.of<PhotoProvider>(context, listen: false)
            .setFinalUploadFailed();
        setState(() {
          _isUploading = false;
          _uploadStatus = 'Error upload.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Photo Result"),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (_isUploading) ...[
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white54)),
                const SizedBox(width: 8),
                Text(_uploadStatus,
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 11)),
              ] else if (_isUploaded) ...[
                const Icon(Icons.cloud_done_rounded,
                    color: Colors.greenAccent, size: 18),
                const SizedBox(width: 6),
                const Text("Uploaded",
                    style: TextStyle(color: Colors.greenAccent, fontSize: 12)),
              ],
            ]),
          ),
        ],
      ),
      body: Consumer<PhotoProvider>(
        builder: (context, provider, _) {
          final frameW = provider.selectedFrameWidth;
          final frameH = provider.selectedFrameHeight;

          return Center(
            child: RepaintBoundary(
              key: _globalKey,
              child: AspectRatio(
                aspectRatio: frameW / frameH,
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: SizedBox(
                    width: frameW,
                    height: frameH,
                    child: _buildFrameResult(provider),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildFrameResult(PhotoProvider provider) {
    final double w = provider.selectedFrameWidth;
    final double h = provider.selectedFrameHeight;

    return Container(
      width: w,
      height: h,
      color: Colors.white,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (provider.hasCustomSlots)
            ..._buildSlotWidgets(provider, w, h)
          else
            _buildGridFallback(provider),
          if (provider.selectedFrameAsset != null)
            IgnorePointer(
              child: provider.selectedFrameAsset!.startsWith('http')
                  ? Image.network(
                      provider.selectedFrameAsset!,
                      fit: BoxFit.fill,
                      frameBuilder: (ctx, child, frame, _) => child,
                      errorBuilder: (ctx, e, st) => const SizedBox.shrink(),
                    )
                  : Image.asset(provider.selectedFrameAsset!, fit: BoxFit.fill),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildSlotWidgets(PhotoProvider provider, double w, double h) {
    final photos = provider.photos;
    if (photos.isEmpty) return [];

    return provider.photoSlots.map((slot) {
      final int idx = slot.photoIndex.clamp(0, photos.length - 1);
      final photoBytes = photos[idx].imageData;

      return Positioned(
        left: slot.x,
        top: slot.y,
        width: slot.width,
        height: slot.height,
        child: Transform.rotate(
          angle: slot.rotation * (math.pi / 180),
          child: ClipRect(
            child: Image.memory(
              photoBytes,
              width: slot.width,
              height: slot.height,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
            ),
          ),
        ),
      );
    }).toList();
  }

  Widget _buildGridFallback(PhotoProvider provider) {
    final layout = provider.selectedLayout;
    final int count = provider.targetPhotoCount;
    final int cols = count == 3 ? 1 : 2;

    return Padding(
      padding: EdgeInsets.fromLTRB(layout.leftPadding, layout.topPadding,
          layout.rightPadding, layout.bottomPadding),
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          crossAxisSpacing: layout.horizontalSpacing,
          mainAxisSpacing: layout.verticalSpacing,
          childAspectRatio: layout.childAspectRatio,
        ),
        itemCount: provider.photos.length,
        itemBuilder: (_, i) => Image.memory(provider.photos[i].imageData,
            fit: BoxFit.cover, alignment: Alignment.topCenter),
      ),
    );
  }
}

// ============================================================
// PAGE 2: GIF PREVIEW
// ============================================================
class GifPreviewPage extends StatefulWidget {
  const GifPreviewPage({super.key});
  @override
  State<GifPreviewPage> createState() => _GifPreviewPageState();
}

class _GifPreviewPageState extends State<GifPreviewPage> {
  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 900), (_) {
      final provider = Provider.of<PhotoProvider>(context, listen: false);
      if (provider.photos.isNotEmpty && mounted) {
        setState(() => _index = (_index + 1) % provider.photos.length);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Consumer<PhotoProvider>(
        builder: (_, provider, __) {
          if (provider.photos.isEmpty) {
            return const Center(
                child: Text("No Photos",
                    style: TextStyle(
                        color: Colors.white,
                        fontFamily: 'Ambitsek',
                        fontSize: 24)));
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Image.memory(
                  provider.photos[_index].imageData,
                  key: ValueKey(_index),
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  alignment: Alignment.topCenter,
                ),
              ),
              IgnorePointer(
                child: Image.asset(
                  'assets/images/gifoverlay.png',
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                ),
              ),
              // Teks "produce your memory" beranimasi typing (looping),
              // di bawah layar (di atas indikator titik).
              const Positioned(
                bottom: 60,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Center(
                    child: TypewriterText(
                      text: 'produce your memory',
                      style: TextStyle(
                        fontFamily: 'Bristol',
                        color: Color(0xFFD23B2B),
                        fontSize: 44,
                        letterSpacing: 1.0,
                        shadows: [
                          Shadow(
                              offset: Offset(0, 2),
                              blurRadius: 6,
                              color: Colors.black45),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 40,
                left: 20,
                child: GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                        color: Colors.black54,
                        border: Border.all(color: Colors.white30),
                        borderRadius: BorderRadius.circular(8)),
                    child: const Icon(Icons.arrow_back,
                        color: Colors.white, size: 24),
                  ),
                ),
              ),
              Positioned(
                bottom: 30,
                left: 0,
                right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    provider.photos.length,
                    (i) => AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: _index == i ? 20 : 8,
                      height: 8,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                          color: _index == i ? Colors.white : Colors.white38,
                          borderRadius: BorderRadius.circular(4)),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ============================================================
// TYPEWRITER TEXT — animasi menulis/menghapus yang looping
// ============================================================
class TypewriterText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final Duration charDuration;
  final Duration holdDuration;
  const TypewriterText({
    super.key,
    required this.text,
    required this.style,
    this.charDuration = const Duration(milliseconds: 120),
    this.holdDuration = const Duration(milliseconds: 1200),
  });

  @override
  State<TypewriterText> createState() => _TypewriterTextState();
}

class _TypewriterTextState extends State<TypewriterText> {
  int _count = 0;
  bool _showCursor = true;
  bool _running = true;
  Timer? _cursorTimer;

  @override
  void initState() {
    super.initState();
    _cursorTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() => _showCursor = !_showCursor);
    });
    _loop();
  }

  Future<void> _loop() async {
    while (_running && mounted) {
      // ketik maju
      for (int i = 0; i <= widget.text.length; i++) {
        if (!_running || !mounted) return;
        setState(() => _count = i);
        await Future.delayed(widget.charDuration);
      }
      await Future.delayed(widget.holdDuration);
      // hapus mundur
      for (int i = widget.text.length; i >= 0; i--) {
        if (!_running || !mounted) return;
        setState(() => _count = i);
        await Future.delayed(
            Duration(milliseconds: widget.charDuration.inMilliseconds ~/ 2));
      }
      await Future.delayed(const Duration(milliseconds: 450));
    }
  }

  @override
  void dispose() {
    _running = false;
    _cursorTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = widget.text.substring(0, _count);
    return Text(
      '$shown${_showCursor ? '|' : ' '}',
      textAlign: TextAlign.center,
      style: widget.style,
    );
  }
}

class _ExtraPaymentDialog extends StatefulWidget {
  final String paymentUrl;
  final String sessionUuid;
  final int amount;
  final String hwid;

  const _ExtraPaymentDialog({
    required this.paymentUrl,
    required this.sessionUuid,
    required this.amount,
    required this.hwid,
  });

  @override
  State<_ExtraPaymentDialog> createState() => _ExtraPaymentDialogState();
}

class _ExtraPaymentDialogState extends State<_ExtraPaymentDialog> {
  final WebviewController _webviewController = WebviewController();
  bool _isWebViewReady = false;
  Timer? _pollingTimer;

  @override
  void initState() {
    super.initState();
    _initWebView();
    _startPolling();
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    if (_isWebViewReady) _webviewController.dispose();
    super.dispose();
  }

  Future<void> _initWebView() async {
    try {
      await _webviewController.initialize();
      await _webviewController.setBackgroundColor(Colors.white);

      _webviewController.loadingState.listen((state) {
        if (state == LoadingState.navigationCompleted) {
          _injectAutoSelectQrisScript();
        }
      });

      await _webviewController.loadUrl(widget.paymentUrl);
      if (mounted) setState(() => _isWebViewReady = true);
    } catch (e) {
      debugPrint("❌ WebView Error: $e");
    }
  }

  void _injectAutoSelectQrisScript() async {
    const jsCode = '''
      (function() {
        var qrisClicked = false;

        function simulateClick(el) {
          ['mousedown', 'mouseup', 'click'].forEach(function(evtType) {
            el.dispatchEvent(new MouseEvent(evtType, {
              bubbles: true, cancelable: true, view: window
            }));
          });
        }

        function trySelectQris(attempt) {
          if (attempt > 30 || qrisClicked) return;

          var xpathResult = document.evaluate(
            "//*[contains(translate(text(),'qris','QRIS'),'QRIS')]",
            document, null,
            XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null
          );

          for (var i = 0; i < xpathResult.snapshotLength; i++) {
            var node = xpathResult.snapshotItem(i);
            var target = node;
            for (var depth = 0; depth < 8; depth++) {
              if (!target) break;
              var tag = (target.tagName || '').toUpperCase();
              var role = (target.getAttribute && target.getAttribute('role')) || '';
              var cursor = window.getComputedStyle(target).cursor;

              if (tag === 'BUTTON' || tag === 'A' || tag === 'LI' ||
                  role === 'button' || role === 'tab' || role === 'option' ||
                  cursor === 'pointer' ||
                  target.onclick != null ||
                  (target.className && target.className.toString().match(/channel|method|option|item|card|tab|accordion/i))) {
                simulateClick(target);
                qrisClicked = true;
                console.log('[AutoQRIS] Clicked QRIS element:', tag, target.className);
                setTimeout(function() { scrollToQrCode(0); }, 2000);
                return;
              }
              target = target.parentElement;
            }
          }

          var fallbackSelectors = [
            '[data-channel*="qris" i]',
            '[data-channel*="QRIS"]',
            '[data-payment*="qris" i]',
            '[data-value*="qris" i]',
            '[id*="qris" i]',
            '[class*="qris" i]',
            '[class*="channel" i]',
          ];
          for (var s = 0; s < fallbackSelectors.length; s++) {
            try {
              var els = document.querySelectorAll(fallbackSelectors[s]);
              for (var j = 0; j < els.length; j++) {
                var txt = (els[j].textContent || '').toUpperCase();
                if (txt.indexOf('QRIS') !== -1) {
                  simulateClick(els[j]);
                  qrisClicked = true;
                  console.log('[AutoQRIS] Fallback clicked:', els[j].tagName, els[j].className);
                  setTimeout(function() { scrollToQrCode(0); }, 2000);
                  return;
                }
              }
            } catch(e) {}
          }

          if (!qrisClicked) {
            var all = document.querySelectorAll('*');
            for (var k = 0; k < all.length; k++) {
              var el = all[k];
              var directText = '';
              for (var c = 0; c < el.childNodes.length; c++) {
                if (el.childNodes[c].nodeType === 3) {
                  directText += el.childNodes[c].textContent;
                }
              }
              if (directText.trim().toUpperCase().indexOf('QRIS') !== -1) {
                var clickTarget = el;
                while (clickTarget && clickTarget !== document.body) {
                  var cs = window.getComputedStyle(clickTarget).cursor;
                  if (cs === 'pointer') {
                    simulateClick(clickTarget);
                    qrisClicked = true;
                    console.log('[AutoQRIS] Last-resort clicked:', clickTarget.tagName);
                    setTimeout(function() { scrollToQrCode(0); }, 2000);
                    return;
                  }
                  clickTarget = clickTarget.parentElement;
                }
                simulateClick(el);
                qrisClicked = true;
                console.log('[AutoQRIS] Direct clicked:', el.tagName);
                setTimeout(function() { scrollToQrCode(0); }, 2000);
                return;
              }
            }
          }

          setTimeout(function() { trySelectQris(attempt + 1); }, 500);
        }

        function scrollToQrCode(attempt) {
          if (attempt > 30) return;
          var qrSelectors = [
            'img[src*="qr"]', 'img[alt*="qr" i]', 'img[alt*="QRIS" i]',
            'canvas', '[class*="qr-code" i]', '[class*="qrcode" i]',
            '[id*="qr" i]', 'img[src*="payment"]',
            'img[src*="doku"]', 'img[src*="shopeepay"]',
          ];
          var qrElement = null;
          for (var s = 0; s < qrSelectors.length; s++) {
            try {
              qrElement = document.querySelector(qrSelectors[s]);
              if (qrElement) break;
            } catch(e) {}
          }
          if (qrElement) {
            qrElement.scrollIntoView({behavior: 'smooth', block: 'center'});
          } else {
            setTimeout(function() { scrollToQrCode(attempt + 1); }, 500);
          }
        }

        var observer = new MutationObserver(function(mutations) {
          if (!qrisClicked) {
            trySelectQris(0);
          } else {
            observer.disconnect();
          }
        });
        observer.observe(document.body || document.documentElement, {
          childList: true, subtree: true
        });

        setTimeout(function() { trySelectQris(0); }, 1500);
      })();
    ''';

    try {
      await _webviewController.executeScript(jsCode);
    } catch (e) {
      debugPrint("⚠️ JS injection error: $e");
    }
  }

  void _startPolling() {
    _pollingTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      final paid = await ApiService()
          .checkPaymentStatus(widget.sessionUuid, hwid: widget.hwid);
      if (paid && mounted) {
        timer.cancel();
        Navigator.pop(context, true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Container(
        width: 500,
        height: 620,
        decoration: BoxDecoration(
          color: _kCream,
          borderRadius: BorderRadius.circular(26),
          boxShadow: const [
            BoxShadow(
                color: Colors.black54, blurRadius: 26, offset: Offset(0, 14)),
          ],
        ),
        child: Column(
          children: [
            // Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [_kRed1, _kRed2],
                ),
                borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
              ),
              child: Row(
                children: [
                  const Text("Pembayaran Tambah Print",
                      style: TextStyle(
                          fontFamily: 'Quicksand',
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          fontSize: 19)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.pop(context, false),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text("Tutup",
                          style: TextStyle(
                              fontFamily: 'Quicksand',
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              fontSize: 13)),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Text("Total: Rp${widget.amount}",
                  style: const TextStyle(
                      fontFamily: 'Quicksand',
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                      color: _kTextBrown)),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    color: Colors.white,
                    child: _isWebViewReady
                        ? Webview(_webviewController)
                        : const Center(
                            child: CircularProgressIndicator(color: _kRed1)),
                  ),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text(
                "Scan QR untuk menyelesaikan pembayaran.",
                style: TextStyle(
                    fontFamily: 'Quicksand',
                    fontSize: 13,
                    color: Color(0xFF8A6A52)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
