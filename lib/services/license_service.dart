import 'package:photobooth_app/services/app_logger.dart';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:device_info_plus/device_info_plus.dart';
import 'config_service.dart';

class LicenseService {
  // URL Endpoint (Dinamis: Local vs Remote)
  String get _baseUrl =>
      '${ConfigService().baseUrl}/api/photobooth/license/check';

  Future<Map<String, dynamic>> checkLicense() async {
    // PERUBAHAN 1: Panggil fungsi public (tanpa garis bawah)
    String hwid = await getHardwareId();

    // Debugging: Print HWID biar gampang dicopy ke Database nanti
    AppLogger.debug("DEBUG: HWID DETECTED -> $hwid");

    try {
      final response = await http
          .post(
            Uri.parse(_baseUrl),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'hwid': hwid,
            }),
          )
          .timeout(const Duration(seconds: 10)); // Timeout 10 detik

      AppLogger.debug("DEBUG: API RESPONSE -> ${response.body}");

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return {
          'success': true,
          'message': data['message'],
          'data': data['data']
        };
      } else {
        // Handle Error 403 (License Expired/Invalid)
        final error = jsonDecode(response.body);
        return {
          'success': false,
          'message': error['message'] ?? 'Lisensi Tidak Valid'
        };
      }
    } catch (e) {
      AppLogger.debug("ERROR KONEKSI: $e");
      return {
        'success': false,
        'message': 'Gagal terhubung ke server. Cek internet.'
      };
    }
  }

  // =================================================================
  // PERBAIKAN UTAMA: UBAH JADI PUBLIC (Hapus garis bawah '_')
  // =================================================================
  // Fungsi Sakti untuk ambil ID Unik
  // Agar bisa dipanggil dari PhotoProvider, fungsi ini harus PUBLIC
  Future<String> getHardwareId() async {
    DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();

    if (Platform.isWindows) {
      WindowsDeviceInfo windowsInfo = await deviceInfo.windowsInfo;
      // deviceId di Windows sangat unik dan permanen
      return windowsInfo.deviceId;
    } else if (Platform.isMacOS) {
      MacOsDeviceInfo macInfo = await deviceInfo.macOsInfo;
      return macInfo.systemGUID ?? 'UNKNOWN-MAC';
    } else if (Platform.isLinux) {
      LinuxDeviceInfo linuxInfo = await deviceInfo.linuxInfo;
      return linuxInfo.machineId ?? 'UNKNOWN-LINUX';
    }

    return 'UNKNOWN-PLATFORM';
  }
}
