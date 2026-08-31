import 'package:photobooth_app/services/app_logger.dart';
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;

class HttpCameraService {
  final String _baseUrl = 'http://localhost:5513';

  // Folder sesuai settingan DigiCamControl
  final String _watchFolder = r'C:\PhotoboothData';

  Future<void> initialize() async {
    // Pastikan Live View nyala saat awal
    await startLiveView();
  }

  // --- FUNGSI BARU: Paksa Nyalakan Live View ---
  Future<void> startLiveView() async {
    try {
      AppLogger.debug('🔄 Sending LiveViewWnd_Show command...');
      await http.get(Uri.parse('$_baseUrl/?cmd=LiveViewWnd_Show'));
    } catch (e) {
      AppLogger.debug('❌ Failed to start Live View: $e');
    }
  }

  // Tambahkan timestamp agar cache tidak nyangkut
  String get liveViewUrl =>
      '$_baseUrl/liveview.jpg?t=${DateTime.now().millisecondsSinceEpoch}';

  Future<File?> takePicture() async {
    try {
      AppLogger.debug('📷 Sending HTTP Capture Command...');
      final captureStartTime = DateTime.now();

      final response = await http.get(Uri.parse('$_baseUrl/?cmd=Capture'));

      if (response.statusCode == 200) {
        AppLogger.debug('✅ Command Sent. Scanning folder $_watchFolder...');
        return await _waitForNewFile(captureStartTime);
      } else {
        throw Exception('Server returned ${response.statusCode}');
      }
    } catch (e) {
      AppLogger.debug('❌ HTTP Capture Error: $e');
      return null;
    }
  }

  Future<File?> _waitForNewFile(DateTime startTime) async {
    final rootDir = Directory(_watchFolder);
    if (!await rootDir.exists()) return null;

    int attempts = 0;
    while (attempts < 20) {
      try {
        final List<FileSystemEntity> allFiles = rootDir
            .listSync(recursive: true)
            .where((e) => e.path.toLowerCase().endsWith('.jpg'))
            .toList();

        if (allFiles.isNotEmpty) {
          allFiles.sort(
              (a, b) => b.statSync().modified.compareTo(a.statSync().modified));
          final latestFile = allFiles.first as File;
          final stat = await latestFile.stat();

          if (stat.modified
                  .isAfter(startTime.subtract(const Duration(seconds: 2))) &&
              stat.size > 0) {
            AppLogger.debug('✅ New Image Found: ${latestFile.path}');
            await Future.delayed(const Duration(milliseconds: 500));
            return latestFile;
          }
        }
      } catch (e) {
        AppLogger.debug('⚠️ Error scanning folder: $e');
      }

      await Future.delayed(const Duration(milliseconds: 500));
      attempts++;
    }
    AppLogger.debug('❌ Timeout: File not found.');
    return null;
  }
}
