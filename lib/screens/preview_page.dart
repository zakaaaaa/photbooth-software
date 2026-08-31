import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import '../providers/photo_provider.dart';
import '../services/api_service.dart';
import '../services/video_result_service.dart';
import '../services/gif_result_service.dart';
import '../utils/image_filter.dart';
import '../utils/frame_composer.dart';
import 'preview_print_page.dart' show PhotoPreviewPage, GifPreviewPage;
import 'video_result_page.dart';
import 'payment_page.dart';
import '../services/upload_queue_service.dart';

// ================================================================
// PREVIEW PAGE
// Tujuan dari CameraPage. Menampilkan hasil foto + frame di tengah,
// dengan tombol Foto / GIF / Video / Cetak di sisi kiri-kanan.
// ================================================================
class PreviewPage extends StatelessWidget {
  const PreviewPage({super.key});

  static const double _deg2rad = 3.141592653589793 / 180;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<PhotoProvider>();

    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, c) {
          final double w = c.maxWidth;
          final double h = c.maxHeight;

          // Ukuran & jarak responsif terhadap ukuran window (proporsi reference).
          final double iconSize = (h * 0.17).clamp(78.0, 150.0);
          // Tombol 10% dari tepi kiri/kanan.
          final double sideInset = (w * 0.10).clamp(48.0, 190.0);
          final double colGap = (h * 0.06).clamp(20.0, 56.0);
          // Frame tengah ~70% tinggi → margin atas/bawah 15% tiap sisi,
          // lalu diturunkan 15% (atas 15%→30%, bawah 15%→0%).
          final double topMargin = h * 0.30;
          const double bottomMargin = 0.0;
          // Preview foto dinaikkan 7% dari posisi tombol.
          final double previewTopMargin = topMargin - h * 0.07;
          final double previewBottomMargin = bottomMargin + h * 0.07;
          // Area tengah dijaga agar tidak menabrak kolom tombol.
          final double centerInset = sideInset + iconSize + 28;

          return Stack(
            fit: StackFit.expand,
            children: [
              // 1. BACKGROUND (16:9, cover)
              Image.asset('assets/images/previewbg.png', fit: BoxFit.cover),

              // 2. PREVIEW HASIL FOTO + FRAME (tengah, dengan margin)
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.only(
                    left: centerInset,
                    right: centerInset,
                    top: previewTopMargin,
                    bottom: previewBottomMargin,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      // Batasi tinggi frame/foto tengah (diperkecil).
                      constraints: BoxConstraints(maxHeight: h * 0.50),
                      child: _CenterPreview(provider: provider),
                    ),
                  ),
                ),
              ),

              // 3. KIRI: Foto + GIF
              Positioned(
                left: sideInset,
                top: topMargin,
                bottom: bottomMargin,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _PreviewIconButton(
                        asset: 'assets/images/foto.png',
                        label: 'Foto',
                        size: iconSize,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const PhotoPreviewPage()),
                        ),
                      ),
                      SizedBox(height: colGap),
                      _PreviewIconButton(
                        // video.png = gambar GIF (sesuai visual)
                        asset: 'assets/images/video.png',
                        label: 'GIF',
                        size: iconSize,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const GifPreviewPage()),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // 4. KANAN: Video (placeholder) + Cetak
              Positioned(
                right: sideInset,
                top: topMargin,
                bottom: bottomMargin,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _PreviewIconButton(
                        // gif.png = gambar clapper/video (sesuai visual)
                        asset: 'assets/images/gif.png',
                        label: 'Video',
                        size: iconSize,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const VideoResultPage()),
                        ),
                      ),
                      SizedBox(height: colGap),
                      _PreviewIconButton(
                        asset: 'assets/images/cetak.png',
                        label: 'Cetak',
                        size: iconSize,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const PaymentPage()),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // 5. PANEL FILTER (bawah-tengah) — pilihan filter dipindah ke sini
              //    dari CameraPage. Foto diambil RAW, filter diterapkan di sini.
              Positioned(
                left: centerInset,
                right: centerInset,
                bottom: h * 0.03,
                child: const Center(child: _FilterBar()),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ================================================================
// CENTER PREVIEW — tampilkan hasil render final bila ada,
// kalau belum siap bangun live dari foto + slot + frame.
// ================================================================
class _CenterPreview extends StatelessWidget {
  final PhotoProvider provider;
  const _CenterPreview({required this.provider});

  @override
  Widget build(BuildContext context) {
    final double frameW = provider.selectedFrameWidth;
    final double frameH = provider.selectedFrameHeight;

    Widget inner;
    final Uint8List? finalBytes = provider.finalImageBytes;
    if (finalBytes != null) {
      inner = Image.memory(finalBytes, fit: BoxFit.contain);
    } else if (provider.photos.isEmpty) {
      inner = const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white70),
            SizedBox(height: 12),
            Text('Menyiapkan hasil...',
                style: TextStyle(color: Colors.white70, fontSize: 13)),
          ],
        ),
      );
    } else {
      inner = FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: frameW,
          height: frameH,
          child: _FrameResult(provider: provider),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFDF6),
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [
          BoxShadow(
              color: Colors.black54, blurRadius: 24, offset: Offset(0, 12)),
        ],
      ),
      child: AspectRatio(
        aspectRatio: frameW / frameH,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: inner,
        ),
      ),
    );
  }
}

// Render frame + foto secara live (fallback bila finalImageBytes belum siap).
class _FrameResult extends StatelessWidget {
  final PhotoProvider provider;
  const _FrameResult({required this.provider});

  @override
  Widget build(BuildContext context) {
    final double w = provider.selectedFrameWidth;
    final double h = provider.selectedFrameHeight;

    return SizedBox(
      width: w,
      height: h,
      child: Stack(
        children: [
          Positioned.fill(child: Container(color: Colors.white)),
          if (provider.hasCustomSlots)
            ..._buildCustomSlots(w, h)
          else
            ..._buildFallbackSlots(w, h),
          if (provider.selectedFrameAsset != null)
            Positioned.fill(
              child: IgnorePointer(
                child: provider.selectedFrameAsset!.startsWith('http')
                    ? Image.network(provider.selectedFrameAsset!,
                        fit: BoxFit.fill,
                        errorBuilder: (_, __, ___) => const SizedBox())
                    : Image.asset(provider.selectedFrameAsset!,
                        fit: BoxFit.fill,
                        errorBuilder: (_, __, ___) => const SizedBox()),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildCustomSlots(double w, double h) {
    final photos = provider.photos;
    if (photos.isEmpty) return [];
    return provider.photoSlots.map((slot) {
      final int idx = slot.photoIndex.clamp(0, photos.length - 1);
      return Positioned(
        left: slot.x,
        top: slot.y,
        width: slot.width,
        height: slot.height,
        child: Transform.rotate(
          angle: slot.rotation * PreviewPage._deg2rad,
          child: ClipRect(
            child: Image.memory(
              photos[idx].imageData,
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

  List<Widget> _buildFallbackSlots(double w, double h) {
    final layout = provider.selectedLayout;
    final int count = provider.targetPhotoCount;
    final int cols = count == 3 ? 1 : 2;
    final int rows = (count / cols).ceil();

    final double lLeft = layout.leftPadding;
    final double lRight = layout.rightPadding;
    final double lTop = layout.topPadding;
    final double lBottom = layout.bottomPadding;
    final double lH = layout.horizontalSpacing;
    final double lV = layout.verticalSpacing;

    final double cellW = (w - lLeft - lRight - (cols - 1) * lH) / cols;
    final double cellH = (h - lTop - lBottom - (rows - 1) * lV) / rows;

    final List<Widget> out = [];
    for (int i = 0; i < provider.photos.length && i < count; i++) {
      final int col = i % cols;
      final int row = i ~/ cols;
      out.add(Positioned(
        left: lLeft + col * (cellW + lH),
        top: lTop + row * (cellH + lV),
        width: cellW,
        height: cellH,
        child: Image.memory(
          provider.photos[i].imageData,
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
        ),
      ));
    }
    return out;
  }
}

// ================================================================
// FILTER BAR — pemilihan filter (dipindah dari CameraPage).
// Saat filter dipilih: re-apply filter ke tiap foto dari bytes base
// (RAW, tanpa mirror ganda), lalu render ulang hasil final.
// ================================================================
class _FilterBar extends StatefulWidget {
  const _FilterBar();

  @override
  State<_FilterBar> createState() => _FilterBarState();
}

class _FilterBarState extends State<_FilterBar> {
  bool _busy = false;

  static const Map<PhotoFilter, String> _assets = {
    PhotoFilter.none: 'assets/filters/filter_none.png',
    PhotoFilter.vintage: 'assets/filters/filter_vintage.png',
    PhotoFilter.grayscale: 'assets/filters/filter_grayscale.png',
    PhotoFilter.smooth: 'assets/filters/filter_smooth.png',
    PhotoFilter.brightness: 'assets/filters/filter_brightness.png',
  };

  static const Map<PhotoFilter, String> _labels = {
    PhotoFilter.none: 'Asli',
    PhotoFilter.vintage: 'Vintage',
    PhotoFilter.grayscale: 'B/W',
    PhotoFilter.smooth: 'Halus',
    PhotoFilter.brightness: 'Cerah',
  };

  Future<void> _apply(PhotoFilter f) async {
    final provider = context.read<PhotoProvider>();
    if (_busy || provider.selectedFilter == f) return;

    setState(() => _busy = true);
    provider.setSelectedFilter(f);

    try {
      // Terapkan filter ke tiap foto dari bytes base SECARA PARALEL di isolate
      // (compute) agar UI tidak nge-freeze. mirror:false (base sudah ter-mirror).
      final futures = <Future<void>>[];
      for (int i = 0; i < provider.photos.length; i++) {
        final base = provider.photos[i].baseImageData;
        futures.add(compute(filterImageEntry, {
          'bytes': base,
          'filter': f.index,
          'mirror': false,
        }).then((res) => provider.updatePhotoImage(i, res)));
      }
      await Future.wait(futures);

      // Render ulang hasil final agar Foto/Cetak memakai versi terfilter.
      final png = await FrameComposer.compose(provider);
      provider.setFinalImageBytes(png); // preview langsung ter-update
    } catch (e) {
      debugPrint('Gagal terapkan filter: $e');
    }

    // Lepas spinner segera setelah preview siap — upload & video di background.
    if (mounted) setState(() => _busy = false);
    _uploadImageInBackground(provider);
    VideoResultService.ensure(provider); // recompose video dgn filter ini
    GifResultService.ensure(provider);   // GIF ikut filter yang sama
  }

  // Upload gambar hasil terfilter (tidak memblok UI pemilihan filter).
  Future<void> _uploadImageInBackground(PhotoProvider provider) async {
    try {
      final png = provider.finalImageBytes;
      if (png == null) return;
      if (provider.machineId.isEmpty) await provider.initMachineId();
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(
          '${tempDir.path}/result_filtered_${DateTime.now().millisecondsSinceEpoch}.png');
      await tempFile.writeAsBytes(png);
      final url = await ApiService().uploadFinalResult(
          provider.sessionUuid, tempFile.path,
          hwid: provider.machineId);
      if (url == null) {
        // Gagal — antre sebelum berkas sementaranya dihapus.
        await UploadQueueService.instance.enqueue(
          kind: UploadKind.finalStrip,
          sessionUuid: provider.sessionUuid,
          sourcePath: tempFile.path,
        );
      }
      try {
        await tempFile.delete();
      } catch (_) {}
    } catch (e) {
      debugPrint('Upload gambar terfilter gagal: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = context.watch<PhotoProvider>().selectedFilter;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF7A4636),
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
              color: Colors.black54, blurRadius: 12, offset: Offset(0, 5)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.only(right: 10, left: 2),
            child: Text(
              'Pilih\nFilter',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Quicksand',
                fontWeight: FontWeight.w700,
                color: Color(0xFFFCE9CE),
                fontSize: 12,
                height: 1.05,
              ),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: PhotoFilter.values.map((f) {
                  final sel = selected == f;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: GestureDetector(
                      onTap: _busy ? null : () => _apply(f),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFFD98C5F),
                              border: Border.all(
                                color: sel
                                    ? const Color(0xFFFFD84D)
                                    : Colors.white24,
                                width: sel ? 2.5 : 1.2,
                              ),
                              image: DecorationImage(
                                  image: AssetImage(_assets[f]!),
                                  fit: BoxFit.cover),
                              boxShadow: sel
                                  ? [
                                      BoxShadow(
                                        color: const Color(0xFFFFD84D)
                                            .withValues(alpha: 0.6),
                                        blurRadius: 6,
                                        spreadRadius: 1,
                                      )
                                    ]
                                  : const [],
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _labels[f]!,
                            style: TextStyle(
                              fontFamily: 'Quicksand',
                              fontWeight:
                                  sel ? FontWeight.w700 : FontWeight.w500,
                              color: sel
                                  ? const Color(0xFFFFD84D)
                                  : const Color(0xFFFCE9CE),
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(left: 10, right: 2),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Color(0xFFFFD84D)),
              ),
            ),
        ],
      ),
    );
  }
}

// ================================================================
// ICON BUTTON dengan animasi hover/press
// ================================================================
class _PreviewIconButton extends StatefulWidget {
  final String asset;
  final String label;
  final double size;
  final VoidCallback onTap;
  const _PreviewIconButton({
    required this.asset,
    required this.label,
    required this.size,
    required this.onTap,
  });

  @override
  State<_PreviewIconButton> createState() => _PreviewIconButtonState();
}

class _PreviewIconButtonState extends State<_PreviewIconButton> {
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
                      color: Colors.black.withValues(alpha: _hover ? 0.45 : 0.3),
                      blurRadius: _hover ? 20 : 10,
                      offset: Offset(0, _hover ? 10 : 6),
                    ),
                  ],
                ),
                child: Image.asset(
                  widget.asset,
                  width: widget.size,
                  height: widget.size,
                  fit: BoxFit.contain,
                ),
              ),
              SizedBox(height: widget.size * 0.09),
              Text(
                widget.label,
                style: TextStyle(
                  fontFamily: 'Quicksand',
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  fontSize: (widget.size * 0.21).clamp(16.0, 26.0),
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
