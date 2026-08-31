import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_windows/webview_windows.dart';
import '../providers/app_config_provider.dart';
import '../providers/photo_provider.dart';
import '../services/api_service.dart';
import '../services/app_logger.dart';
import '../services/payment_webview_scripts.dart';
import 'preview_print_page.dart';
import '../widgets/retro_keyboard.dart';

// ── Palet desain konsisten (warm / rounded) ──
const Color _kCream = Color(0xFFFFF6E6);
const Color _kRed1 = Color(0xFFC23A2A);
const Color _kRed2 = Color(0xFFA62D1D);
const Color _kBrown = Color(0xFF7A4636);
const Color _kTextBrown = Color(0xFF5A3A2A);

class PaymentPage extends StatefulWidget {
  const PaymentPage({super.key});

  @override
  State<PaymentPage> createState() => _PaymentPageState();
}

class _PaymentPageState extends State<PaymentPage> {
  static const bool _enableVerbosePaymentLogs = bool.fromEnvironment(
    'PAYMENT_VERBOSE_LOGS',
    defaultValue: false,
  );
  static const bool _enableQrisAutoSelect = bool.fromEnvironment(
    'PAYMENT_AUTO_SELECT_QRIS',
    defaultValue: true,
  );

  bool _isSelectionMode = true;
  bool _isLoading = false;
  bool _isPaid = false;
  int _paymentAttemptId = 0;
  bool _paymentFlowCancelled = false;

  // Sesi QRIS yang barisnya sudah tertulis di server tapi belum dibayar.
  // Baris sesi harus dibuat lebih dulu karena /payment/generate mencari harga
  // dan kredensial DOKU lewat baris itu — jadi kalau alurnya berakhir tanpa
  // pembayaran, baris tersebut yang harus kita tutup sendiri.
  String? _outstandingQrisUuid;
  String? _outstandingHwid;

  // Voucher state
  bool _isVoucherMode = false;
  final TextEditingController _voucherController = TextEditingController();
  String _voucherError = "";
  bool _isValidatingVoucher = false;

  // WebView state
  Timer? _pollingTimer;
  final WebviewController _webviewController = WebviewController();
  bool _isWebViewReady = false;

  // -- DEBUG STATE --
  String _webViewError = "";

  @override
  void initState() {
    super.initState();
    if (_enableVerbosePaymentLogs) {
      _runEnvironmentCheck();
    }
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    // Halaman ditutup selagi QRIS belum dibayar (mis. sesi habis waktu) —
    // baris sesinya tetap harus ditutup, bukan ditinggal 'pending'.
    _abandonOutstandingSession();
    _voucherController.dispose();
    if (_isWebViewReady) {
      _webviewController.dispose();
    }
    super.dispose();
  }

  /// Menutup baris sesi QRIS yang terlanjur dibuat tapi tidak jadi dibayar.
  ///
  /// Servernya yang memutuskan hasil akhir: ia menanyakan DOKU dulu dan justru
  /// menandai LUNAS kalau ternyata sudah dibayar, jadi aman dipanggil meski
  /// pelanggan membayar tepat saat menekan "Batalkan".
  ///
  /// Sengaja tidak di-await dan tidak memakai Provider: metode ini juga
  /// dipanggil dari dispose(), saat context sudah tidak boleh dibaca.
  void _abandonOutstandingSession() {
    final uuid = _outstandingQrisUuid;
    final hwid = _outstandingHwid;
    _outstandingQrisUuid = null;
    _outstandingHwid = null;
    if (uuid == null || hwid == null || hwid.isEmpty) return;
    _log("Menutup sesi QRIS yang tidak jadi dibayar: $uuid");
    ApiService().abandonSession(uuid, hwid: hwid);
  }

  // ================================================================
  // DEBUG HELPERS
  // ================================================================
  void _log(String message, {bool verboseOnly = false}) {
    if (verboseOnly && !_enableVerbosePaymentLogs) return;
    final timestamp = DateTime.now().toIso8601String().substring(11, 23);
    final entry = "[$timestamp] $message";
    debugPrint("WEBVIEW_DEBUG: $entry");
    AppLogger.debug("PaymentPage: $entry");
  }

  /// Run environment diagnostics on page load
  Future<void> _runEnvironmentCheck() async {
    _log("=== ENVIRONMENT CHECK START ===", verboseOnly: true);
    _log(
      "Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}",
      verboseOnly: true,
    );
    _log("Dart version: ${Platform.version}", verboseOnly: true);
    _log("Executable: ${Platform.resolvedExecutable}", verboseOnly: true);

    try {
      final webviewVersion = await WebviewController.getWebViewVersion();
      _log("WebView2 Runtime version: $webviewVersion", verboseOnly: true);
    } catch (e) {
      _log("WebView2 Runtime check failed: $e", verboseOnly: true);
    }

    _log("--- Network connectivity test ---", verboseOnly: true);
    for (final host in ['google.com', 'doku.com', '8.8.8.8']) {
      try {
        final result = await InternetAddress.lookup(host)
            .timeout(const Duration(seconds: 5));
        if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
          _log("DNS resolve OK: $host -> ${result[0].address}",
              verboseOnly: true);
        }
      } catch (e) {
        _log("DNS resolve FAIL: $host -> $e", verboseOnly: true);
      }
    }

    final envVars = [
      'WEBVIEW2_BROWSER_EXECUTABLE_FOLDER',
      'WEBVIEW2_USER_DATA_FOLDER',
      'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',
    ];
    for (final v in envVars) {
      final val = Platform.environment[v];
      _log("ENV $v = ${val ?? '(not set)'}", verboseOnly: true);
    }

    _log("=== ENVIRONMENT CHECK END ===", verboseOnly: true);
  }

  // ================================================================
  // QRIS FLOW (WebView)
  // ================================================================
  void _onSelectQRIS() {
    _log("User selected QRIS payment", verboseOnly: true);
    // "Coba Lagi" masuk lewat sini juga. Tiap percobaan memakai UUID baru —
    // wajib, karena invoice_number yang sama tidak bisa dipakai dua kali di
    // DOKU — jadi percobaan sebelumnya harus ditutup dulu, bukan ditinggal.
    _abandonOutstandingSession();
    _paymentAttemptId++;
    _paymentFlowCancelled = false;
    setState(() {
      _isSelectionMode = false;
      _isLoading = true;
      _webViewError = "";
    });
    _initQrisPayment();
  }

  void _initQrisPayment() async {
    final provider = Provider.of<PhotoProvider>(context, listen: false);
    final apiService = Provider.of<ApiService>(context, listen: false);

    if (provider.machineId.isEmpty) {
      _log("Machine ID empty, initializing...", verboseOnly: true);
      await provider.initMachineId();
    }
    _log("Machine ID: ${provider.machineId}", verboseOnly: true);

    final newUuid = "sesi-${DateTime.now().millisecondsSinceEpoch}";
    provider.setSessionUuid(newUuid);
    _log("Session UUID: $newUuid", verboseOnly: true);

    _log("Creating session on backend...", verboseOnly: true);
    final sessionStartResult = await apiService.startSessionDetailed(
      newUuid,
      hwid: provider.machineId,
      paymentMethod: 'qris',
    );

    if (!sessionStartResult.success) {
      _log("Backend session creation FAILED: ${sessionStartResult.code}");
      _resetToMenu(
        sessionStartResult.message ??
            "Gagal membuat sesi. Cek koneksi internet.",
      );
      return;
    }
    _log("Backend session created", verboseOnly: true);
    // Mulai titik ini baris sesi sudah ada di server dan berstatus 'pending'.
    // Setiap jalan keluar dari sini yang bukan "lunas" wajib menutupnya.
    _outstandingQrisUuid = newUuid;
    _outstandingHwid = provider.machineId;

    _log("Requesting payment link from backend...", verboseOnly: true);
    final paymentUrl =
        await apiService.generatePaymentLink(newUuid, hwid: provider.machineId);
    _log("Payment URL response: $paymentUrl", verboseOnly: true);

    if (mounted && paymentUrl != null) {
      _log("Initializing WebView with URL: $paymentUrl", verboseOnly: true);
      await _initWebView(paymentUrl);
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      _startPolling(newUuid);
    } else {
      _log("âŒ Payment URL is null or widget not mounted");
      _resetToMenu("Gagal mendapatkan halaman pembayaran.");
    }
  }

  Future<void> _initWebView(String url) async {
    _log("--- WebView Init START ---", verboseOnly: true);

    // Step 1: Check WebView2 version again right before init
    try {
      final version = await WebviewController.getWebViewVersion();
      _log("Step 1/5: WebView2 version confirmed: $version", verboseOnly: true);
    } catch (e) {
      _log("Step 1/5: ❌ WebView2 version check FAILED: $e");
      if (mounted) {
        setState(() => _webViewError =
            "WebView2 Runtime tidak ditemukan.\n\nInstall dari:\nhttps://developer.microsoft.com/en-us/microsoft-edge/webview2/\n\nError: $e");
      }
      return;
    }

    // Step 2: Initialize controller
    try {
      _log("Step 2/5: Calling _webviewController.initialize()...",
          verboseOnly: true);
      await _webviewController.initialize();
      _log("Step 2/5: ✅ Controller initialized", verboseOnly: true);
    } catch (e, stack) {
      _log("Step 2/5: ❌ Controller initialize FAILED: $e");
      _log("Stack: $stack");
      if (mounted) {
        setState(() => _webViewError =
            "WebView controller gagal initialize.\n\nError: $e\n\nCoba:\n1. Restart aplikasi\n2. Jalankan sebagai Administrator\n3. Update WebView2 Runtime");
      }
      return;
    }

    // Step 3: Set background color
    try {
      _log("Step 3/5: Setting background color...", verboseOnly: true);
      await _webviewController.setBackgroundColor(Colors.white);
      _log("Step 3/5: ✅ Background color set", verboseOnly: true);
    } catch (e) {
      _log("Step 3/5: ❌ setBackgroundColor failed (non-critical): $e");
    }

    // Step 4: Register event listeners
    try {
      _log("Step 4/5: Registering event listeners...", verboseOnly: true);

      _webviewController.loadingState.listen((state) {
        _log("LoadingState changed: $state", verboseOnly: true);
        if (state == LoadingState.navigationCompleted) {
          _log(
            "Navigation completed - injecting QRIS auto-select script",
            verboseOnly: true,
          );
          _injectAutoSelectQrisScript();
        }
      });

      _webviewController.url.listen((url) {
        _log("URL changed: $url", verboseOnly: true);
      });

      // WebErrorStatus is an enum, not an object with .errorCode/.url
      _webviewController.onLoadError.listen((WebErrorStatus error) {
        _log("❌ WebView LOAD ERROR: $error (${error.name})");
        if (mounted) {
          setState(() => _webViewError =
              "Halaman gagal dimuat.\n\nWebErrorStatus: ${error.name}");
        }
      });

      _webviewController.containsFullScreenElementChanged.listen((flag) {
        _log("Fullscreen changed: $flag", verboseOnly: true);
      });

      _webviewController.securityStateChanged.listen((state) {
        _log("Security state changed: $state", verboseOnly: true);
      });

      _log("Step 4/5: ✅ Event listeners registered", verboseOnly: true);
    } catch (e) {
      _log("Step 4/5: ⚠️ Some event listeners failed: $e", verboseOnly: true);
    }

    // Step 5: Load URL
    try {
      _log("Step 5/5: Loading URL: $url", verboseOnly: true);
      await _webviewController.loadUrl(url);
      _log("Step 5/5: ✅ loadUrl() called successfully", verboseOnly: true);

      if (mounted) {
        setState(() => _isWebViewReady = true);
        _log("WebView marked as READY", verboseOnly: true);
      }
    } catch (e, stack) {
      _log("Step 5/5: ❌ loadUrl FAILED: $e");
      _log("Stack: $stack");
      if (mounted) {
        setState(() => _webViewError =
            "Gagal memuat URL pembayaran.\n\nURL: $url\nError: $e");
      }
    }

    _log("--- WebView Init END ---", verboseOnly: true);
  }

  /// Inject JavaScript to auto-select QRIS payment on DOKU checkout page
  /// and scroll to the QR code.
  ///
  /// This behavior is optional because checkout DOM can change over time.
  void _injectAutoSelectQrisScript() async {
    if (!_enableQrisAutoSelect) {
      _log("QRIS auto-select disabled by config.", verboseOnly: true);
      return;
    }

    try {
      await _webviewController
          .executeScript(PaymentWebviewScripts.autoSelectQris);
      _log("QRIS auto-select JS injected", verboseOnly: true);
    } catch (e) {
      _log("JS injection error: $e");
    }
  }

  // ================================================================
  // VOUCHER FLOW
  // ================================================================
  void _onSelectVoucher() {
    _paymentAttemptId++;
    _paymentFlowCancelled = false;
    setState(() {
      _isSelectionMode = false;
      _isVoucherMode = true;
    });
  }

  void _validateAndUseVoucher() async {
    final code = _voucherController.text.trim().toUpperCase();
    if (code.isEmpty) {
      setState(() => _voucherError = "Masukkan kode voucher.");
      return;
    }

    final provider = Provider.of<PhotoProvider>(context, listen: false);
    final apiService = Provider.of<ApiService>(context, listen: false);

    setState(() {
      _isValidatingVoucher = true;
      _voucherError = "";
    });

    if (provider.machineId.isEmpty) await provider.initMachineId();

    final newUuid = "voucher-${DateTime.now().millisecondsSinceEpoch}";
    provider.setSessionUuid(newUuid);

    final sessionStartResult = await apiService.startSessionDetailed(
      newUuid,
      hwid: provider.machineId,
      paymentMethod: 'voucher',
      voucherCode: code,
    );

    if (!mounted) return;

    if (sessionStartResult.success) {
      _handlePaymentSuccess();
    } else {
      setState(() {
        _voucherError =
            sessionStartResult.message ?? "Kode voucher tidak valid atau sudah habis.";
        _isValidatingVoucher = false;
      });
    }
  }

  // ================================================================
  // POLLING & SUCCESS
  // ================================================================
  void _startPolling(String uuid) {
    final attemptId = _paymentAttemptId;
    _log("Starting payment polling for $uuid", verboseOnly: true);
    _pollingTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_paymentFlowCancelled || attemptId != _paymentAttemptId) {
        _log("Stopping stale payment polling for $uuid", verboseOnly: true);
        timer.cancel();
        return;
      }
      final apiService = Provider.of<ApiService>(context, listen: false);
      final provider = Provider.of<PhotoProvider>(context, listen: false);
      final paid =
          await apiService.checkPaymentStatus(uuid, hwid: provider.machineId);
      _log("Poll check: paid=$paid", verboseOnly: true);
      if (paid && !_paymentFlowCancelled && attemptId == _paymentAttemptId) {
        timer.cancel();
        if (mounted) _handlePaymentSuccess();
      }
    });
  }

  void _handlePaymentSuccess() {
    _pollingTimer?.cancel();
    if (_isPaid || _paymentFlowCancelled) {
      _log("Ignoring late payment success because flow already ended.");
      return;
    }
    _log("✅ Payment success!");
    // Sudah lunas — jangan sampai dispose() menutupnya sebagai batal.
    _outstandingQrisUuid = null;
    _outstandingHwid = null;
    if (mounted) {
      setState(() => _isPaid = true);
      // JANGAN reset: foto/hasil render dibutuhkan untuk dicetak.
      // Buka PreviewPrintPage dengan autoPrint → kirim perintah print 1x.
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
                builder: (_) => const PreviewPrintPage(autoPrint: true)),
          );
        }
      });
    }
  }

  void _resetToMenu(String message) {
    _paymentFlowCancelled = true;
    _paymentAttemptId++;
    _pollingTimer?.cancel();
    // Batal / gagal buat link / gagal muat WebView — semuanya lewat sini, jadi
    // satu panggilan di sini menutup semua jalan keluar tanpa pembayaran.
    _abandonOutstandingSession();
    _log("Reset to menu: $message");
    if (mounted) {
      setState(() {
        _isLoading = false;
        _isSelectionMode = true;
        _isVoucherMode = false;
        _isWebViewReady = false;
        _webViewError = "";
        _isPaid = false;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  // ================================================================
  // BUILD
  // ================================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child:
                Image.asset("assets/images/paymentbg.png", fit: BoxFit.cover),
          ),
          Center(
            child: _isSelectionMode
                ? _buildSelectionMenu()
                : _isVoucherMode
                    ? _buildVoucherInput()
                    : _buildPaymentWebView(),
          ),
        ],
      ),
    );
  }

  // ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ MENU PILIHAN ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬
  Widget _buildSelectionMenu() {
    final appConfig = Provider.of<AppConfigProvider>(context, listen: false);
    final canUseQris = appConfig.paymentMethodsEnabled.contains('qris');
    final canUseVoucher = appConfig.paymentMethodsEnabled.contains('voucher') &&
        appConfig.voucherEnabled;

    return Transform.translate(
      offset: const Offset(0, 60),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (canUseQris)
            _PaymentIconButton(
              asset: "assets/images/qris.png",
              label: "QRIS",
              onTap: _onSelectQRIS,
            ),
          if (canUseQris && canUseVoucher) const SizedBox(width: 270),
          if (canUseVoucher)
            _PaymentIconButton(
              asset: "assets/images/voucher.png",
              label: "Voucher",
              onTap: _onSelectVoucher,
            ),
        ],
      ),
    );
  }

  // ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ PAYMENT WEBVIEW ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬
  Widget _buildPaymentWebView() {
    return Transform.translate(
      offset: const Offset(0, 70),
      child: Container(
      width: 500,
      height: 630,
      decoration: BoxDecoration(
        color: _kCream,
        borderRadius: BorderRadius.circular(26),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 26, offset: Offset(0, 14))
        ],
      ),
      child: Column(
        children: [
          // Header
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [_kRed1, _kRed2],
              ),
              borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
            ),
            child: const Center(
              child: Text("Pembayaran QRIS",
                  style: TextStyle(
                      fontFamily: 'Quicksand',
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      fontSize: 22,
                      letterSpacing: 0.5)),
            ),
          ),

          // Content
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: _isLoading
                    ? _buildLoadingView("Memuat halaman pembayaran...")
                    : _webViewError.isNotEmpty
                        ? _buildWebViewErrorView()
                        : _isPaid
                            ? Container(
                                color: Colors.white,
                                child: _buildSuccessView())
                            : _isWebViewReady
                                ? Webview(_webviewController)
                                : _buildLoadingView("Memuat WebView...",
                                    hint: "Jika stuck, cek log backend/payment"),
              ),
            ),
          ),

          // Cancel button
          if (!_isPaid)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: _PaymentPillButton(
                label: "Batalkan",
                primary: false,
                onTap: () {
                  _pollingTimer?.cancel();
                  _resetToMenu("Transaksi dibatalkan.");
                },
              ),
            ),
        ],
      ),
      ),
    );
  }

  Widget _buildLoadingView(String message, {String? hint}) {
    return Container(
      color: Colors.white,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: _kRed1),
            const SizedBox(height: 14),
            Text(message,
                style: const TextStyle(
                    fontFamily: 'Quicksand',
                    fontWeight: FontWeight.w700,
                    color: _kTextBrown,
                    fontSize: 15)),
            if (hint != null) ...[
              const SizedBox(height: 4),
              Text(hint,
                  style: const TextStyle(fontSize: 11, color: Colors.black45)),
            ],
          ],
        ),
      ),
    );
  }

  // WEBVIEW ERROR VIEW
  Widget _buildWebViewErrorView() {
    return Container(
      color: Colors.white,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Pembayaran Bermasalah",
                style: TextStyle(
                    fontFamily: 'Quicksand',
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    color: _kRed2)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF0EC),
                border: Border.all(color: const Color(0xFFE7B7AE)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _webViewError,
                style: const TextStyle(fontSize: 12, color: Color(0xFF7A4636)),
                textAlign: TextAlign.left,
              ),
            ),
            const SizedBox(height: 18),
            _PaymentPillButton(
              label: "Coba Lagi",
              onTap: () {
                setState(() => _webViewError = "");
                _onSelectQRIS();
              },
            ),
          ],
        ),
      ),
    );
  }

  // VOUCHER INPUT
  Widget _buildVoucherInput() {
    return Transform.translate(
      offset: const Offset(0, 50),
      child: Container(
      width: 600,
      padding: const EdgeInsets.fromLTRB(26, 22, 26, 26),
      decoration: BoxDecoration(
        color: _kCream,
        borderRadius: BorderRadius.circular(26),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 26, offset: Offset(0, 14))
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text("Masukkan Kode Voucher",
              style: TextStyle(
                  fontFamily: 'Quicksand',
                  fontWeight: FontWeight.w700,
                  fontSize: 24,
                  color: _kTextBrown)),
          const SizedBox(height: 18),
          if (_isPaid)
            _buildSuccessView()
          else ...[
            // Tampilan kode
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE2C9A6), width: 2),
              ),
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _voucherController,
                builder: (context, value, _) {
                  final hasText = value.text.isNotEmpty;
                  return Text(
                    hasText ? value.text : "XXXXX",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Quicksand',
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 8,
                      color: hasText
                          ? _kTextBrown
                          : const Color(0xFFBFA98A),
                    ),
                  );
                },
              ),
            ),
            if (_voucherError.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(_voucherError,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: _kRed2,
                      fontFamily: 'Quicksand',
                      fontWeight: FontWeight.w700,
                      fontSize: 13)),
            ],
            const SizedBox(height: 18),

            RetroKeyboard(
              controller: _voucherController,
              onKeyTapped: () {
                if (_voucherError.isNotEmpty) {
                  setState(() => _voucherError = "");
                }
              },
            ),

            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: _PaymentPillButton(
                    label: "Kembali",
                    primary: false,
                    onTap: () => setState(() {
                      _isVoucherMode = false;
                      _isSelectionMode = true;
                      _voucherError = "";
                      _voucherController.clear();
                    }),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  flex: 3,
                  child: _PaymentPillButton(
                    label: "Gunakan Voucher",
                    loading: _isValidatingVoucher,
                    onTap: _isValidatingVoucher
                        ? null
                        : _validateAndUseVoucher,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      ),
    );
  }

  Widget _buildSuccessView() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF5FBF6B), Color(0xFF3E9E54)],
              ),
              boxShadow: [
                BoxShadow(
                    color: Colors.black26, blurRadius: 10, offset: Offset(0, 5))
              ],
            ),
            child: const Center(
              child: Text("✓",
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 44,
                      fontWeight: FontWeight.w900,
                      height: 1.0)),
            ),
          ),
          const SizedBox(height: 14),
          const Text("Pembayaran Berhasil!",
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'Quicksand',
                  color: _kTextBrown)),
          const SizedBox(height: 6),
          const Text("Menuju pemilihan frame...",
              style: TextStyle(
                  fontSize: 13,
                  fontFamily: 'Quicksand',
                  color: Color(0xFF8A6A52))),
        ],
      ),
    );
  }
}

// =========================================================
// WIDGETS
// =========================================================

// Tombol pilihan pembayaran: gambar + label di bawah, animasi hover/press.
class _PaymentIconButton extends StatefulWidget {
  final String asset;
  final String label;
  final VoidCallback onTap;
  const _PaymentIconButton({
    required this.asset,
    required this.label,
    required this.onTap,
  });
  @override
  State<_PaymentIconButton> createState() => _PaymentIconButtonState();
}

class _PaymentIconButtonState extends State<_PaymentIconButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final double scale = _pressed ? 0.94 : (_hover ? 1.08 : 1.0);
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
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color:
                          Colors.black.withValues(alpha: _hover ? 0.45 : 0.3),
                      blurRadius: _hover ? 24 : 12,
                      offset: Offset(0, _hover ? 12 : 7),
                    ),
                  ],
                ),
                child: Image.asset(widget.asset,
                    width: 270, height: 270, fit: BoxFit.contain),
              ),
              const SizedBox(height: 12),
              Text(
                widget.label,
                style: const TextStyle(
                  fontFamily: 'Quicksand',
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  fontSize: 35,
                  letterSpacing: 0.5,
                  shadows: [
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
class _PaymentPillButton extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool loading;
  const _PaymentPillButton({
    required this.label,
    required this.onTap,
    this.primary = true,
    this.loading = false,
  });
  @override
  State<_PaymentPillButton> createState() => _PaymentPillButtonState();
}

class _PaymentPillButtonState extends State<_PaymentPillButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onTap != null && !widget.loading;
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
      cursor:
          enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
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
          child: Opacity(
            opacity: enabled ? 1.0 : 0.6,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 15),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: gradient,
                color: widget.primary ? null : _kBrown,
                borderRadius: BorderRadius.circular(40),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: _hover ? 16 : 9,
                    offset: Offset(0, _hover ? 8 : 5),
                  ),
                ],
              ),
              child: widget.loading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2.4),
                    )
                  : Text(
                      widget.label,
                      style: const TextStyle(
                        fontFamily: 'Quicksand',
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        fontSize: 20,
                        letterSpacing: 0.5,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class OutlinedText extends StatelessWidget {
  final String text;
  final String fontFamily;
  final double fontSize;
  final Color textColor;
  final Color outlineColor;
  final FontWeight fontWeight;
  final double letterSpacing;
  final bool hasShadow;

  const OutlinedText({
    super.key,
    required this.text,
    required this.fontFamily,
    required this.fontSize,
    required this.textColor,
    required this.outlineColor,
    this.fontWeight = FontWeight.normal,
    this.letterSpacing = 0.0,
    this.hasShadow = false,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (hasShadow)
          Positioned(
              top: 4,
              left: 4,
              child: Text(text,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontFamily: fontFamily,
                      fontSize: fontSize,
                      fontWeight: fontWeight,
                      letterSpacing: letterSpacing,
                      height: 1.2,
                      color: Colors.black.withValues(alpha: 0.6)))),
        Text(text,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontFamily: fontFamily,
                fontSize: fontSize,
                fontWeight: fontWeight,
                letterSpacing: letterSpacing,
                height: 1.2,
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 8
                  ..color = outlineColor)),
        Text(text,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontFamily: fontFamily,
                fontSize: fontSize,
                fontWeight: fontWeight,
                letterSpacing: letterSpacing,
                height: 1.2,
                color: textColor)),
      ],
    );
  }
}
