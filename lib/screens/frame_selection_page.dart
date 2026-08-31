import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/photo_provider.dart';
import 'camera_page.dart';
import 'static_frame_template_page.dart';

class FrameSelectionPage extends StatelessWidget {
  const FrameSelectionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 1. BACKGROUND IMAGE
          Positioned.fill(
            child: Image.asset(
              "assets/images/bg.png",
              fit: BoxFit.cover,
            ),
          ),

          // 2. KONTEN UTAMA
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // HEADLINE
                const OutlinedText(
                  text: "CHOOSE\nCATEGORY TEMPLATE",
                  fontFamily: 'Ambitsek',
                  fontSize: 65,
                  textColor: Color(0xFFFFED00),
                  outlineColor: Color(0xFFEF7D30),
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.0,
                  hasShadow: true,
                ),

                const SizedBox(height: 60),

                // --- TOMBOL 1: STATIC FRAME ---
                ImageButton(
                  text: "Static Frame",
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (context) =>
                              const StaticFrameTemplatePage()),
                    );
                  },
                ),

                const SizedBox(height: 30),

                // --- TOMBOL 2: DIY FRAME ---
                ImageButton(
                  text: "DIY Frame",
                  onTap: () {
                    Provider.of<PhotoProvider>(context, listen: false)
                        .setFrameMode(
                      FrameMode.custom,
                      photoCount: 3,
                    );
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (context) => const CameraPage()),
                    );
                  },
                ),

                const SizedBox(height: 60),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =========================================================
// WIDGET: IMAGE BUTTON
// =========================================================
class ImageButton extends StatefulWidget {
  final String text;
  final VoidCallback onTap;

  const ImageButton({
    super.key,
    required this.text,
    required this.onTap,
  });

  @override
  State<ImageButton> createState() => _ImageButtonState();
}

class _ImageButtonState extends State<ImageButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _isPressed = false),
      child: Transform.scale(
        scale: _isPressed ? 0.95 : 1.0,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Image.asset(
              "assets/images/btn.png",
              width: 320,
              height: 90,
              fit: BoxFit.contain,
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Text(
                widget.text,
                style: const TextStyle(
                  fontFamily: 'ambitsek',
                  fontSize: 25,
                  color: Color.fromARGB(255, 255, 255, 255),
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =========================================================
// WIDGET: OUTLINED TEXT
// =========================================================
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
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: fontFamily,
                fontSize: fontSize,
                fontWeight: fontWeight,
                letterSpacing: letterSpacing,
                height: 1.2,
                color: Colors.black.withValues(alpha: 0.6),
              ),
            ),
          ),
        Text(
          text,
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
              ..color = outlineColor,
          ),
        ),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: fontSize,
            fontWeight: fontWeight,
            letterSpacing: letterSpacing,
            height: 1.2,
            color: textColor,
          ),
        ),
      ],
    );
  }
}
