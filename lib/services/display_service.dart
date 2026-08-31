import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// Target monitor untuk mode kiosk photobooth.
///
/// Bisa di-override saat build:
///   flutter build windows --dart-define=PHOTOBOOTH_DISPLAY=external
///
/// Nilai yang dikenali:
///   - `external` (default) → pakai monitor selain layar utama (layar customer)
///   - `primary`            → paksa di layar utama (layar laptop)
///   - `0`, `1`, `2`, ...   → paksa ke display index tertentu
const String _kDisplayTarget =
    String.fromEnvironment('PHOTOBOOTH_DISPLAY', defaultValue: 'external');

/// Mengatur di monitor mana window photobooth ditampilkan fullscreen.
///
/// PENTING: ini hanya berfungsi kalau Windows diset ke mode **Extend**
/// (Win+P → Extend). Pada mode Duplicate/Mirror, Windows melaporkan kedua
/// layar sebagai SATU display, jadi tidak ada monitor kedua untuk dituju —
/// bar hitam pada mode itu harus diperbaiki lewat Display Settings.
class DisplayService {
  DisplayService._();

  static final DisplayService instance = DisplayService._();

  // ── Geometri ───────────────────────────────────────────────

  /// Rect sebuah display dalam pixel FISIK Windows.
  ///
  /// screen_retriever melaporkan posisi/ukuran dalam logical pixel milik
  /// monitor itu sendiri (dibagi scale factor monitor tsb), sedangkan
  /// windowManager.setBounds mengalikan nilai yang kita kirim dengan
  /// devicePixelRatio milik window saat ini. Kalau laptop 200% dan monitor
  /// 100%, dua skala itu beda — jadi semua hitungan disamakan ke pixel fisik
  /// dulu, baru dikonversi balik pakai DPR window.
  Rect _physicalBounds(Display display) {
    final double scale = (display.scaleFactor ?? 1).toDouble();
    final Offset position = display.visiblePosition ?? Offset.zero;
    return Rect.fromLTWH(
      position.dx * scale,
      position.dy * scale,
      display.size.width * scale,
      display.size.height * scale,
    );
  }

  bool _isSameDisplay(Display a, Display b) {
    if ((a.name ?? '').isNotEmpty && (b.name ?? '').isNotEmpty) {
      return a.name == b.name;
    }
    return a.visiblePosition == b.visiblePosition && a.size == b.size;
  }

  // ── Pemilihan monitor ──────────────────────────────────────

  Future<List<Display>> allDisplays() => screenRetriever.getAllDisplays();

  /// Monitor yang dipakai untuk tampilan customer.
  ///
  /// Mengembalikan `null` kalau cuma ada satu display terdeteksi (single
  /// screen ATAU mode Duplicate) — pemanggil tinggal fullscreen di tempat.
  Future<Display?> photoboothDisplay() async {
    final List<Display> displays = await allDisplays();
    if (displays.length < 2) return null;

    // Override eksplisit ke index tertentu.
    final int? index = int.tryParse(_kDisplayTarget);
    if (index != null) {
      if (index >= 0 && index < displays.length) return displays[index];
      debugPrint(
          'Display: index $index di luar jangkauan, fallback ke external.');
    }

    if (_kDisplayTarget.toLowerCase() == 'primary') {
      return screenRetriever.getPrimaryDisplay();
    }

    // Heuristik: pada laptop Windows, panel internal hampir selalu
    // \\.\DISPLAY1 karena output adapter-nya dienumerasi paling awal; monitor
    // eksternal dapat nomor lebih besar.
    //
    // JANGAN pakai "pilih yang bukan primary": begitu monitor eksternal
    // dicolok, Windows sering menjadikan MONITOR itu primary (atau operator
    // sengaja mencentang "Make this my main display"), sehingga aturan itu
    // justru menunjuk balik ke laptop. Terbukti di lapangan:
    //   [0] \\.\DISPLAY1 2880x1800 @ (-2880,0)            ← laptop
    //   [1] \\.\DISPLAY2 1920x1080 @ (0,0)      [PRIMARY] ← monitor customer
    final List<Display> sorted = List<Display>.from(displays)
      ..sort((a, b) => _displayNumber(a).compareTo(_displayNumber(b)));
    return sorted.last;
  }

  /// Angka di belakang nama device (`\\.\DISPLAY2` → 2). Dipakai untuk
  /// mengurutkan; nama tanpa angka dianggap paling awal.
  int _displayNumber(Display display) {
    final Match? match = RegExp(r'(\d+)$').firstMatch(display.name ?? '');
    return match == null ? 0 : int.parse(match.group(1)!);
  }

  /// Display yang saat ini menaungi titik tengah window.
  Future<Display?> _currentDisplay(List<Display> displays) async {
    final double dpr = windowManager.getDevicePixelRatio();
    final Rect bounds = await windowManager.getBounds();
    final Offset center = Offset(
      (bounds.left + bounds.width / 2) * dpr,
      (bounds.top + bounds.height / 2) * dpr,
    );
    for (final Display display in displays) {
      if (_physicalBounds(display).contains(center)) return display;
    }
    return null;
  }

  // ── Aksi ───────────────────────────────────────────────────

  /// Geser window ke tengah [display]. Tidak perlu presisi: setFullScreen()
  /// memakai MonitorFromWindow, jadi cukup mayoritas window ada di monitor itu.
  Future<void> _moveWindowTo(Display display) async {
    final Rect target = _physicalBounds(display);
    final double dpr = windowManager.getDevicePixelRatio();
    final double width = target.width * 0.6;
    final double height = target.height * 0.6;

    await windowManager.setBounds(
      Rect.fromLTWH(
        (target.left + (target.width - width) / 2) / dpr,
        (target.top + (target.height - height) / 2) / dpr,
        width / dpr,
        height / dpr,
      ),
    );
  }

  /// Pindahkan window ke [display] lalu fullscreen di sana.
  Future<void> fullScreenOn(Display display) async {
    if (await windowManager.isFullScreen()) {
      await windowManager.setFullScreen(false);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    await _moveWindowTo(display);
    // Beri waktu Windows menyelesaikan perpindahan monitor (dan perubahan DPI)
    // sebelum window di-maximize ke monitor tujuan.
    await Future<void>.delayed(const Duration(milliseconds: 300));

    await windowManager.setFullScreen(true);
    await windowManager.focus();

    final Rect bounds = _physicalBounds(display);
    debugPrint('Display: fullscreen di ${display.name} '
        '(${bounds.width.toInt()}x${bounds.height.toInt()} px).');
  }

  /// Entry point kiosk: fullscreen di monitor customer kalau ada.
  Future<void> goFullScreenOnPhotoboothDisplay() async {
    try {
      await logDisplays();
      final Display? target = await photoboothDisplay();

      if (target == null) {
        await windowManager.setFullScreen(true);
        await windowManager.focus();
        debugPrint('Display: hanya 1 layar terdeteksi (single screen atau mode '
            'Duplicate) → fullscreen di layar aktif.');
        return;
      }

      await fullScreenOn(target);
    } catch (e) {
      debugPrint('Display: gagal fullscreen di monitor target → $e');
      try {
        await windowManager.setFullScreen(true);
      } catch (_) {
        // Sudah dilaporkan di atas; jangan sampai startup kiosk gagal.
      }
    }
  }

  /// Pindahkan window fullscreen ke monitor berikutnya (shortcut F10).
  /// Kalau cuma ada satu display, ini jadi toggle fullscreen biasa.
  Future<void> cycleToNextDisplay() async {
    try {
      final List<Display> displays = await allDisplays();
      if (displays.length < 2) {
        final bool isFull = await windowManager.isFullScreen();
        await windowManager.setFullScreen(!isFull);
        debugPrint('Display: cuma 1 layar → toggle fullscreen ${!isFull}.');
        return;
      }

      final Display? current = await _currentDisplay(displays);
      final int currentIndex = current == null
          ? -1
          : displays.indexWhere((d) => _isSameDisplay(d, current));
      final Display next = displays[(currentIndex + 1) % displays.length];

      await fullScreenOn(next);
    } catch (e) {
      debugPrint('Display: gagal pindah monitor → $e');
    }
  }

  // ── Watcher monitor colok/cabut ────────────────────────────

  Timer? _watchTimer;
  int _lastDisplayCount = 0;
  bool _isRetargeting = false;

  /// Pantau perubahan jumlah monitor selama app jalan.
  ///
  /// Kasus nyata di lapangan: laptop dinyalakan dan app dibuka duluan, monitor
  /// customer baru dicolok belakangan. Tanpa ini window akan tetap menempel di
  /// layar laptop karena penentuan monitor hanya terjadi sekali saat startup.
  ///
  /// Sengaja polling, bukan `screenRetriever.addListener`: listener bawaan
  /// paket membaca `event['type']` yang TIDAK dikirim oleh sisi Windows kalau
  /// jumlah monitor tidak berubah (mis. saat kamu ganti resolusi), sehingga
  /// melempar TypeError yang tidak bisa ditangkap dari sini. Menghitung jumlah
  /// monitor sendiri jauh lebih aman dan biayanya cuma EnumDisplayMonitors.
  Future<void> startDisplayWatcher({
    Duration interval = const Duration(seconds: 3),
  }) async {
    _watchTimer?.cancel();
    try {
      _lastDisplayCount = (await allDisplays()).length;
    } catch (_) {
      _lastDisplayCount = 0;
    }

    _watchTimer = Timer.periodic(interval, (_) async {
      if (_isRetargeting) return;
      try {
        final int count = (await allDisplays()).length;
        if (count == _lastDisplayCount) return;

        final int previous = _lastDisplayCount;
        _lastDisplayCount = count;
        debugPrint('Display: jumlah monitor berubah $previous → $count.');

        _isRetargeting = true;
        await goFullScreenOnPhotoboothDisplay();
      } catch (e) {
        debugPrint('Display: watcher error → $e');
      } finally {
        _isRetargeting = false;
      }
    });
    debugPrint('Display: watcher aktif (mulai dari $_lastDisplayCount layar).');
  }

  void stopDisplayWatcher() {
    _watchTimer?.cancel();
    _watchTimer = null;
  }

  /// Cetak daftar monitor ke log — dipakai saat troubleshooting di lokasi.
  Future<void> logDisplays() async {
    try {
      final List<Display> displays = await allDisplays();
      final Display primary = await screenRetriever.getPrimaryDisplay();

      debugPrint('Display: ${displays.length} layar terdeteksi.');
      for (int i = 0; i < displays.length; i++) {
        final Display d = displays[i];
        final Rect b = _physicalBounds(d);
        final String tag = _isSameDisplay(d, primary) ? ' [PRIMARY]' : '';
        debugPrint('  [$i] ${d.name} '
            '${b.width.toInt()}x${b.height.toInt()} '
            '@ (${b.left.toInt()},${b.top.toInt()}) '
            'scale=${d.scaleFactor}$tag');
      }
    } catch (e) {
      debugPrint('Display: gagal membaca daftar monitor → $e');
    }
  }
}
