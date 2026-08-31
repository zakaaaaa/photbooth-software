import 'package:flutter/material.dart';

class AppConfigProvider extends ChangeNotifier {
  Map<String, dynamic> _settings = const {
    'session_price': 30000,
    'extra_print_enabled': true,
    'extra_print_price': 10000,
    'session_duration_minutes': 5,
    'payment_methods_enabled': ['qris', 'voucher'],
    'voucher_enabled': true,
    'download_qr_enabled': true,
    'email_delivery_enabled': false,
    'email_sender_name': 'Amandya Photobooth',
    'email_subject_template': 'Terima kasih sudah berfoto bersama kami',
    'email_body_template': 'Berikut hasil photobooth Anda.',
    'preferred_printer_keyword': 'epson',
    'paper_size': '4R',
    'auto_print_copies': 1,
    'camera_mode': 'webcam',
  };

  bool _isLoaded = false;
  String? _deviceName;
  String? _clientName;

  bool get isLoaded => _isLoaded;
  String? get deviceName => _deviceName;
  String? get clientName => _clientName;

  int get sessionPrice => (_settings['session_price'] as num?)?.toInt() ?? 30000;
  bool get extraPrintEnabled => _settings['extra_print_enabled'] as bool? ?? true;
  int get extraPrintPrice => (_settings['extra_print_price'] as num?)?.toInt() ?? 10000;
  int get sessionDurationMinutes =>
      (_settings['session_duration_minutes'] as num?)?.toInt() ?? 5;
  List<String> get paymentMethodsEnabled =>
      List<String>.from(_settings['payment_methods_enabled'] as List? ?? const ['qris', 'voucher']);
  bool get voucherEnabled => _settings['voucher_enabled'] as bool? ?? true;
  bool get downloadQrEnabled => _settings['download_qr_enabled'] as bool? ?? true;
  bool get emailDeliveryEnabled => _settings['email_delivery_enabled'] as bool? ?? false;
  String get emailSenderName =>
      _settings['email_sender_name'] as String? ?? 'Amandya Photobooth';
  String get emailSubjectTemplate =>
      _settings['email_subject_template'] as String? ??
      'Terima kasih sudah berfoto bersama kami';
  String get emailBodyTemplate =>
      _settings['email_body_template'] as String? ?? 'Berikut hasil photobooth Anda.';
  String get preferredPrinterKeyword =>
      _settings['preferred_printer_keyword'] as String? ?? 'epson';
  String get paperSize => _settings['paper_size'] as String? ?? '4R';
  int get autoPrintCopies => (_settings['auto_print_copies'] as num?)?.toInt() ?? 1;
  String get cameraMode => _settings['camera_mode'] as String? ?? 'webcam';

  void applyBootstrap(Map<String, dynamic> payload) {
    _settings = Map<String, dynamic>.from(payload['settings'] as Map? ?? _settings);
    _deviceName = (payload['device'] as Map?)?['name'] as String?;
    _clientName = (payload['client'] as Map?)?['name'] as String?;
    _isLoaded = true;
    notifyListeners();
  }
}
