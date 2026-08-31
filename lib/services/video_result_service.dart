import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import '../providers/photo_provider.dart';
import '../utils/video_composer.dart';
import 'api_service.dart';
import 'config_service.dart';
import 'upload_queue_service.dart';

// ================================================================
// VIDEO RESULT SERVICE
// Orkestrasi komposit video hasil: hanya compose bila perlu (belum ada
// atau filter berubah), cegah dobel via flag, lalu upload ke server.
// Dipakai oleh CameraPage, PreviewPage (saat ganti filter), dan VideoResultPage.
// ================================================================
class VideoResultService {
  static final String _backendUrl = ConfigService().baseUrl;

  /// Pastikan finalVideoPath sesuai filter terkini. Aman dipanggil berkali-kali.
  static Future<void> ensure(PhotoProvider provider, {bool upload = true}) async {
    if (!provider.hasAllVideoClips) return;
    if (provider.videoProcessing) return;
    // Sudah sesuai filter terkini → tidak perlu compose ulang.
    if (provider.finalVideoPath != null &&
        provider.finalVideoFilter == provider.selectedFilter) {
      return;
    }

    provider.setVideoProcessing(true);
    var reachedUpload = false;
    try {
      await _reportStatus(provider, 'processing');
      final filter = provider.selectedFilter;
      final path = await VideoComposer.compose(provider);
      if (path != null) {
        provider.setFinalVideo(path, filter);
        if (upload) {
          reachedUpload = true;
          await _upload(provider, path);
        }
      }
    } catch (e) {
      debugPrint('[VIDEO] ensure error: $e');
    } finally {
      provider.setVideoProcessing(false);
      // Upload sukses sudah ditandai 'ready' oleh server; kalau compose gagal
      // sebelum sampai upload, jangan biarkan status menggantung.
      if (!reachedUpload) await _reportStatus(provider, 'failed');
    }

    // Bila filter berubah saat compose berjalan, ulangi sekali untuk yang terbaru.
    if (provider.hasAllVideoClips &&
        provider.finalVideoFilter != provider.selectedFilter) {
      await ensure(provider, upload: upload);
    }
  }

  static Future<void> _reportStatus(PhotoProvider provider, String status) async {
    try {
      if (provider.sessionUuid.isEmpty) return;
      if (provider.machineId.isEmpty) await provider.initMachineId();
      if (provider.machineId.isEmpty) return;
      await ApiService().setMediaStatus(
        sessionUuid: provider.sessionUuid,
        hwid: provider.machineId,
        videoStatus: status,
      );
    } catch (_) {
      // Transparansi UI tidak boleh menggagalkan komposit video.
    }
  }

  static Future<void> _upload(PhotoProvider provider, String path) async {
    try {
      if (provider.sessionUuid.isEmpty) return;
      if (provider.machineId.isEmpty) await provider.initMachineId();
      final hwid = provider.machineId;
      if (hwid.isEmpty) return;

      final uri = Uri.parse('$_backendUrl/api/photobooth/upload/video');
      final request = http.MultipartRequest('POST', uri)
        ..fields['session_uuid'] = provider.sessionUuid
        ..fields['hwid'] = hwid
        ..files.add(await http.MultipartFile.fromPath('video', path,
            contentType: MediaType('video', 'mp4')));

      final streamed = await request.send();
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode == 200 || response.statusCode == 201) {
        debugPrint('[VIDEO] Upload video berhasil.');
      } else {
        debugPrint('[VIDEO] Upload video gagal: ${response.statusCode}');
        await _queueRetry(provider, path);
      }
    } catch (e) {
      debugPrint('[VIDEO] Upload video error: $e');
      await _queueRetry(provider, path);
    }
  }

  /// Statusnya sengaja dibiarkan 'processing', bukan langsung 'failed':
  /// selama masih ada di antrean, hasilnya masih mungkin sampai. Antrean
  /// sendiri yang menandai 'failed' kalau akhirnya menyerah.
  static Future<void> _queueRetry(PhotoProvider provider, String path) async {
    await UploadQueueService.instance.enqueue(
      kind: UploadKind.video,
      sessionUuid: provider.sessionUuid,
      sourcePath: path,
    );
  }
}
