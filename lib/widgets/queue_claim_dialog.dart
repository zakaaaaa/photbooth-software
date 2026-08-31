import 'package:flutter/material.dart';

import '../services/queue_service.dart';

/// Dialog untuk menukar kode antrean 4 digit dengan giliran berfoto.
///
/// Papan angkanya dibuat sendiri, bukan memakai [RetroKeyboard], karena di sini
/// yang diketik hanya empat angka di layar sentuh sambil berdiri — tombolnya
/// perlu jauh lebih besar daripada tuts QWERTY.
///
/// Mengembalikan `true` lewat [Navigator.pop] kalau kode berhasil diklaim;
/// tiketnya sendiri sudah tersimpan di [QueueService.instance.aktif].
class QueueClaimDialog extends StatefulWidget {
  final String hwid;

  const QueueClaimDialog({super.key, required this.hwid});

  @override
  State<QueueClaimDialog> createState() => _QueueClaimDialogState();
}

class _QueueClaimDialogState extends State<QueueClaimDialog> {
  static const Color _panel = Color(0xFF7A4636);
  static const Color _key = Color(0xFFFFF6E6);
  static const Color _keyText = Color(0xFF5A3A2A);
  static const Color _merah = Color(0xFFC23A2A);

  String _kode = '';
  bool _sibuk = false;
  String? _galat;

  void _tekan(String angka) {
    if (_sibuk || _kode.length >= 4) return;
    setState(() {
      _kode += angka;
      _galat = null;
    });
    // Empat digit sudah lengkap — langsung kirim. Menuntut satu ketukan
    // "OK" tambahan hanya menambah langkah pada orang yang sedang ditunggu
    // antrean di belakangnya.
    if (_kode.length == 4) _kirim();
  }

  void _hapus() {
    if (_sibuk || _kode.isEmpty) return;
    setState(() {
      _kode = _kode.substring(0, _kode.length - 1);
      _galat = null;
    });
  }

  Future<void> _kirim() async {
    setState(() => _sibuk = true);
    final hasil = await QueueService.instance.klaim(widget.hwid, _kode);
    if (!mounted) return;

    if (hasil.berhasil) {
      Navigator.of(context).pop(true);
      return;
    }

    setState(() {
      _sibuk = false;
      _galat = hasil.pesan;
      // Kode dikosongkan supaya percobaan berikutnya tidak menumpuk di atas
      // angka yang sudah terbukti salah.
      _kode = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final lebar = MediaQuery.of(context).size.width;
    final skala = (lebar / 1920).clamp(0.6, 1.2);

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: 520 * skala,
        padding: EdgeInsets.all(28 * skala),
        decoration: BoxDecoration(
          color: _panel,
          borderRadius: BorderRadius.circular(28 * skala),
          boxShadow: const [
            BoxShadow(color: Colors.black45, blurRadius: 30, offset: Offset(0, 12)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'MASUKKAN KODE ANTREAN',
              style: TextStyle(
                color: _key,
                fontSize: 18 * skala,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
              ),
            ),
            SizedBox(height: 6 * skala),
            Text(
              'Empat angka yang tampil di HP kamu',
              style: TextStyle(color: _key.withValues(alpha: 0.7), fontSize: 13 * skala),
            ),
            SizedBox(height: 20 * skala),

            // Empat kotak digit
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(4, (i) {
                final terisi = i < _kode.length;
                return Container(
                  width: 62 * skala,
                  height: 78 * skala,
                  margin: EdgeInsets.symmetric(horizontal: 6 * skala),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: terisi ? _key : _key.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(14 * skala),
                  ),
                  child: Text(
                    terisi ? _kode[i] : '',
                    style: TextStyle(
                      color: _keyText,
                      fontSize: 38 * skala,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                );
              }),
            ),

            SizedBox(height: 14 * skala),
            SizedBox(
              height: 34 * skala,
              child: _sibuk
                  ? SizedBox(
                      width: 22 * skala,
                      height: 22 * skala,
                      child: const CircularProgressIndicator(
                        strokeWidth: 3,
                        valueColor: AlwaysStoppedAnimation<Color>(_key),
                      ),
                    )
                  : _galat != null
                      ? Text(
                          _galat!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: const Color(0xFFFFC9BE),
                            fontSize: 13.5 * skala,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      : const SizedBox.shrink(),
            ),

            SizedBox(height: 10 * skala),
            for (final baris in const [
              ['1', '2', '3'],
              ['4', '5', '6'],
              ['7', '8', '9'],
            ])
              Padding(
                padding: EdgeInsets.only(bottom: 10 * skala),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [for (final a in baris) _tombolAngka(a, skala)],
                ),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _tombolAksi(Icons.close, skala, () => Navigator.of(context).pop(false)),
                _tombolAngka('0', skala),
                _tombolAksi(Icons.backspace_outlined, skala, _hapus),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _tombolAngka(String angka, double skala) => Padding(
        padding: EdgeInsets.symmetric(horizontal: 6 * skala),
        child: Material(
          color: _key,
          borderRadius: BorderRadius.circular(16 * skala),
          child: InkWell(
            borderRadius: BorderRadius.circular(16 * skala),
            onTap: _sibuk ? null : () => _tekan(angka),
            child: SizedBox(
              width: 96 * skala,
              height: 64 * skala,
              child: Center(
                child: Text(
                  angka,
                  style: TextStyle(
                    color: _keyText,
                    fontSize: 28 * skala,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  Widget _tombolAksi(IconData ikon, double skala, VoidCallback aksi) => Padding(
        padding: EdgeInsets.symmetric(horizontal: 6 * skala),
        child: Material(
          color: ikon == Icons.close ? _merah : _key.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(16 * skala),
          child: InkWell(
            borderRadius: BorderRadius.circular(16 * skala),
            onTap: _sibuk ? null : aksi,
            child: SizedBox(
              width: 96 * skala,
              height: 64 * skala,
              child: Center(child: Icon(ikon, color: _key, size: 26 * skala)),
            ),
          ),
        ),
      );
}
