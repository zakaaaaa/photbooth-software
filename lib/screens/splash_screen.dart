import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show SystemNavigator, SystemSound, SystemSoundType;
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../providers/app_config_provider.dart';
import '../providers/photo_provider.dart';
import '../services/api_service.dart';
import '../services/license_service.dart';
import '../services/config_service.dart';
import '../services/queue_service.dart';
import '../widgets/queue_claim_dialog.dart';
import 'static_frame_template_page.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  final LicenseService _licenseService = LicenseService();
  final ApiService _apiService = ApiService();

  bool _isLoading = true;
  bool _isLicenseValid = false;
  String _errorMessage = "";
  bool _isHoveringClose = false;

  // ── Antrean pelanggan ──────────────────────────────────────────────────
  // Layar idle merangkap papan panggilan, tapi HANYA saat operator menyalakan
  // mode antrean. Selama `_queue.aktif` false, layar ini tampil dan berperilaku
  // persis seperti sebelum fitur antrean ada — itu jaring pengamannya di
  // lapangan: kalau ada yang aneh, operator matikan antrean dan booth kembali
  // seperti semula tanpa perlu menyentuh aplikasi.
  QueueState _queue = QueueState.mati;
  Timer? _queueTimer;
  String _hwid = '';
  int? _nomorTerakhirDipanggil;

  static const Duration _queuePollInterval = Duration(seconds: 5);

  late final AnimationController _entryController;
  // LIGHT — slide turun (dari atas) + fade in
  late final Animation<Offset> _lightSlide;
  late final Animation<double> _lightFade;
  // OVLSPLASH — slide naik (dari bawah) + fade in
  late final Animation<Offset> _ovlSlide;
  late final Animation<double> _ovlFade;
  // LOGO — fade in di tengah
  late final Animation<double> _logoFade;

  static final String _backendUrl = ConfigService().baseUrl;

  @override
  void initState() {
    super.initState();

    // ── Animasi masuk (sekali, tanpa loop) ──
    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );

    // LIGHT: slide turun dari atas + fade in
    _lightSlide = Tween<Offset>(
      begin: const Offset(0, -0.35),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _entryController,
      curve: const Interval(0.0, 0.75, curve: Curves.easeOutCubic),
    ));
    _lightFade = Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(
      parent: _entryController,
      curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
    ));

    // OVLSPLASH: slide naik dari bawah + fade in
    _ovlSlide = Tween<Offset>(
      begin: const Offset(0, 0.35),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _entryController,
      curve: const Interval(0.0, 0.75, curve: Curves.easeOutCubic),
    ));
    _ovlFade = Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(
      parent: _entryController,
      curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
    ));

    // LOGO: fade in di tengah (sedikit lebih lambat agar muncul setelah overlay)
    _logoFade = Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(
      parent: _entryController,
      curve: const Interval(0.35, 1.0, curve: Curves.easeIn),
    ));

    _entryController.forward(); // jalan sekali

    _preWarmConnection(); // ✅ Fire & forget
    _checkAccess();
  }

  @override
  void dispose() {
    _queueTimer?.cancel();
    _entryController.dispose();
    super.dispose();
  }

  // ── Antrean ────────────────────────────────────────────────────────────

  /// Mulai memantau antrean. Dipanggil hanya setelah lisensi valid — booth
  /// yang tidak boleh beroperasi tidak perlu memanggil siapa-siapa.
  void _mulaiPantauAntrean() {
    _queueTimer?.cancel();
    _muatAntrean();
    _queueTimer = Timer.periodic(_queuePollInterval, (_) => _muatAntrean());
  }

  Future<void> _muatAntrean() async {
    if (_hwid.isEmpty) return;
    final state = await QueueService.instance.ambilState(_hwid);
    if (!mounted) return;

    // Bunyi hanya saat NOMOR BARU dipanggil, bukan tiap polling. Tanpa
    // penjaga ini layar idle akan berbunyi setiap lima detik selama orangnya
    // belum datang, dan operator akan mematikan suaranya di hari pertama.
    final nomorBaru = state.dipanggil?.nomor;
    if (nomorBaru != null && nomorBaru != _nomorTerakhirDipanggil) {
      _nomorTerakhirDipanggil = nomorBaru;
      SystemSound.play(SystemSoundType.alert);
    } else if (nomorBaru == null) {
      _nomorTerakhirDipanggil = null;
    }

    setState(() => _queue = state);
  }

  Future<void> _bukaDialogKlaim() async {
    final berhasil = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => QueueClaimDialog(hwid: _hwid),
    );

    if (berhasil != true || !mounted) return;

    // Tiket sudah tersimpan di QueueService; halaman pemilihan frame yang
    // memutuskan apakah langkahnya bisa dilewati karena frame sudah dipilih
    // dari HP. Alurnya sengaja tetap satu jalur supaya tidak ada logika
    // pemilihan frame yang terduplikasi di sini.
    _onStartPressed();
  }

  /// Kirim request dummy ke backend supaya koneksi TCP & Supabase pool
  /// sudah hangat saat user membuka frame selection.
  void _preWarmConnection() async {
    try {
      await http
          .get(Uri.parse('$_backendUrl/api/frames?hwid=warmup'))
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Sembunyikan error pre-warm karena hanya untuk "pemanasan" koneksi
    }
  }

  void _applyRuntimeSettings(Map<String, dynamic> payload) {
    if (!mounted) return;
    final appConfig = Provider.of<AppConfigProvider>(context, listen: false);
    final photoProvider = Provider.of<PhotoProvider>(context, listen: false);

    appConfig.applyBootstrap(payload);
    final settings = payload['settings'] as Map<String, dynamic>? ?? const {};
    photoProvider.setSessionDuration(
      (settings['session_duration_minutes'] as num?)?.toInt() ?? 5,
    );
  }

  Future<void> _checkAccess() async {
    await Future.delayed(const Duration(seconds: 2));

    final result = await _licenseService.checkLicense();
    if (!mounted) return;

    if (result['success'] == true) {
      final hwid = await _licenseService.getHardwareId();
      _hwid = hwid;
      final bootstrap = await _apiService.fetchBootstrap(hwid);
      if (bootstrap != null) {
        _applyRuntimeSettings(bootstrap);
      } else {
        final fallbackSettings =
            (result['data'] as Map?)?['settings'] as Map<String, dynamic>?;
        if (fallbackSettings != null) {
          _applyRuntimeSettings({
            'settings': fallbackSettings,
            'data': result['data'],
          });
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _isLoading = false;
      if (result['success'] == true) {
        _isLicenseValid = true;
      } else {
        _isLicenseValid = false;
        _errorMessage = result['message'] ?? "Gagal memuat lisensi.";
      }
    });

    if (_isLicenseValid) _mulaiPantauAntrean();
  }

  void _onStartPressed() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const StaticFrameTemplatePage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 1. BACKGROUND — SPLASH-BG.png
          Positioned.fill(
            child:
                Image.asset("assets/images/SPLASH-BG.png", fit: BoxFit.cover),
          ),

          // 2. OVLSPLASH overlay — slide naik (dari bawah) + fade in
          Positioned.fill(
            child: IgnorePointer(
              child: FadeTransition(
                opacity: _ovlFade,
                child: SlideTransition(
                  position: _ovlSlide,
                  child: Image.asset("assets/images/OVLSPLASH.png",
                      fit: BoxFit.cover),
                ),
              ),
            ),
          ),

          // 3. LIGHT overlay — slide turun (dari atas) + fade in
          Positioned.fill(
            child: IgnorePointer(
              child: FadeTransition(
                opacity: _lightFade,
                child: SlideTransition(
                  position: _lightSlide,
                  child:
                      Image.asset("assets/images/LIGHT.png", fit: BoxFit.cover),
                ),
              ),
            ),
          ),

          // 4. LOGO — di tengah, fade in saat masuk (di atas overlay)
          Center(
            child: IgnorePointer(
              child: FadeTransition(
                opacity: _logoFade,
                child: Image.asset(
                  "assets/images/logo.png",
                  width: MediaQuery.of(context).size.width * 0.32,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),

          // 4b. PAPAN PANGGILAN — hanya muncul saat ada nomor yang dipanggil.
          //     Layar ini memang sedang bebas persis di saat panggilan
          //     dibutuhkan: sesi sebelumnya sudah selesai dan pelanggan
          //     berikutnya belum masuk.
          if (_queue.dipanggil != null)
            Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: EdgeInsets.only(
                    top: MediaQuery.of(context).size.height * 0.10),
                child: _buildPapanPanggilan(_queue.dipanggil!),
              ),
            ),

          // 5. TOMBOL / STATUS (bawah tengah) — layering paling atas
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 56),
              child: _buildBottomControl(),
            ),
          ),

          // 6. HOVER CLOSE BUTTON (TOP CENTER)
          Positioned(
            top: 0,
            left: MediaQuery.of(context).size.width / 2 - 100,
            width: 200,
            height: 60,
            child: MouseRegion(
              onEnter: (_) => setState(() => _isHoveringClose = true),
              onExit: (_) => setState(() => _isHoveringClose = false),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: _isHoveringClose ? 1.0 : 0.0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.only(top: 8),
                    child: IconButton(
                      icon: const Icon(Icons.close,
                          color: Colors.white, size: 28),
                      onPressed: () {
                        if (Platform.isWindows ||
                            Platform.isMacOS ||
                            Platform.isLinux) {
                          exit(0);
                        } else {
                          SystemNavigator.pop();
                        }
                      },
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.red.withValues(alpha: 0.8),
                        hoverColor: Colors.red,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Papan panggilan di layar idle. Ukurannya sengaja besar dan kontrasnya
  /// tinggi: ini harus terbaca dari beberapa meter oleh orang yang sedang
  /// berdiri di keramaian tenant, bukan oleh orang yang berdiri di depan layar.
  Widget _buildPapanPanggilan(QueueEntry entri) {
    final lebar = MediaQuery.of(context).size.width;
    final skala = (lebar / 1920).clamp(0.6, 1.3);

    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: 52 * skala, vertical: 26 * skala),
      decoration: BoxDecoration(
        color: const Color(0xFFC23A2A),
        borderRadius: BorderRadius.circular(28 * skala),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 28, offset: Offset(0, 10)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'GILIRAN NOMOR',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 18 * skala,
              fontWeight: FontWeight.w700,
              letterSpacing: 4,
            ),
          ),
          Text(
            '${entri.nomor}',
            style: TextStyle(
              color: Colors.white,
              fontSize: 96 * skala,
              fontWeight: FontWeight.w900,
              height: 1.05,
            ),
          ),
          if (entri.nama != null && entri.nama!.isNotEmpty)
            Text(
              entri.nama!,
              style: TextStyle(
                color: Colors.white,
                fontSize: 26 * skala,
                fontWeight: FontWeight.w700,
              ),
            ),
          SizedBox(height: 6 * skala),
          Text(
            'Masukkan kode 4 angka dari HP kamu',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 15 * skala,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomControl() {
    if (_isLoading) {
      return const SizedBox(
        width: 44,
        height: 44,
        child: CircularProgressIndicator(
          strokeWidth: 3.5,
          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFC23A2A)),
        ),
      );
    }

    if (_isLicenseValid) {
      // Saat mode antrean hidup, tombol "MULAI" biasa sengaja DISEMBUNYIKAN.
      // Kalau tetap ada, siapa pun yang berdiri di depan booth bisa menyerobot
      // giliran orang yang sudah menunggu — dan itu perselisihan yang jauh
      // lebih mahal daripada satu ketukan tambahan. Untuk pengecualian,
      // operator punya sakelar mematikan antrean dari panelnya.
      if (_queue.aktif) {
        return FadeTransition(
          opacity: _lightFade,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              StartButton(
                onPressed: _bukaDialogKlaim,
                label: 'MASUKKAN KODE',
              ),
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _queue.menunggu == 0
                      ? 'Belum ada yang mengantre'
                      : '${_queue.menunggu} orang mengantre',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      }

      return FadeTransition(
        opacity: _lightFade,
        child: StartButton(onPressed: _onStartPressed),
      );
    }

    // License invalid → pesan + tombol coba lagi
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            _errorMessage,
            style: const TextStyle(
                color: Color(0xFFFF8A7A), fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 12),
        StartButton(
          label: "coba lagi",
          onPressed: () {
            setState(() {
              _isLoading = true;
              _errorMessage = "";
            });
            _preWarmConnection();
            _checkAccess();
          },
        ),
      ],
    );
  }
}

// =========================================================
// WIDGET: START BUTTON (hover animasi)
// =========================================================
class StartButton extends StatefulWidget {
  final VoidCallback onPressed;
  final String label;
  const StartButton({super.key, required this.onPressed, this.label = "start"});

  @override
  State<StartButton> createState() => _StartButtonState();
}

class _StartButtonState extends State<StartButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final double scale = _pressed ? 0.96 : (_hover ? 1.06 : 1.0);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onPressed();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: scale,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            padding:
                const EdgeInsets.symmetric(horizontal: 46, vertical: 18),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: _hover
                    ? const [Color(0xFFD0452F), Color(0xFFB23320)]
                    : const [Color(0xFFC23A2A), Color(0xFFA62D1D)],
              ),
              borderRadius: BorderRadius.circular(40),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: _hover ? 24 : 14,
                  offset: Offset(0, _hover ? 11 : 6),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.label,
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(width: 14),
                AnimatedSlide(
                  offset: _hover ? const Offset(0.22, 0) : Offset.zero,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  child: const Icon(
                    Icons.arrow_forward_rounded,
                    color: Colors.white,
                    size: 27,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
