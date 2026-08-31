import 'dart:async';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:http/http.dart' as http;
import 'package:photobooth_app/services/app_logger.dart';

class ConfigService {
  static final ConfigService _instance = ConfigService._internal();
  factory ConfigService() => _instance;
  ConfigService._internal();

  // Backend URLs
  static const String localUrl = String.fromEnvironment(
    'LOCAL_BACKEND_URL',
    defaultValue: 'http://localhost:3001',
  );
  static const String remoteUrl = String.fromEnvironment(
    'PROD_BACKEND_URL',
    defaultValue: 'https://api.pabrikenangan.my.id',
  );

  // Frontend URLs (untuk QR download)
  static const String localFrontendUrl = String.fromEnvironment(
    'LOCAL_FRONTEND_URL',
    defaultValue: 'http://localhost:3000',
  );
  static const String remoteFrontendUrl = String.fromEnvironment(
    'PROD_FRONTEND_URL',
    defaultValue: 'https://www.pabrikenangan.my.id',
  );

  String _baseUrl = localUrl;
  String get baseUrl => _baseUrl;

  bool get _isDevelopment => !kReleaseMode;

  /// Mengikuti prinsip yang sama dengan [baseUrl]: debug & release sama-sama
  /// memakai frontend production. QR "Unduh Softfile" dipindai pakai HP
  /// pelanggan — `localhost` di situ selalu jadi link mati, termasuk saat demo
  /// dan pengujian. Untuk menunjuk frontend lokal, jalankan dengan
  /// `--dart-define=PROD_FRONTEND_URL=http://<ip-lan>:3000`.
  String get frontendUrl => remoteFrontendUrl;

  /// Debug & Release sama-sama pakai production backend (pabrikenangan).
  /// Untuk balik ke localhost saat dev, set _baseUrl = localUrl di blok debug.
  Future<void> init() async {
    if (_isDevelopment) {
      // Debug diarahkan ke production agar app fungsional saat debugging
      // (tidak perlu menjalankan backend Node lokal).
      _baseUrl = remoteUrl;
      AppLogger.debug(
        'ConfigService: Development mode -> production backend: $_baseUrl',
      );

      // Health-check hanya untuk log (tidak mengubah URL aktif)
      try {
        final uri = Uri.parse('$_baseUrl/api/photobooth/license/check');
        await http
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: '{"hwid":"ping"}',
            )
            .timeout(const Duration(seconds: 5));
        AppLogger.debug('ConfigService: Production backend reachable.');
      } catch (e) {
        AppLogger.debug('ConfigService: Backend belum reachable: $e');
      }
      return;
    }

    _baseUrl = remoteUrl;
    AppLogger.debug(
      'ConfigService: Release mode -> production backend: $_baseUrl',
    );
  }
}
