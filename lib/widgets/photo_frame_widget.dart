// photo_frame_widget.dart
import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'package:photobooth_app/providers/photo_provider.dart';

class PhotoFrameWidget extends StatelessWidget {
  final Uint8List imageData;
  final Color frameColor;
  final String? frameTexture;
  final FrameShape frameShape;
  final double? width;   // 🔹 Tambahkan parameter width
  final double? height; // 🔹 Tambahkan parameter height

  const PhotoFrameWidget({
    super.key,
    required this.imageData,
    required this.frameColor,
    required this.frameTexture,
    required this.frameShape,
    this.width,          // 👈 opsional
    this.height,         // 👈 opsional
  });

  @override
  Widget build(BuildContext context) {
    Widget photoWidget = Image.memory(
      imageData,
      fit: BoxFit.cover,
      width: width,   // ✅ Gunakan width dari parameter
      height: height, // ✅ Gunakan height dari parameter
    );

    if (frameShape == FrameShape.circle) {
      photoWidget = ClipOval(child: photoWidget);
    } else if (frameShape == FrameShape.love) {
      photoWidget = ClipPath(clipper: LoveShapeClipper(), child: photoWidget);
    } else {
      photoWidget = ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: photoWidget,
      );
    }

    return Container(
      width: width,   // 👈 gunakan parameter width
      height: height, // 👈 gunakan parameter height
      decoration: BoxDecoration(
        color: frameTexture == null ? frameColor : null,
        image: frameTexture != null
            ? DecorationImage(
                image: AssetImage(frameTexture!),
                fit: BoxFit.cover,
              )
            : null,
        borderRadius: BorderRadius.circular(15),
      ),
      child: photoWidget,
    );
  }
}

class LoveShapeClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path();
    final r = size.width / 4;
    path.moveTo(size.width / 2, size.height / 3);
    path.cubicTo(
      size.width / 2 + r, size.height / 3 - r,
      size.width - r, size.height / 3,
      size.width - r, size.height / 2,
    );
    path.cubicTo(
      size.width - r, size.height - r,
      size.width / 2, size.height,
      size.width / 2, size.height - r,
    );
    path.cubicTo(
      size.width / 2, size.height,
      r, size.height - r,
      r, size.height / 2,
    );
    path.cubicTo(
      r, size.height / 3,
      size.width / 2 - r, size.height / 3 - r,
      size.width / 2, size.height / 3,
    );
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}