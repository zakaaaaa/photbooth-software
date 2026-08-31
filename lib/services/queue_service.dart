import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_logger.dart';
import 'config_service.dart';

/// Antrean pelanggan.
///
/// ATURAN PALING PENTING DI BERKAS INI: tidak satu pun panggilan di sini boleh
/// menghalangi alur pelanggan. Antrean adalah lapisan tambahan di atas kios
/// yang sudah bekerja — kalau servernya mati, sinyalnya putus, atau balasannya
/// aneh, kios harus berperilaku persis seperti sebelum fitur ini ada. Karena
/// itu semua method menelan galatnya sendiri dan mengembalikan nilai netral,
/// dan tidak ada satu pun yang melempar ke pemanggil.
///
/// Kios hanya PEMBACA antrean, bukan pemiliknya. Yang menentukan siapa
/// dipanggil adalah server dan panel operator; kios cuma menampilkan, mengklaim
/// kode, lalu melapor sesinya selesai. Konsekuensinya disengaja: kalau aplikasi
/// ini mati di tengah acara, antrean tetap hidup dan operator tetap bisa
/// memanggil orang dari HP-nya.

class QueueTicket {
  final String id;
  final int nomor;
  final String? nama;
  final String? frameId;

  /// Terisi hanya kalau sesinya sudah lunas di luar kios. Belum dipakai —
  /// pembayaran di alur ini terjadi SETELAH foto, jadi tidak ada yang bisa
  /// dilunasi lebih dulu dari HP. Disimpan supaya jalurnya tidak perlu
  /// dibongkar lagi kalau urutan itu berubah.
  final String? sessionTransactionCode;

  const QueueTicket({
    required this.id,
    required this.nomor,
    this.nama,
    this.frameId,
    this.sessionTransactionCode,
  });
}

/// Ringkasan satu tiket untuk papan panggilan di layar idle.
class QueueEntry {
  final int nomor;
  final String? nama;

  const QueueEntry({required this.nomor, this.nama});

  factory QueueEntry.fromJson(Map<String, dynamic> j) => QueueEntry(
        nomor: (j['nomor'] as num?)?.toInt() ?? 0,
        nama: j['nama'] as String?,
      );
}

class QueueState {
  /// off | on | closing. 'off' berarti kios harus tampil persis seperti
  /// sebelum fitur antrean ada.
  final String mode;
  final int menunggu;
  final QueueEntry? dipanggil;
  final QueueEntry? dilayani;
  final List<QueueEntry> berikutnya;

  const QueueState({
    required this.mode,
    required this.menunggu,
    this.dipanggil,
    this.dilayani,
    this.berikutnya = const [],
  });

  bool get aktif => mode != 'off';

  static const QueueState mati = QueueState(mode: 'off', menunggu: 0);

  factory QueueState.fromJson(Map<String, dynamic> j) {
    QueueEntry? entri(String kunci) {
      final v = j[kunci];
      return v is Map<String, dynamic> ? QueueEntry.fromJson(v) : null;
    }

    return QueueState(
      mode: j['mode'] as String? ?? 'off',
      menunggu: (j['menunggu'] as num?)?.toInt() ?? 0,
      dipanggil: entri('dipanggil'),
      dilayani: entri('dilayani'),
      berikutnya: (j['berikutnya'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(QueueEntry.fromJson)
              .toList() ??
          const [],
    );
  }
}

class ClaimResult {
  final bool berhasil;
  final QueueTicket? tiket;
  final String? pesan;

  const ClaimResult({required this.berhasil, this.tiket, this.pesan});
}

class QueueService {
  QueueService._();
  static final QueueService instance = QueueService._();

  String get _baseUrl => "${ConfigService().baseUrl}/api/queue";

  /// Tiket yang sedang dilayani di kios ini, dibawa lintas halaman sejak
  /// kodenya diklaim di layar idle sampai tombol "Selesai" ditekan.
  QueueTicket? _aktif;
  QueueTicket? get aktif => _aktif;

  void bersihkan() => _aktif = null;

  /// Keadaan antrean untuk papan di layar idle.
  ///
  /// Mengembalikan [QueueState.mati] pada kegagalan apa pun — layar idle lalu
  /// tampil seperti biasa. Ini disengaja: booth yang kehilangan internet harus
  /// tetap bisa melayani pelanggan yang berdiri di depannya.
  Future<QueueState> ambilState(String hwid) async {
    if (hwid.isEmpty) return QueueState.mati;
    try {
      final r = await http
          .post(
            Uri.parse("$_baseUrl/kiosk/state"),
            headers: const {
              "Content-Type": "application/json",
              "Accept": "application/json",
            },
            body: jsonEncode({'hwid': hwid}),
          )
          .timeout(const Duration(seconds: 8));

      if (r.statusCode == 200) {
        return QueueState.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
      }
    } catch (e) {
      AppLogger.debug("Queue state error: $e");
    }
    return QueueState.mati;
  }

  /// Menukar kode 4 digit dengan tiketnya.
  ///
  /// Verifikasi ini yang mencegah orang lain memakai giliran yang bukan
  /// haknya, jadi kegagalannya HARUS terlihat oleh pengguna — berbeda dengan
  /// method lain di kelas ini yang sengaja diam.
  Future<ClaimResult> klaim(String hwid, String kode) async {
    try {
      final r = await http
          .post(
            Uri.parse("$_baseUrl/kiosk/claim"),
            headers: const {
              "Content-Type": "application/json",
              "Accept": "application/json",
            },
            body: jsonEncode({'hwid': hwid, 'claim_code': kode}),
          )
          .timeout(const Duration(seconds: 12));

      final data = jsonDecode(r.body) as Map<String, dynamic>;

      if (r.statusCode == 200 && data['success'] == true) {
        final sesi = data['session'];
        _aktif = QueueTicket(
          id: data['ticket_id'] as String,
          nomor: (data['nomor'] as num?)?.toInt() ?? 0,
          nama: data['nama'] as String?,
          frameId: data['frame_id'] as String?,
          sessionTransactionCode:
              sesi is Map<String, dynamic> ? sesi['transaction_code'] as String? : null,
        );
        return ClaimResult(berhasil: true, tiket: _aktif);
      }

      return ClaimResult(
        berhasil: false,
        pesan: data['message'] as String? ?? 'Kode tidak dikenali.',
      );
    } catch (e) {
      AppLogger.debug("Queue claim error: $e");
      return const ClaimResult(
        berhasil: false,
        pesan: 'Tidak bisa terhubung ke server. Panggil petugas ya.',
      );
    }
  }

  /// Memberi tahu server bahwa kameranya sebentar lagi bebas, supaya orang
  /// berikutnya bisa dikabari lebih awal.
  ///
  /// Dipanggil saat pelanggan masuk tahap preview — bukan saat sesi selesai.
  /// Kalau orang berikutnya baru dikabari ketika gilirannya benar-benar tiba,
  /// booth menganggur selama dia berjalan kembali dari tempatnya menunggu.
  Future<void> preCall(String hwid) async {
    if (hwid.isEmpty) return;
    try {
      await http
          .post(
            Uri.parse("$_baseUrl/kiosk/precall"),
            headers: const {"Content-Type": "application/json"},
            body: jsonEncode({'hwid': hwid}),
          )
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      AppLogger.debug("Queue precall error: $e");
    }
  }

  /// Menutup tiket yang sedang dilayani; server lalu memanggil berikutnya.
  ///
  /// [sessionUuid] mengikat sesi ke tiketnya supaya dasbor bisa melihat
  /// transaksi mana yang datang dari antrean. Kosong pun tidak apa-apa —
  /// antrean tetap harus maju meski penautannya gagal.
  Future<void> selesai(String hwid, {String? sessionUuid}) async {
    if (hwid.isEmpty) {
      bersihkan();
      return;
    }
    try {
      await http
          .post(
            Uri.parse("$_baseUrl/kiosk/done"),
            headers: const {"Content-Type": "application/json"},
            body: jsonEncode({
              'hwid': hwid,
              if (_aktif != null) 'ticket_id': _aktif!.id,
              if (sessionUuid != null && sessionUuid.isNotEmpty)
                'session_uuid': sessionUuid,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      AppLogger.debug("Queue done error: $e");
    } finally {
      // Tiket dilepas apa pun hasilnya. Tiket yang menempel setelah sesi
      // berakhir jauh lebih berbahaya daripada satu baris yatim di server:
      // pelanggan berikutnya akan mewarisi frame dan nomor orang sebelumnya.
      bersihkan();
    }
  }
}
