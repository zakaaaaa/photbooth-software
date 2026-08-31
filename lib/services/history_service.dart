import 'package:photobooth_app/services/app_logger.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class LocalStrip {
  final String path;
  final String fileName;
  final DateTime timestamp;
  final String sessionUuid;

  LocalStrip({
    required this.path,
    required this.fileName,
    required this.timestamp,
    required this.sessionUuid,
  });

  Uint8List get bytes => File(path).readAsBytesSync();
}

class HistoryService {
  static final HistoryService _instance = HistoryService._internal();
  factory HistoryService() => _instance;
  HistoryService._internal();

  Future<String> get _historyPath async {
    final docs = await getApplicationDocumentsDirectory();
    final path = p.join(docs.path, 'Photobooth', 'History');
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return path;
  }

  /// Memperoleh semua strip yang tersimpan secara lokal
  Future<List<LocalStrip>> getLocalHistory() async {
    try {
      final path = await _historyPath;
      final dir = Directory(path);
      final List<FileSystemEntity> files = await dir.list().toList();

      final List<LocalStrip> strips = [];
      for (var file in files) {
        if (file is File && file.path.endsWith('.png')) {
          final fileName = p.basename(file.path);
          // Format: sessionUuid_yyyyMMdd_HHmmss.png
          final parts = fileName.replaceAll('.png', '').split('_');

          DateTime ts;
          String uuid;

          if (parts.length >= 3) {
            uuid = parts[0];
            try {
              ts = DateFormat('yyyyMMddHHmmss').parse('${parts[1]}${parts[2]}');
            } catch (_) {
              ts = await file.lastModified();
            }
          } else {
            uuid = 'unknown';
            ts = await file.lastModified();
          }

          strips.add(LocalStrip(
            path: file.path,
            fileName: fileName,
            timestamp: ts,
            sessionUuid: uuid,
          ));
        }
      }

      // Sort: terbaru di atas
      strips.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return strips;
    } catch (e) {
      AppLogger.debug("❌ Error reading local history: $e");
      return [];
    }
  }

  /// Menyimpan strip final ke folder history
  Future<String?> saveToHistory(String sessionUuid, Uint8List bytes) async {
    try {
      final path = await _historyPath;
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final fileName = '${sessionUuid}_$timestamp.png';
      final fullPath = p.join(path, fileName);

      final file = File(fullPath);
      await file.writeAsBytes(bytes);

      AppLogger.debug("💾 Strip saved to local history: $fullPath");
      return fullPath;
    } catch (e) {
      AppLogger.debug("❌ Error saving to history: $e");
      return null;
    }
  }
}
