import 'package:flutter/material.dart';
import 'static_frame_template_page.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Menggunakan Stack agar background bisa fullscreen
    return Scaffold(
      body: Stack(
        fit: StackFit.expand, // Memaksa child memenuhi layar
        children: [
          // 1. BACKGROUND IMAGE (Asset kamu)
          Image.asset(
            'assets/images/splash_background.png', // Menggunakan background yang sudah kamu upload
            fit: BoxFit.cover,
          ),

          // 2. OVERLAY GELAP (Supaya teks terbaca jelas)
          Container(
            color: Colors.black.withValues(alpha: 0.3),
          ),

          // 3. KONTEN TENGAH
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Judul / Logo (Bisa diganti Image.asset logo kamu)
                const Text(
                  "PHOTOBOOTH",
                  style: TextStyle(
                    fontFamily: 'Poppins', // Asumsi kamu pakai font ini
                    fontSize: 60,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 5,
                    shadows: [
                      Shadow(
                        blurRadius: 10.0,
                        color: Colors.black,
                        offset: Offset(2.0, 2.0),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 10),

                const Text(
                  "Abadikan Momen Serumu Disini!",
                  style: TextStyle(
                    fontSize: 20,
                    color: Colors.white70,
                    letterSpacing: 1.5,
                  ),
                ),

                const SizedBox(height: 60),

                // TOMBOL MULAI (Animasi Pulse dikit biar menarik - Opsional)
                ElevatedButton(
                  onPressed: () {
                    // Navigasi ke Halaman Pemilihan Frame
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const StaticFrameTemplatePage(),
                      ),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 50, vertical: 20),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                    elevation: 10,
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.camera_alt, size: 30),
                      SizedBox(width: 15),
                      Text(
                        "MULAI FOTO",
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 4. FOOTER (Opsional - Copyright / Info)
          const Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: Text(
              "Touch Screen to Start • Zaka Enterprise",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white54,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
