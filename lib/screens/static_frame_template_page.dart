import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../services/config_service.dart';
import '../services/api_service.dart';
import '../services/queue_service.dart';
import '../providers/photo_provider.dart';
import 'camera_page.dart';

// ==========================================
// MODEL
// ==========================================
class FrameTemplate {
  final String id;
  final String name;
  final String imageUrl;
  final String thumbnailUrl;
  final int photoCount;
  final double outputWidth;
  final double outputHeight;
  final String? orientation;
  final bool needsLayoutReview;
  final String? layoutReviewReason;
  final FrameLayout layout;
  final List<PhotoSlot> photoSlots;

  FrameTemplate({
    required this.id,
    required this.name,
    required this.imageUrl,
    required this.thumbnailUrl,
    required this.photoCount,
    required this.outputWidth,
    required this.outputHeight,
    required this.orientation,
    required this.needsLayoutReview,
    required this.layoutReviewReason,
    required this.layout,
    required this.photoSlots,
  });

  bool get hasCustomSlots => photoSlots.isNotEmpty;

  factory FrameTemplate.fromJson(Map<String, dynamic> json) {
    final count        = json['photo_count'] as int? ?? 4;
    final imageUrl     = json['image_url']     as String? ?? '';
    final thumbnailUrl = json['thumbnail_url'] as String?;

    List<PhotoSlot> slots = [];
    final rawSlots = json['photo_slots'];
    if (rawSlots != null && rawSlots is List) {
      slots = rawSlots
          .map((s) => PhotoSlot.fromJson(s as Map<String, dynamic>))
          .toList();
    }

    return FrameTemplate(
      id:           json['id'] as String,
      name:         json['name'] as String,
      imageUrl:     imageUrl,
      thumbnailUrl: (thumbnailUrl != null && thumbnailUrl.isNotEmpty)
                        ? thumbnailUrl
                        : imageUrl,
      photoCount:   count,
      outputWidth:  (json['output_width']  as num?)?.toDouble() ?? 344.0,
      outputHeight: (json['output_height'] as num?)?.toDouble() ?? 515.0,
      orientation: (json['orientation'] as String?)?.trim(),
      needsLayoutReview: json['needs_layout_review'] == true,
      layoutReviewReason: (json['layout_review_reason'] as String?)?.trim(),
      layout:       _layoutForCount(count),
      photoSlots:   slots,
    );
  }

  static FrameLayout _layoutForCount(int count) {
    switch (count) {
      case 3:
        return const FrameLayout(
          topPadding: 59, bottomPadding: 59,
          leftPadding: 10, rightPadding: 10,
          horizontalSpacing: 20, verticalSpacing: 10,
          childAspectRatio: 1.2,
        );
      case 4:
      default:
        return const FrameLayout(
          topPadding: 25, leftPadding: 10, rightPadding: 5,
          bottomPadding: 40, horizontalSpacing: 5, verticalSpacing: 13,
          childAspectRatio: 1.0,
        );
    }
  }
}

// ==========================================
// PAGE
// ==========================================
class StaticFrameTemplatePage extends StatefulWidget {
  const StaticFrameTemplatePage({super.key});

  @override
  State<StaticFrameTemplatePage> createState() => _StaticFrameTemplatePageState();
}

class _StaticFrameTemplatePageState extends State<StaticFrameTemplatePage> {
  List<FrameTemplate> _templates = [];
  bool _isLoading = true;
  String _error   = '';
  int _currentPage = 0;

  static const int _columnsPerPage = 4;
  static const int _rowsPerPage = 1;
  static const int _itemsPerPage = _columnsPerPage * _rowsPerPage;

  static final String _baseUrl = '${ConfigService().baseUrl}/api';

  @override
  void initState() {
    super.initState();
    _fetchFrames();
  }

  /// Kalau pelanggan sudah memilih frame dari HP-nya sambil mengantre, langkah
  /// ini dilewati sepenuhnya. Inilah satu-satunya bagian sesi yang benar-benar
  /// bisa dipindahkan ke luar booth, dan itu memangkas waktu pemakaian kios.
  void _lewatiJikaFrameSudahDipilih() {
    final frameId = QueueService.instance.aktif?.frameId;
    if (frameId == null || frameId.isEmpty) return;

    FrameTemplate? cocok;
    for (final t in _templates) {
      if (t.id == frameId) {
        cocok = t;
        break;
      }
    }

    // Frame bisa saja dinonaktifkan operator setelah pelanggan memilihnya.
    // Kalau begitu, biarkan dia memilih ulang di layar — jauh lebih baik
    // daripada menggantung di halaman yang seolah membeku.
    final terpilih = cocok;
    if (terpilih == null) return;

    // Ditunda ke frame berikutnya supaya navigasinya tidak terjadi di tengah
    // build; halaman ini baru saja selesai setState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      pilihFrameTemplate(context, terpilih);
    });
  }

  Future<void> _fetchFrames() async {
    setState(() { _isLoading = true; _error = ''; });

    try {
      final provider = Provider.of<PhotoProvider>(context, listen: false);
      if (provider.machineId.isEmpty) await provider.initMachineId();
      final hwid = provider.machineId;

      final uri = Uri.parse('$_baseUrl/frames?hwid=${Uri.encodeComponent(hwid)}');

      // Auto-retry 3x dengan jeda 2 detik
      http.Response? response;
      Exception? lastError;
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          response = await http.get(uri).timeout(const Duration(seconds: 15));
          break;
        } catch (e) {
          lastError = e as Exception?;
          debugPrint('⚠️ Attempt $attempt gagal: $e');
          if (attempt < 3) await Future.delayed(const Duration(seconds: 2));
        }
      }
      if (response == null) throw lastError ?? Exception('Timeout');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          final List<dynamic> framesJson = data['frames'] ?? [];

          // ✅ Set durasi dari API
          final int durationMin = (data['session_duration_minutes'] as num? ?? 5).toInt();
          if (mounted) {
            final provider = Provider.of<PhotoProvider>(context, listen: false);
            provider.setSessionDuration(durationMin);
          }

          setState(() {
            _templates = framesJson.map((j) => FrameTemplate.fromJson(j)).toList();
            _isLoading = false;
            _currentPage = 0;
          });
          _lewatiJikaFrameSudahDipilih();
          return;
        }
      }

      setState(() {
        _error = 'Gagal memuat frame. Cek koneksi internet.';
        _isLoading = false;
      });

    } catch (e) {
      setState(() {
        _error = 'Tidak dapat terhubung ke server.\n$e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset('assets/images/BGG.png', fit: BoxFit.cover),

          // ── KONTEN (lampu + frame) — beri ruang atas untuk logo ──
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.only(top: 202),
              child: _isLoading
                  ? const Center(
                      child:
                          CircularProgressIndicator(color: Color(0xFFFFED00)))
                  : _error.isNotEmpty
                      ? _buildError()
                      : _templates.isEmpty
                          ? _buildEmpty()
                          : _buildGrid(),
            ),
          ),

          // ── LOGO — layering paling atas (di atas lampu) ──
          Positioned(
            top: 40,
            left: 0,
            right: 0,
            child: Center(
              child: Image.asset(
                'assets/images/logo.png',
                height: 150,
                fit: BoxFit.contain,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    final totalPagesRaw = (_templates.length / _itemsPerPage).ceil();
    final totalPages = totalPagesRaw < 1 ? 1 : totalPagesRaw;
    final safeCurrentPage = _currentPage >= totalPages ? totalPages - 1 : _currentPage;

    final start = safeCurrentPage * _itemsPerPage;
    final end = (start + _itemsPerPage) > _templates.length
        ? _templates.length
        : (start + _itemsPerPage);
    final pageItems = _templates.sublist(start, end);
    final canGoPrev = safeCurrentPage > 0;
    final canGoNext = safeCurrentPage < totalPages - 1;

    return LayoutBuilder(
      builder: (context, outer) {
        final double h = outer.maxHeight;
        // Lampu besar, menempel mentok atas.
        const double lampHeight = 500.0;
        // Frame digeser ke atas (lebih dekat ke tengah layar) tanpa
        // mengubah ukuran: kurangi top, tambah bottom dengan selisih sama.
        final double framesTop = h * 0.08;
        final double framesBottom = h * 0.34;
        final double bandH = h - framesTop - framesBottom;

        // Lebar tiap frame mengikuti rasio asli, agar frame & lampu
        // bisa di-center sebagai grup (bukan Expanded full width).
        double frameWidthFor(FrameTemplate t) =>
            bandH * (t.outputWidth / t.outputHeight);

        final Widget framesRow = Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (int i = 0; i < pageItems.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(
                  width: frameWidthFor(pageItems[i]),
                  child: RetroFrameCard(template: pageItems[i]),
                ),
              ),
          ],
        );

        final Widget lampsRow = Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int i = 0; i < pageItems.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(
                  width: frameWidthFor(pageItems[i]),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: _AnimatedLamp(
                      key: ValueKey('lamp-$safeCurrentPage-$i'),
                      index: i,
                      height: lampHeight,
                    ),
                  ),
                ),
              ),
          ],
        );

        return Stack(
          clipBehavior: Clip.none,
          children: [
            // FRAME (area bawah)
            Positioned(
              left: 96,
              right: 96,
              top: framesTop,
              bottom: framesBottom,
              child: framesRow,
            ),

            // LAMPU.png — mentok atas, sejajar di atas tiap frame.
            // top = posisi vertikal (makin kecil/negatif = makin ke atas).
            // left/right beda 40 → titik tengah bergeser 20px ke kanan.
            Positioned(
              left: 116,
              right: 76,
              top: -450,
              child: lampsRow,
            ),

            // ◀ Panah kiri — sejajar tengah band frame
            Positioned(
              left: 24,
              top: framesTop,
              bottom: framesBottom,
              child: Center(
                child: _CircleArrowButton(
                  icon: Icons.chevron_left_rounded,
                  enabled: canGoPrev,
                  onTap: () => setState(() => _currentPage--),
                ),
              ),
            ),

            // ▶ Panah kanan — sejajar tengah band frame
            Positioned(
              right: 24,
              top: framesTop,
              bottom: framesBottom,
              child: Center(
                child: _CircleArrowButton(
                  icon: Icons.chevron_right_rounded,
                  enabled: canGoNext,
                  onTap: () => setState(() => _currentPage++),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, color: Colors.white38, size: 64),
          const SizedBox(height: 16),
          Text(_error,
            style: const TextStyle(color: Colors.white60, fontSize: 14),
            textAlign: TextAlign.center),
          const SizedBox(height: 24),
          GestureDetector(
            onTap: _fetchFrames,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF0000AA),
                border: Border.all(color: Colors.white24)),
              child: const Text("Coba Lagi",
                style: TextStyle(fontFamily: 'Ambitsek', color: Colors.white,
                  fontSize: 16, letterSpacing: 1)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.photo_library_outlined, color: Colors.white24, size: 64),
          SizedBox(height: 16),
          Text("Belum ada frame tersedia.",
            style: TextStyle(color: Colors.white38, fontSize: 16, fontFamily: 'Ambitsek')),
          SizedBox(height: 8),
          Text("Hubungi admin untuk menambahkan frame.",
            style: TextStyle(color: Colors.white24, fontSize: 13)),
        ],
      ),
    );
  }
}

// ==========================================
// FRAME CARD
// ==========================================
class RetroFrameCard extends StatefulWidget {
  final FrameTemplate template;
  const RetroFrameCard({super.key, required this.template});

  @override
  State<RetroFrameCard> createState() => _RetroFrameCardState();
}

class _RetroFrameCardState extends State<RetroFrameCard> {
  bool _isPressed = false;
  bool _isHovered = false;

  static const List<Color> _slotColors = [
    Color(0xFF6366f1), Color(0xFF10b981), Color(0xFFf59e0b), Color(0xFFef4444),
    Color(0xFF8b5cf6), Color(0xFF06b6d4), Color(0xFFf472b6), Color(0xFF84cc16),
    Color(0xFFfb923c), Color(0xFF38bdf8),
  ];

  List<Widget> _buildSlotPreviews(
    List<PhotoSlot> slots,
    double frameW, double frameH,
    double dispW,  double dispH,
  ) {
    final scaleX = dispW / frameW;
    final scaleY = dispH / frameH;

    return slots.asMap().entries.map((entry) {
      final i     = entry.key;
      final slot  = entry.value;
      final color = _slotColors[slot.photoIndex % _slotColors.length];

      final left     = slot.x      * scaleX;
      final top      = slot.y      * scaleY;
      final width    = slot.width  * scaleX;
      final height   = slot.height * scaleY;
      final fontSize = (width * 0.28).clamp(8.0, 22.0);

      return Positioned(
        left: left, top: top, width: width, height: height,
        child: Transform.rotate(
          angle: slot.rotation * (3.14159265 / 180),
          child: Container(
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.75),
              border: Border.all(color: color, width: 1.5),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${i + 1}',
                    style: TextStyle(
                      color: Colors.white, fontSize: fontSize,
                      fontWeight: FontWeight.w900, fontFamily: 'Poppins',
                      shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
                      height: 1,
                    ),
                  ),
                  if (width > 30 && height > 30)
                    Text(
                      'F${slot.photoIndex + 1}',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: (fontSize * 0.55).clamp(6.0, 12.0),
                        fontFamily: 'Poppins', fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  // Ketukan manual dan pemilihan otomatis dari tiket antrean menempuh
  // jalur yang sama persis — lihat pilihFrameTemplate di bawah.
  Future<void> _handleSelection() =>
      pilihFrameTemplate(context, widget.template);

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit:  (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown:   (_) => setState(() => _isPressed = true),
        onTapUp:     (_) { setState(() => _isPressed = false); _handleSelection(); },
        onTapCancel: () => setState(() => _isPressed = false),
        child: AnimatedScale(
          scale: _isPressed ? 0.95 : (_isHovered ? 1.04 : 1.0),
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          // Frame transparan — tanpa background/border/header apa pun
          child: LayoutBuilder(
            builder: (context, constraints) {
              final frameW = widget.template.outputWidth;
              final frameH = widget.template.outputHeight;
              final scaleX = constraints.maxWidth  / frameW;
              final scaleY = constraints.maxHeight / frameH;
              final scale  = scaleX < scaleY ? scaleX : scaleY;
              final dispW  = frameW * scale;
              final dispH  = frameH * scale;

              return Center(
                child: SizedBox(
                  width: dispW, height: dispH,
                  child: Stack(
                    children: [
                      if (widget.template.hasCustomSlots)
                        ..._buildSlotPreviews(
                          widget.template.photoSlots,
                          frameW, frameH, dispW, dispH,
                        ),
                      Positioned.fill(
                        child: Image.network(
                          widget.template.thumbnailUrl,
                          fit: BoxFit.contain,
                          cacheWidth: 400,
                          loadingBuilder: (ctx, child, progress) {
                            if (progress == null) return child;
                            return Center(
                              child: SizedBox(
                                width: 22, height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white70,
                                  value: progress.expectedTotalBytes != null
                                      ? progress.cumulativeBytesLoaded /
                                        progress.expectedTotalBytes!
                                      : null,
                                ),
                              ),
                            );
                          },
                          errorBuilder: (ctx, err, st) => const Center(
                            child: Icon(Icons.broken_image, size: 40, color: Colors.white30)),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

// ==========================================
// OUTLINED TEXT WIDGET
// ==========================================
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
    super.key, required this.text, required this.fontFamily,
    required this.fontSize, required this.textColor, required this.outlineColor,
    this.fontWeight = FontWeight.normal, this.letterSpacing = 0.0, this.hasShadow = false,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (hasShadow) Positioned(top: 4, left: 4, child: Text(text,
          textAlign: TextAlign.center,
          style: TextStyle(fontFamily: fontFamily, fontSize: fontSize,
            fontWeight: fontWeight, letterSpacing: letterSpacing, height: 1.2,
            color: Colors.black.withValues(alpha: 0.6)))),
        Text(text, textAlign: TextAlign.center,
          style: TextStyle(fontFamily: fontFamily, fontSize: fontSize,
            fontWeight: fontWeight, letterSpacing: letterSpacing, height: 1.2,
            foreground: Paint()..style = PaintingStyle.stroke..strokeWidth = 8..color = outlineColor)),
        Text(text, textAlign: TextAlign.center,
          style: TextStyle(fontFamily: fontFamily, fontSize: fontSize,
            fontWeight: fontWeight, letterSpacing: letterSpacing, height: 1.2,
            color: textColor)),
      ],
    );
  }
}

// ==========================================
// ANIMATED LAMP (LAMPU.png) — slide-down saat masuk
// ==========================================
class _AnimatedLamp extends StatefulWidget {
  final int index;
  final double height;
  const _AnimatedLamp({super.key, required this.index, required this.height});

  @override
  State<_AnimatedLamp> createState() => _AnimatedLampState();
}

class _AnimatedLampState extends State<_AnimatedLamp> {
  bool _show = false;

  @override
  void initState() {
    super.initState();
    // Stagger per frame agar lampu turun berurutan.
    Future.delayed(Duration(milliseconds: 100 + widget.index * 130), () {
      if (mounted) setState(() => _show = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      offset: _show ? Offset.zero : const Offset(0, -0.9),
      duration: const Duration(milliseconds: 550),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: _show ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 450),
        child: SizedBox(
          height: widget.height,
          child: Image.asset('assets/images/LAMPU.png', fit: BoxFit.contain),
        ),
      ),
    );
  }
}

// ==========================================
// CIRCLE ARROW BUTTON (navigasi halaman frame)
// ==========================================
class _CircleArrowButton extends StatefulWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _CircleArrowButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  State<_CircleArrowButton> createState() => _CircleArrowButtonState();
}

class _CircleArrowButtonState extends State<_CircleArrowButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.enabled;
    final double scale =
        !enabled ? 1.0 : (_pressed ? 0.92 : (_hover ? 1.08 : 1.0));

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled
            ? (_) {
                setState(() => _pressed = false);
                widget.onTap();
              }
            : null,
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedOpacity(
          opacity: 1.0,
          duration: const Duration(milliseconds: 150),
          child: AnimatedScale(
            scale: scale,
            duration: const Duration(milliseconds: 130),
            curve: Curves.easeOut,
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFFD0452F), Color(0xFFA62D1D)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.30),
                    blurRadius: (_hover && enabled) ? 18 : 10,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Icon(widget.icon, color: Colors.white, size: 38),
            ),
          ),
        ),
      ),
    );
  }
}


/// Menerapkan sebuah frame lalu melanjutkan ke kamera: membuat sesi kalau
/// belum ada, mengunci frame ke sesi itu, menyalakan timer, dan berpindah
/// halaman.
///
/// Dipisah dari widget kartunya karena ada DUA pemanggil: ketukan pelanggan
/// di layar, dan pemilihan otomatis ketika pelanggan sudah memilih frame
/// dari HP-nya sambil mengantre.
Future<void> pilihFrameTemplate(BuildContext context, FrameTemplate template) async {
  final provider = Provider.of<PhotoProvider>(context, listen: false);

  if (template.needsLayoutReview) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          "Frame ini perlu review layout (${template.layoutReviewReason ?? 'mismatch besar'}). Pilih frame lain.",
        ),
        backgroundColor: Colors.orangeAccent,
      ),
    );
    return;
  }

  if (provider.machineId.isEmpty) {
    await provider.initMachineId();
  }
  final hwid = provider.machineId;
  if (hwid.isEmpty) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("HWID belum terdeteksi. Coba lagi."),
        backgroundColor: Colors.redAccent,
      ),
    );
    return;
  }

  // ── Buat sesi baru di sini (pembayaran dilakukan setelah preview) ──
  var sessionUuid = provider.sessionUuid;
  if (sessionUuid.isEmpty) {
    sessionUuid = "sesi-${DateTime.now().millisecondsSinceEpoch}";
    provider.setSessionUuid(sessionUuid);
    final started = await ApiService().startSessionDetailed(
      sessionUuid,
      hwid: hwid,
      paymentMethod: 'qris',
    );
    if (!started.success) {
      provider.setSessionUuid(''); // reset agar bisa coba lagi
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(started.message ?? "Gagal membuat sesi. Cek koneksi internet."),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }
  }

  final attached = await ApiService().attachFrameToSession(
    sessionUuid: sessionUuid,
    frameId: template.id,
    hwid: hwid,
  );
  if (!attached) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Gagal mengunci frame ke sesi. Coba lagi."),
        backgroundColor: Colors.redAccent,
      ),
    );
    return;
  }
  if (!context.mounted) return;

  if (template.hasCustomSlots) {
    provider.setFrameModeWithSlots(
      FrameMode.static,
      photoCount:   template.photoCount,
      frameAsset:   template.imageUrl,
      photoSlots:   template.photoSlots,
      customWidth:  template.outputWidth,
      customHeight: template.outputHeight,
    );
    debugPrint('✅ Frame "${template.name}" — ${template.photoSlots.length} slots, ${template.photoCount} foto');
  } else {
    provider.setFrameMode(
      FrameMode.static,
      photoCount:   template.photoCount,
      frameAsset:   template.imageUrl,
      layout:       template.layout,
      customWidth:  template.outputWidth,
      customHeight: template.outputHeight,
    );
    debugPrint('⚠️ Frame "${template.name}" — fallback layout (belum ada slots)');
  }

  // ✅ MULAI TIMER SESI DI SINI — Setelah frame dipilih
  if (!provider.isSessionActive) {
    provider.startSession();
  }

  Navigator.push(
      context, MaterialPageRoute(builder: (_) => const CameraPage()));
}