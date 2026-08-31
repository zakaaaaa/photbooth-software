import 'package:flutter/material.dart';

// Keyboard voucher bergaya konsisten: rounded, warm, font Quicksand.
class RetroKeyboard extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback? onKeyTapped;

  const RetroKeyboard({
    super.key,
    required this.controller,
    this.onKeyTapped,
  });

  static const Color _panel = Color(0xFF7A4636);
  static const Color _key = Color(0xFFFFF6E6);
  static const Color _keyPressed = Color(0xFFFFE3A6);
  static const Color _keyText = Color(0xFF5A3A2A);

  @override
  Widget build(BuildContext context) {
    final List<List<String>> rows = [
      ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
      ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'],
      ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L'],
      ['Z', 'X', 'C', 'V', 'B', 'N', 'M'],
    ];

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(color: Colors.black38, blurRadius: 10, offset: Offset(0, 5)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...rows.map((row) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: row
                      .map((k) => _Key(
                            label: k,
                            onTap: () => _handleKeyTap(k),
                          ))
                      .toList(),
                ),
              )),
          const SizedBox(height: 4),
          // Baris terakhir: tombol HAPUS (teks, bukan icon)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: _Key(
              label: 'HAPUS',
              width: 210,
              onTap: _handleBackspace,
            ),
          ),
        ],
      ),
    );
  }

  void _handleKeyTap(String key) {
    controller.text = controller.text + key;
    onKeyTapped?.call();
  }

  void _handleBackspace() {
    if (controller.text.isNotEmpty) {
      controller.text =
          controller.text.substring(0, controller.text.length - 1);
      onKeyTapped?.call();
    }
  }
}

class _Key extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final double width;

  const _Key({
    required this.label,
    required this.onTap,
    this.width = 46,
  });

  @override
  State<_Key> createState() => _KeyState();
}

class _KeyState extends State<_Key> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final bool isWide = widget.label.length > 1;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.92 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: Container(
            width: widget.width,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _pressed
                  ? RetroKeyboard._keyPressed
                  : RetroKeyboard._key,
              borderRadius: BorderRadius.circular(12),
              boxShadow: _pressed
                  ? []
                  : const [
                      BoxShadow(
                          color: Colors.black26,
                          blurRadius: 3,
                          offset: Offset(0, 2)),
                    ],
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                fontFamily: 'Quicksand',
                fontWeight: FontWeight.w700,
                fontSize: isWide ? 16 : 20,
                color: RetroKeyboard._keyText,
                letterSpacing: isWide ? 1.0 : 0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
