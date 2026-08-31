import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/photo_provider.dart';
import '../services/queue_service.dart';
import 'splash_screen.dart';

/// Wrap screen post-payment dengan widget ini untuk:
/// 1. Menampilkan countdown timer di pojok kanan atas
/// 2. Auto-navigate ke SplashScreen saat timer habis
///
/// Contoh pemakaian:
/// ```dart
/// return SessionTimerOverlay(
///   child: Scaffold(...),
/// );
/// ```
class SessionTimerOverlay extends StatefulWidget {
  final Widget child;

  const SessionTimerOverlay({super.key, required this.child});

  @override
  State<SessionTimerOverlay> createState() => _SessionTimerOverlayState();
}

class _SessionTimerOverlayState extends State<SessionTimerOverlay> {

  @override
  void initState() {
    super.initState();
    // Set callback — saat timer habis, navigasi ke SplashScreen
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = Provider.of<PhotoProvider>(context, listen: false);
      provider.onSessionExpired = _handleExpired;
    });
  }

  @override
  void dispose() {
    // Bersihkan callback saat widget di-dispose agar tidak memanggil context yang sudah mati
    final provider = Provider.of<PhotoProvider>(context, listen: false);
    if (provider.onSessionExpired == _handleExpired) {
      provider.onSessionExpired = null;
    }
    super.dispose();
  }

  void _handleExpired() {
    if (!mounted) return;

    final provider = Provider.of<PhotoProvider>(context, listen: false);

    // Sesi yang kehabisan waktu tetap harus menutup tiket antreannya. Tanpa
    // ini tiket tersangkut berstatus 'serving' selamanya dan seluruh antrean
    // di belakangnya berhenti — operator memang bisa melewatinya dari panel,
    // tapi kemacetan yang bisa dicegah sendiri jangan diserahkan ke manusia.
    if (QueueService.instance.aktif != null) {
      QueueService.instance.selesai(
        provider.machineId,
        sessionUuid: provider.sessionUuid,
      );
    }

    // Reset provider
    provider.reset();

    // Navigasi ke SplashScreen, hapus semua route sebelumnya
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const SplashScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Konten screen utama
        widget.child,

        // Timer overlay — pojok kanan atas
        const Positioned(
          top: 16,
          right: 20,
          child: _TimerBadge(),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// Timer badge widget (Consumer — rebuild tiap detik)
// ─────────────────────────────────────────────
class _TimerBadge extends StatelessWidget {
  const _TimerBadge();

  @override
  Widget build(BuildContext context) {
    return Consumer<PhotoProvider>(
      builder: (context, provider, _) {
        // Tidak tampil jika sesi tidak aktif
        if (!provider.isSessionActive) return const SizedBox.shrink();

        final progress = provider.timerProgress;
        final color    = provider.timerColor;
        final timeStr  = provider.timerString;
        final isUrgent = progress < 0.2;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: isUrgent ? 0.85 : 0.65),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: color.withValues(alpha: 0.7),
              width: isUrgent ? 1.5 : 1.0,
            ),
            boxShadow: isUrgent
                ? [BoxShadow(color: color.withValues(alpha: 0.3), blurRadius: 12, spreadRadius: 2)]
                : [],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Progress arc kecil
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 2.5,
                  backgroundColor: Colors.white.withValues(alpha: 0.15),
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
              const SizedBox(width: 8),
              // Teks waktu
              Text(
                timeStr,
                style: TextStyle(
                  color: color,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                  letterSpacing: 1.5,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
