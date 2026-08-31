import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:photobooth_app/providers/app_config_provider.dart';
import 'package:photobooth_app/providers/photo_provider.dart';
import 'package:photobooth_app/screens/diagnostic_page.dart';
import 'package:photobooth_app/screens/splash_screen.dart';
import 'package:photobooth_app/services/api_service.dart';
import 'package:photobooth_app/services/config_service.dart';
import 'package:photobooth_app/services/display_service.dart';
import 'package:photobooth_app/services/upload_queue_service.dart';
import 'package:photobooth_app/services/queue_service.dart';

// ── Global navigator key — dipakai untuk navigasi dari mana saja ──
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
const String _startupScreen =
    String.fromEnvironment('STARTUP_SCREEN', defaultValue: 'diagnostic');
const String _kioskModeOverride =
    String.fromEnvironment('ENABLE_KIOSK_MODE', defaultValue: 'auto');

bool get _shouldEnableKioskMode {
  switch (_kioskModeOverride.toLowerCase()) {
    case 'true':
      return true;
    case 'false':
      return false;
    case 'auto':
    default:
      return kReleaseMode;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Inisialisasi media_kit (pemutar video Windows) ──
  MediaKit.ensureInitialized();

  // ── Backend Auto-Discovery ──
  // Await sebentar (max 2-3 detik) agar aplikasi punya BASE_URL yang benar saat pertama dibuka
  await ConfigService().init();

  // ── Antrean unggahan ──
  // Dijalankan setelah BASE_URL siap: berkas sesi sebelumnya yang gagal
  // diunggah (mati listrik, wifi putus, backend sempat down) dikirim ulang
  // sendiri di latar belakang, tanpa perlu ada yang menekan tombol.
  unawaited(UploadQueueService.instance.start());

  // ── Window setup (desktop) ──
  // windowManager SELALU di-inisialisasi di desktop agar toggle fullscreen
  // (F11) berfungsi baik di debug maupun release. Auto-fullscreen kiosk hanya
  // dinyalakan saat _shouldEnableKioskMode (default: release mode).
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    try {
      await windowManager.ensureInitialized();

      // Mulai dari window normal, lalu naikkan ke fullscreen yang paling aman.
      // Kombinasi alwaysOnTop + skipTaskbar + hidden titlebar sempat membuat
      // input mouse/touch tidak responsif pada beberapa mesin Windows saat debug.
      WindowOptions windowOptions = const WindowOptions(
        fullScreen: false,
        alwaysOnTop: false,
        skipTaskbar: false,
        titleBarStyle: TitleBarStyle.normal,
      );

      windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();

        if (_shouldEnableKioskMode) {
          // Tunggu sebentar agar surface Flutter benar-benar siap sebelum fullscreen.
          Future.delayed(const Duration(seconds: 5), () async {
            // Fullscreen di monitor customer (layar eksternal) kalau ada,
            // bukan sekadar di layar tempat window kebetulan dibuka.
            await DisplayService.instance.goFullScreenOnPhotoboothDisplay();
            // Monitor customer sering baru dicolok setelah app dibuka —
            // pantau terus supaya window ikut pindah begitu terdeteksi.
            await DisplayService.instance.startDisplayWatcher();
            debugPrint('Kiosk fullscreen enabled with safe profile.');
          });
        } else {
          await DisplayService.instance.logDisplays();
          debugPrint('Kiosk auto-fullscreen off (debug). '
              'F11 = toggle fullscreen, F10 = pindah monitor. '
              'Pakai --dart-define=ENABLE_KIOSK_MODE=true untuk tes perilaku kiosk.');
        }
      });
    } catch (e) {
      debugPrint('WindowManager Init Error: $e');
    }
  }

  runApp(const MyApp());
}

// Toggle fullscreen (dipakai shortcut F11). Aman dipanggil kapan pun karena
// windowManager sudah di-inisialisasi di main().
Future<void> toggleFullScreen() async {
  try {
    final bool isFull = await windowManager.isFullScreen();
    if (isFull) {
      await windowManager.setFullScreen(false);
      debugPrint('Fullscreen toggled → false');
    } else {
      // Saat dinyalakan, arahkan ke monitor customer sekalian.
      await DisplayService.instance.goFullScreenOnPhotoboothDisplay();
      debugPrint('Fullscreen toggled → true');
    }
  } catch (e) {
    debugPrint('Toggle fullscreen error: $e');
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  Widget _buildStartupScreen() {
    switch (_startupScreen.toLowerCase()) {
      case 'splash':
        debugPrint('Startup screen override: SplashScreen');
        return const SplashScreen();
      case 'diagnostic':
      default:
        debugPrint('Startup screen override: DiagnosticPage');
        return const DiagnosticPage();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setupSessionExpiredCallback();
    });
  }

  void _setupSessionExpiredCallback() {
    final context = navigatorKey.currentContext;
    if (context == null) return;

    Provider.of<PhotoProvider>(context, listen: false).onSessionExpired = () {
      final nav = navigatorKey.currentState;
      if (nav == null) return;

      final providerCtx = navigatorKey.currentContext;
      if (providerCtx != null) {
        final provider =
            Provider.of<PhotoProvider>(providerCtx, listen: false);

        // Tutup tiket antrean sebelum reset — kalau tidak, tiketnya menggantung
        // 'serving' dan antrean di belakangnya ikut berhenti.
        if (QueueService.instance.aktif != null) {
          QueueService.instance.selesai(
            provider.machineId,
            sessionUuid: provider.sessionUuid,
          );
        }

        provider.reset();
      }

      nav.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const SplashScreen()),
        (route) => false,
      );

      debugPrint('⏱ Navigasi ke SplashScreen via navigatorKey ✅');
    };
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppConfigProvider()),
        ChangeNotifierProvider(create: (_) {
          final photos = PhotoProvider();
          // Kalau strip final baru berhasil diunggah menyusul lewat antrean,
          // panel QR pada sesi yang masih terbuka ikut terbuka kuncinya.
          UploadQueueService.instance.onFinalUploaded = (sessionUuid, url) {
            if (sessionUuid == photos.sessionUuid) {
              photos.setFinalUploaded(url);
            }
          };
          return photos;
        }),
        Provider(create: (_) => ApiService()),
      ],
      child: MaterialApp(
        title: 'Photobooth App',
        debugShowCheckedModeBanner: false,
        navigatorKey: navigatorKey,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          useMaterial3: true,
          fontFamily: 'Poppins',
        ),
        builder: (context, child) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _setupSessionExpiredCallback();
          });
          return _AppOverlay(child: child!);
        },
        home: _buildStartupScreen(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────
// App overlay — gabungan timer badge + hidden close button
// ─────────────────────────────────────────────────────────
class _AppOverlay extends StatelessWidget {
  final Widget child;
  const _AppOverlay({required this.child});

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: FocusNode(),
      autofocus: true,
      onKeyEvent: (event) {
        if (event is! KeyDownEvent) return;

        // 🖥️ TOGGLE FULLSCREEN: F11
        if (event.logicalKey == LogicalKeyboardKey.f11) {
          toggleFullScreen();
          return;
        }

        // 🖥️ PINDAH MONITOR: F10 (fullscreen di layar berikutnya)
        if (event.logicalKey == LogicalKeyboardKey.f10) {
          DisplayService.instance.cycleToNextDisplay();
          return;
        }

        // 🚨 EMERGENCY EXIT: ESC + LEFT SHIFT
        final isEsc = event.logicalKey == LogicalKeyboardKey.escape;
        final isShift = HardwareKeyboard.instance.isShiftPressed;

        if (isEsc && isShift) {
          debugPrint("🆘 EMERGENCY EXIT TRIGGERED!");
          exit(0); // Force kill process
        }
      },
      child: Stack(
        children: [
          child,
          // ... rest of the overlay

          // ── Hidden close button (top center, hold 3 detik untuk close) ──
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Center(child: _HiddenCloseButton()),
          ),

          // ── Timer badge ──
          Consumer<PhotoProvider>(
            builder: (context, provider, _) {
              if (!provider.isSessionActive) return const SizedBox.shrink();

              final progress = provider.timerProgress;
              final timeStr = provider.timerString;
              final bool isUrgent = progress < 0.2;

              // Palet brand (warm): coklat panel + krem teks, aksen emas,
              // berubah merah saat waktu hampir habis.
              const Color cream = Color(0xFFFCE9CE);
              const Color gold = Color(0xFFFFD84D);
              const Color red = Color(0xFFC23A2A);
              final Color bg = isUrgent ? red : const Color(0xFF7A4636);
              final Color ring = isUrgent ? cream : gold;

              return Positioned(
                top: 20,
                right: 24,
                child: SafeArea(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                        color: cream.withValues(alpha: 0.45),
                        width: 1.2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: isUrgent ? 18 : 12,
                          offset: const Offset(0, 6),
                        ),
                        if (isUrgent)
                          BoxShadow(
                            color: red.withValues(alpha: 0.5),
                            blurRadius: 16,
                            spreadRadius: 1,
                          ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _HourglassIcon(color: ring),
                        const SizedBox(width: 9),
                        Text(
                          timeStr,
                          style: const TextStyle(
                            color: cream,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'Quicksand',
                            letterSpacing: 1.0,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────
// Hourglass animation — pengganti CircularProgressIndicator di timer
// ─────────────────────────────────────────────────────────
class _HourglassIcon extends StatefulWidget {
  final Color color;
  const _HourglassIcon({required this.color});

  @override
  State<_HourglassIcon> createState() => _HourglassIconState();
}

class _HourglassIconState extends State<_HourglassIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final icon =
            _ctrl.value < 0.5 ? Icons.hourglass_top : Icons.hourglass_bottom;
        return Icon(icon, color: widget.color, size: 20);
      },
    );
  }
}

// ─────────────────────────────────────────────────────────
// Hidden close button — hold 3 detik di tengah atas untuk exit
// ─────────────────────────────────────────────────────────
class _HiddenCloseButton extends StatefulWidget {
  const _HiddenCloseButton();

  @override
  State<_HiddenCloseButton> createState() => _HiddenCloseButtonState();
}

class _HiddenCloseButtonState extends State<_HiddenCloseButton> {
  bool _isHolding = false;
  double _holdProgress = 0.0;
  Timer? _holdTimer;
  static const _holdDuration = Duration(seconds: 3);
  static const _tickInterval = Duration(milliseconds: 50);

  void _onLongPressStart(LongPressStartDetails _) {
    setState(() {
      _isHolding = true;
      _holdProgress = 0.0;
    });

    final totalTicks =
        _holdDuration.inMilliseconds / _tickInterval.inMilliseconds;

    _holdTimer = Timer.periodic(_tickInterval, (timer) {
      setState(() {
        _holdProgress += 1.0 / totalTicks;
      });

      if (_holdProgress >= 1.0) {
        timer.cancel();
        _closeApp();
      }
    });
  }

  void _onLongPressEnd(LongPressEndDetails _) {
    _cancelHold();
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    if (mounted) {
      setState(() {
        _isHolding = false;
        _holdProgress = 0.0;
      });
    }
  }

  Future<void> _closeApp() async {
    await windowManager.setFullScreen(false);
    await windowManager.close();
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: _onLongPressStart,
      onLongPressEnd: _onLongPressEnd,
      onLongPressCancel: _cancelHold,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 100,
        height: 30,
        decoration: BoxDecoration(
          color: _isHolding
              ? Colors.red.withValues(alpha: 0.3)
              : Colors.transparent,
          borderRadius: const BorderRadius.only(
            bottomLeft: Radius.circular(12),
            bottomRight: Radius.circular(12),
          ),
        ),
        child: _isHolding
            ? Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SizedBox(
                    width: 80,
                    height: 3,
                    child: LinearProgressIndicator(
                      value: _holdProgress,
                      backgroundColor: Colors.white24,
                      valueColor:
                          const AlwaysStoppedAnimation<Color>(Colors.red),
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
              )
            : null,
      ),
    );
  }
}
