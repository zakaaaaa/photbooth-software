import 'package:photobooth_app/services/api_service.dart';

class EmailService {
  final ApiService _apiService = ApiService();

  Future<bool> sendResultLink({
    required String hwid,
    required String recipientEmail,
    required String resultUrl,
  }) {
    return _apiService.sendResultEmail(
      hwid: hwid,
      recipientEmail: recipientEmail,
      resultUrl: resultUrl,
    );
  }
}
