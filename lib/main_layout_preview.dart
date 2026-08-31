// ===========================================================================
// ENTRY KHUSUS PENGEMBANGAN — bukan bagian dari aplikasi produksi.
//
// Merender CameraPage seolah-olah berjalan di monitor customer 1920x1080,
// lalu men-skala hasilnya agar muat di layar laptop yang lebih kecil.
// Tata letaknya IDENTIK dengan monitor sungguhan (font, gambar, proporsi);
// hanya ukuran tampilnya yang dikecilkan.
//
// Gunanya: menyetel tata letak tanpa monitor 15,6" itu tercolok — hasilnya
// tinggal di-screenshot lewat tools/screenshot.ps1 dan dilihat dari mana pun.
//
// Jalankan:
//   flutter run -d windows -t lib/main_layout_preview.dart
//
// Ukuran target bisa diganti tanpa mengubah kode:
//   --dart-define=PREVIEW_W=1366 --dart-define=PREVIEW_H=768
// ===========================================================================

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'providers/photo_provider.dart';
import 'screens/camera_page.dart';
import 'screens/static_frame_template_page.dart' show FrameTemplate;
import 'services/config_service.dart';

// Dart hanya punya int/bool/String.fromEnvironment — jadi ambil sebagai int.
const int _pw = int.fromEnvironment('PREVIEW_W', defaultValue: 1920);
const int _ph = int.fromEnvironment('PREVIEW_H', defaultValue: 1080);
const double kPreviewW = _pw + 0.0;
const double kPreviewH = _ph + 0.0;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  // Samakan rasio jendela dengan target supaya screenshot-nya bersih tanpa
  // bilah hitam, dan skalanya tepat (1440/1920 = 0,75).
  const winW = 1440.0;
  const winH = winW * (kPreviewH / kPreviewW);

  windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: const Size(winW, winH),
      center: true,
      title: 'Layout Preview ${kPreviewW.toInt()}x${kPreviewH.toInt()}',
      titleBarStyle: TitleBarStyle.normal,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );

  runApp(const LayoutPreviewApp());
}

class LayoutPreviewApp extends StatelessWidget {
  const LayoutPreviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Layout Preview',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
        fontFamily: 'Poppins', // samakan dengan main.dart
      ),
      home: const _PreviewStage(),
    );
  }
}

// Frame ke berapa dari daftar backend yang dipakai.
//   --dart-define=PREVIEW_FRAME_INDEX=2
const int kFrameIndex = int.fromEnvironment('PREVIEW_FRAME_INDEX');

// Ambil frame SUNGGUHAN dari backend, memakai endpoint & parser yang sama
// dengan StaticFrameTemplatePage. Tanpa ini slot foto tampil polos tanpa
// artwork, sehingga tata letaknya tidak bisa dinilai dengan jujur.
Future<PhotoProvider> _loadProviderWithFrame() async {
  final p = PhotoProvider();
  try {
    // baseUrl default-nya localhost sampai init() dipanggil.
    await ConfigService().init();
    await p.initMachineId();

    final uri = Uri.parse('${ConfigService().baseUrl}/api/frames'
        '?hwid=${Uri.encodeComponent(p.machineId)}');
    final res = await http.get(uri).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      debugPrint('[preview] /frames HTTP ${res.statusCode}');
      return p;
    }

    final data = jsonDecode(res.body);
    final List<dynamic> raw = (data['frames'] as List<dynamic>?) ?? [];
    if (raw.isEmpty) {
      debugPrint('[preview] backend tidak mengembalikan frame apa pun.');
      return p;
    }

    final idx = kFrameIndex.clamp(0, raw.length - 1);
    final t = FrameTemplate.fromJson(raw[idx] as Map<String, dynamic>);
    if (t.hasCustomSlots) {
      p.setFrameModeWithSlots(
        FrameMode.static,
        photoCount: t.photoCount,
        frameAsset: t.imageUrl,
        photoSlots: t.photoSlots,
        customWidth: t.outputWidth,
        customHeight: t.outputHeight,
      );
    } else {
      p.setFrameMode(
        FrameMode.static,
        photoCount: t.photoCount,
        frameAsset: t.imageUrl,
        layout: t.layout,
        customWidth: t.outputWidth,
        customHeight: t.outputHeight,
      );
    }
    debugPrint('[preview] frame [$idx/${raw.length}] "${t.name}" '
        '${t.outputWidth.toInt()}x${t.outputHeight.toInt()} '
        '${t.photoSlots.length} slot — ${t.imageUrl}');
  } catch (e) {
    debugPrint('[preview] gagal mengambil frame: $e');
  }
  return p;
}

class _PreviewStage extends StatefulWidget {
  const _PreviewStage();

  @override
  State<_PreviewStage> createState() => _PreviewStageState();
}

class _PreviewStageState extends State<_PreviewStage> {
  late final Future<PhotoProvider> _future = _loadProviderWithFrame();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<PhotoProvider>(
        future: _future,
        builder: (_, snap) {
          if (!snap.hasData) {
            return const Center(
              child: Text('memuat frame dari backend…',
                  style: TextStyle(color: Colors.white54)),
            );
          }
          return Center(
            child: FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: kPreviewW,
                height: kPreviewH,
                // MediaQuery di-override supaya SEMUA perhitungan berbasis
                // ukuran layar di dalam CameraPage (mis. screenH * 0.55)
                // memakai angka monitor customer, bukan layar laptop.
                child: MediaQuery(
                  data: const MediaQueryData(
                    size: Size(kPreviewW, kPreviewH),
                    devicePixelRatio: 1,
                  ),
                  child: ChangeNotifierProvider<PhotoProvider>.value(
                    value: snap.data!,
                    child: const CameraPage(layoutPreview: true),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
