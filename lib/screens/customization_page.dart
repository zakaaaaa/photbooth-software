import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:photobooth_app/providers/photo_provider.dart';
import 'package:photobooth_app/screens/preview_print_page.dart';

class CustomizationPage extends StatefulWidget {
  const CustomizationPage({super.key});

  @override
  State<CustomizationPage> createState() => _CustomizationPageState();
}

class _CustomizationPageState extends State<CustomizationPage> {
  int? _selectedStickerIndex;
  List<Uint8List>? _randomizedPhotos;

  final List<String> _textures = [
    'assets/textures/texture1.png',
    'assets/textures/texture2.png',
    'assets/textures/texture3.png',
    'assets/textures/texture4.png',
    'assets/textures/texture5.png',
    'assets/textures/texture6.png',
  ];

  final List<String> _stickers = [
    'assets/stickers/sticker1.png',
    'assets/stickers/sticker2.png',
    'assets/stickers/sticker3.png',
    'assets/stickers/sticker4.png',
    'assets/stickers/sticker5.png',
    'assets/stickers/sticker6.png',
    'assets/stickers/sticker7.png',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _prepareRandomizedPhotos();
    });
  }

  void _prepareRandomizedPhotos() {
    final provider = Provider.of<PhotoProvider>(context, listen: false);
    if (provider.selectedMode == FrameMode.static &&
        provider.targetPhotoCount == 3) {
      final originalPhotos = provider.photos.map((p) => p.imageData).toList();
      List<Uint8List> pool = [...originalPhotos, ...originalPhotos];
      pool.shuffle(math.Random());
      setState(() {
        _randomizedPhotos = pool;
      });
    }
  }

  void _showColorPicker(BuildContext context) {
    final provider = Provider.of<PhotoProvider>(context, listen: false);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pick Background Color'),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: provider.frameColor,
            onColorChanged: (color) => provider.setFrameColor(color),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: GestureDetector(
        onTap: () {
          if (_selectedStickerIndex != null) {
            setState(() {
              _selectedStickerIndex = null;
            });
          }
        },
        behavior: HitTestBehavior.translucent,
        child: Container(
          decoration: const BoxDecoration(
            image: DecorationImage(
              image: AssetImage('assets/images/bg.png'),
              fit: BoxFit.cover,
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                // HEADER
                const Padding(
                  padding: EdgeInsets.only(top: 20.0, bottom: 20.0),
                  child: OutlinedText(
                    text: "CUSTOMIZE\nYOUR FRAME",
                    fontFamily: 'Ambitsek',
                    fontSize: 40,
                    textColor: Color(0xFFFFED00),
                    outlineColor: Color(0xFFEF7D30),
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2.0,
                    hasShadow: true,
                  ),
                ),

                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // PANEL KIRI: PREVIEW (Canvas)
                      Expanded(flex: 2, child: _buildPreviewPanel()),

                      // PANEL KANAN: TOOLS
                      Expanded(flex: 2, child: _buildCustomizationPanel()),
                    ],
                  ),
                ),

                // FOOTER BUTTON (NEXT)
                _buildFooterButtons(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ==========================================
  // PANEL 1: PREVIEW (CANVAS) - [REVISI SIZE]
  // ==========================================
  Widget _buildPreviewPanel() {
    return Consumer<PhotoProvider>(
      builder: (context, provider, _) {
        double currentFrameWidth;
        // [REVISI] Tinggi dibuat konsisten 515.0 untuk semua mode
        const double currentFrameHeight = 515.0;

        if (provider.selectedMode == FrameMode.custom) {
          if (provider.customLayout == CustomLayout.vertical) {
            currentFrameWidth = 230.0;
          } else {
            currentFrameWidth = 400.0;
          }
        } else {
          // Static Mode (Lebar disamakan dengan PreviewPrintPage)
          currentFrameWidth = 344.0;
        }

        return Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 20),
            width: currentFrameWidth,
            height: currentFrameHeight,
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5), blurRadius: 20)
              ],
            ),
            child: Stack(
              fit: StackFit.expand,
              alignment: Alignment.center,
              children: [
                _buildPhotoLayout(provider),
                if (provider.selectedMode == FrameMode.static &&
                    provider.selectedFrameAsset != null)
                  IgnorePointer(
                    child: Image.asset(
                      provider.selectedFrameAsset!,
                      fit: BoxFit.contain,
                      width: currentFrameWidth,
                      height: currentFrameHeight,
                    ),
                  ),
                ...provider.stickers.asMap().entries.map((entry) {
                  final index = entry.key;
                  final sticker = entry.value;
                  return Positioned(
                    left: 0,
                    top: 0,
                    child: _buildEditableSticker(
                      sticker,
                      index,
                      _selectedStickerIndex == index,
                      provider,
                      frameWidth: currentFrameWidth,
                      frameHeight: currentFrameHeight,
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  // ==========================================
  // LOGIKA LAYOUT MANAGER
  // ==========================================
  Widget _buildPhotoLayout(PhotoProvider provider) {
    if (provider.selectedMode == FrameMode.custom) {
      return Container(
        decoration: BoxDecoration(
          color: provider.frameColor,
          image: provider.frameTexture != null
              ? DecorationImage(
                  image: AssetImage(provider.frameTexture!), fit: BoxFit.cover)
              : null,
        ),
        child: provider.customLayout == CustomLayout.vertical
            ? _buildCustomVerticalLayout(provider)
            : _buildCustomGridLayout(provider),
      );
    } else {
      final layout = provider.selectedLayout;
      return Container(
        color: Colors.white,
        padding: EdgeInsets.fromLTRB(layout.leftPadding, layout.topPadding,
            layout.rightPadding, layout.bottomPadding),
        child: GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: layout.horizontalSpacing,
            mainAxisSpacing: layout.verticalSpacing,
            childAspectRatio: layout.childAspectRatio,
          ),
          itemCount: provider.targetPhotoCount == 3 ? 6 : 4,
          itemBuilder: (context, index) {
            final photosToShow = (provider.targetPhotoCount == 3)
                ? (_randomizedPhotos ?? [])
                : provider.photos.map((e) => e.imageData).toList();
            if (index >= photosToShow.length) return Container();
            return Image.memory(photosToShow[index], fit: BoxFit.cover);
          },
        ),
      );
    }
  }

  Widget _buildCustomVerticalLayout(PhotoProvider provider) {
    const double photoWidth = 170.0;
    const double photoHeight = 100.0;
    const double spacing = 10.8;
    const double radius = 20.0;
    const double border = 0.0;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: provider.photos.map((photo) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: spacing / 2),
            child: _buildSinglePhoto(
              bytes: photo.imageData,
              w: photoWidth,
              h: photoHeight,
              radius: radius,
              border: border,
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildCustomGridLayout(PhotoProvider provider) {
    const double gridPhotoWidth = 180.0;
    const double gridPhotoHeight = 160.0;
    const double gridSpacing = 10.0;
    const double gridRadius = 20.0;
    const double gridBorder = 2.0;

    return Center(
      child: Wrap(
        spacing: gridSpacing,
        runSpacing: gridSpacing,
        alignment: WrapAlignment.center,
        children: provider.photos.map((photo) {
          return _buildSinglePhoto(
            bytes: photo.imageData,
            w: gridPhotoWidth,
            h: gridPhotoHeight,
            radius: gridRadius,
            border: gridBorder,
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSinglePhoto(
      {required Uint8List bytes,
      required double w,
      required double h,
      required double radius,
      required double border}) {
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white, width: border),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))
        ],
      ),
      child: ClipRRect(
        borderRadius:
            BorderRadius.circular(radius - border > 0 ? radius - border : 0),
        child: Image.memory(bytes, fit: BoxFit.cover),
      ),
    );
  }

  // ==========================================
  // PANEL 2: TOOLS (MENU KANAN - STYLE WINDOWS 95)
  // ==========================================
  Widget _buildCustomizationPanel() {
    return Consumer<PhotoProvider>(
      builder: (context, provider, _) {
        return Container(
          margin: const EdgeInsets.only(top: 10, bottom: 40, right: 40),
          decoration: BoxDecoration(
            color: const Color(0xFFC0C0C0),
            border: Border.all(width: 4, color: Colors.black),
            boxShadow: const [
              BoxShadow(
                  color: Colors.black54, offset: Offset(8, 8), blurRadius: 0)
            ],
          ),
          child: Column(
            children: [
              // HEADER BIRU
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(vertical: 8, horizontal: 15),
                color: const Color(0xFF0000AA),
                child: Text(
                  provider.selectedMode == FrameMode.static
                      ? 'STICKER PACK'
                      : 'CUSTOM TOOLS',
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 1.0,
                  ),
                ),
              ),

              // ISI KONTEN
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (provider.selectedMode == FrameMode.custom) ...[
                        const Text("Choose Layout:",
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontFamily: 'Poppins')),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            _buildLayoutOption(provider, CustomLayout.vertical,
                                Icons.view_agenda, "Strip"),
                            const SizedBox(width: 15),
                            _buildLayoutOption(provider, CustomLayout.grid,
                                Icons.grid_view, "Grid"),
                          ],
                        ),
                        const SizedBox(height: 20),
                        const Divider(color: Colors.black54, thickness: 2),
                        const SizedBox(height: 10),
                        _buildFrameColorSection(),
                        const SizedBox(height: 20),
                        const Divider(color: Colors.black54, thickness: 2),
                        const SizedBox(height: 10),
                      ],
                      _buildStickersSection(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLayoutOption(PhotoProvider provider, CustomLayout layout,
      IconData icon, String label) {
    final isSelected = provider.customLayout == layout;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          if (provider.customLayout != layout) {
            provider.setCustomLayout(layout);
            while (provider.stickers.isNotEmpty) {
              provider.removeSticker(0);
            }
            setState(() {
              _selectedStickerIndex = null;
            });
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? Colors.blue[800] : Colors.white,
            border: Border.all(width: 2, color: Colors.black),
            boxShadow: isSelected
                ? []
                : const [
                    BoxShadow(color: Colors.black54, offset: Offset(2, 2))
                  ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  color: isSelected ? Colors.white : Colors.black, size: 20),
              const SizedBox(width: 8),
              Text(label,
                  style: TextStyle(
                      color: isSelected ? Colors.white : Colors.black,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'Poppins')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFrameColorSection() {
    return Consumer<PhotoProvider>(
      builder: (context, provider, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Background Style',
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontFamily: 'Poppins')),
            const SizedBox(height: 10),
            Row(
              children: [
                GestureDetector(
                  onTap: () => _showColorPicker(context),
                  child: Container(
                    width: 50, height: 50,
                    decoration: BoxDecoration(
                      color: provider.frameColor,
                      border: Border.all(color: Colors.black, width: 2),
                      boxShadow: const [
                        BoxShadow(color: Colors.black54, offset: Offset(2, 2))
                      ],
                    ),
                    // [REVISI ICON] Color Wheel Icon
                    child: const Icon(Icons.color_lens,
                        color: Colors.white, size: 30),
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: SizedBox(
                    height: 50,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: _textures.length,
                      itemBuilder: (context, index) {
                        return GestureDetector(
                          onTap: () =>
                              provider.setFrameTexture(_textures[index]),
                          child: Container(
                            width: 50,
                            margin: const EdgeInsets.only(right: 10),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.black, width: 2),
                              image: DecorationImage(
                                  image: AssetImage(_textures[index]),
                                  fit: BoxFit.cover),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildStickersSection() {
    return Consumer<PhotoProvider>(
      builder: (context, provider, _) {
        List<String> displayedStickers;
        if (provider.selectedMode == FrameMode.custom) {
          if (provider.customLayout == CustomLayout.vertical) {
            displayedStickers = _stickers.sublist(0, 4);
          } else {
            displayedStickers = _stickers.sublist(4);
          }
        } else {
          displayedStickers = _stickers;
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Add Sticker Package',
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontFamily: 'Poppins')),
            const SizedBox(height: 10),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              itemCount: displayedStickers.length,
              itemBuilder: (context, index) {
                return GestureDetector(
                  onTap: () => provider.addSticker(displayedStickers[index]),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(width: 2, color: Colors.black),
                      boxShadow: const [
                        BoxShadow(color: Colors.black26, offset: Offset(2, 2))
                      ],
                    ),
                    padding: const EdgeInsets.all(5),
                    child: Image.asset(displayedStickers[index]),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }

  Widget _buildEditableSticker(
      StickerData sticker, int index, bool isSelected, PhotoProvider provider,
      {required double frameWidth, required double? frameHeight}) {
    return GestureDetector(
      onTap: () => setState(() => _selectedStickerIndex = index),
      child: Stack(
        children: [
          Transform.rotate(
            angle: sticker.rotation,
            child: Container(
              alignment: Alignment.topLeft,
              child: Image.asset(
                sticker.assetPath,
                width: frameWidth,
                height: frameHeight,
                fit: BoxFit.contain,
              ),
            ),
          ),
          if (isSelected)
            Positioned(
              right: 10,
              top: 10,
              child: GestureDetector(
                onTap: () {
                  provider.removeSticker(index);
                  setState(() => _selectedStickerIndex = null);
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                    border: Border.all(width: 2, color: Colors.white),
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 4)
                    ],
                  ),
                  child: const Icon(Icons.close, color: Colors.white, size: 24),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFooterButtons() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20.0),
      child: NextImageButton(
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const PreviewPrintPage()),
          );
        },
      ),
    );
  }
}

// WIDGET HELPER: OUTLINED TEXT
class OutlinedText extends StatelessWidget {
  final String text;
  final String fontFamily;
  final double fontSize;
  final Color textColor;
  final Color outlineColor;
  final FontWeight fontWeight;
  final double letterSpacing;
  final bool hasShadow;

  const OutlinedText(
      {super.key,
      required this.text,
      required this.fontFamily,
      required this.fontSize,
      required this.textColor,
      required this.outlineColor,
      this.fontWeight = FontWeight.normal,
      this.letterSpacing = 0.0,
      this.hasShadow = false});

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

// WIDGET HELPER: NEXT IMAGE BUTTON
class NextImageButton extends StatefulWidget {
  final VoidCallback onPressed;
  const NextImageButton({super.key, required this.onPressed});

  @override
  State<NextImageButton> createState() => _NextImageButtonState();
}

class _NextImageButtonState extends State<NextImageButton> {
  bool _isHovered = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) {
          setState(() => _isPressed = false);
          widget.onPressed();
        },
        onTapCancel: () => setState(() => _isPressed = false),
        child: AnimatedScale(
          scale: _isPressed ? 0.9 : (_isHovered ? 1.05 : 1.0),
          duration: const Duration(milliseconds: 100),
          child: Image.asset(
            "assets/images/next.png",
            width: 180,
            height: 96,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}
