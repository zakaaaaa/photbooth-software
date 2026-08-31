import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../utils/video_composer.dart';

// ================================================================
// CAPTURE CARD SERVICE
// Membaca capture card HDMI→USB (mis. chip MS2109 "USB Video") via
// ffmpeg + DirectShow, karena chip semacam ini TIDAK kompatibel dengan
// Media Foundation (yang dipakai plugin camera_windows) → selalu gagal
// "Failed to create camera".
//
// Satu proses ffmpeg membaca device, meng-output aliran MJPEG ke pipe.
// Tiap frame JPEG dipakai untuk:
//   - preview live (stream frames)
//   - ambil foto  (latestFrame saat shutter)
//   - video       (buffer frame selama countdown → encode MP4)
//
// ffmpeg.exe di-resolve lewat VideoComposer.resolveFfmpeg().
// ================================================================
class CaptureCardService {
  Process? _proc;
  StreamSubscription<List<int>>? _stdoutSub;
  final StreamController<Uint8List> _frameController =
      StreamController<Uint8List>.broadcast();

  Uint8List? _latestFrame;
  String? _deviceName;
  int _fps = 20;
  bool _wantRunning = false;
  int _restartAttempts = 0;

  // Buffer perakitan JPEG dari aliran byte pipe.
  Uint8List _pending = Uint8List(0);

  // Buffer frame untuk klip video (per foto).
  bool _buffering = false;
  final List<Uint8List> _clipFrames = [];

  Stream<Uint8List> get frames => _frameController.stream;
  Uint8List? get latestFrame => _latestFrame;
  bool get isRunning => _proc != null;
  String? get deviceName => _deviceName;

  // Kata kunci nama device yang menandakan capture card (bukan webcam biasa).
  static const List<String> _captureKeywords = [
    'usb video',
    'capture',
    'hdmi',
    'ms2109',
    'cam link',
    'camlink',
    'elgato',
    'video capture',
    'usb3.0 video',
    'usb3. video',
  ];

  // Enumerasi device video DirectShow via ffmpeg (-list_devices).
  // ffmpeg mencetak daftar ke stderr lalu keluar dengan error → itu normal.
  static Future<List<String>> listDshowVideoDevices() async {
    final ff = VideoComposer.resolveFfmpeg();
    try {
      final res = await Process.run(ff, [
        '-hide_banner',
        '-list_devices',
        'true',
        '-f',
        'dshow',
        '-i',
        'dummy',
      ]);
      final text = '${res.stdout}\n${res.stderr}';
      final out = <String>[];
      // Baris seperti:  [dshow @ ..] "USB Video" (video)
      final re = RegExp(r'"([^"]+)"\s*\(video\)');
      for (final m in re.allMatches(text)) {
        final name = m.group(1);
        if (name != null && !out.contains(name)) out.add(name);
      }
      return out;
    } catch (e) {
      debugPrint('[capture] listDshowVideoDevices error: $e');
      return [];
    }
  }

  // Pilih device capture card dari daftar (null jika tidak ada yang cocok).
  static String? pickCaptureDevice(List<String> devices) {
    for (final d in devices) {
      final low = d.toLowerCase();
      for (final k in _captureKeywords) {
        if (low.contains(k)) return d;
      }
    }
    return null;
  }

  // Jalankan ffmpeg untuk streaming MJPEG dari device.
  Future<bool> start(String deviceName, {int fps = 20}) async {
    _deviceName = deviceName;
    _fps = fps;
    _wantRunning = true;
    _restartAttempts = 0;
    return _spawn();
  }

  Future<bool> _spawn() async {
    if (!_wantRunning) return false;
    final ff = VideoComposer.resolveFfmpeg();
    _pending = Uint8List(0);
    try {
      // Sengaja TIDAK memaksa -video_size/-framerate: chip MS2109 sering
      // melempar "demuxing I/O error" bila timing HDMI dari kamera tidak
      // persis cocok. Biarkan ffmpeg pakai format native dari device.
      _proc = await Process.start(ff, [
        '-hide_banner',
        '-loglevel', 'error',
        '-f', 'dshow',
        '-rtbufsize', '256M',
        '-vcodec', 'mjpeg', // minta pin MJPEG dari device
        '-i', 'video=$deviceName',
        '-an', // abaikan audio
        // Re-encode ke MJPEG baseline standar supaya PASTI bisa di-decode
        // Flutter (varian JPEG dari MS2109 kadang non-standar / rusak; ffmpeg
        // otomatis skip frame rusak & duplikasi frame bagus).
        '-c:v', 'mjpeg',
        '-q:v', '4',
        // Cap ke 20fps: device native 1080p60 terlalu berat untuk di-decode
        // terus-menerus di Flutter.
        '-r', '$_fps',
        '-f', 'mjpeg',
        'pipe:1',
      ]);
    } catch (e) {
      debugPrint('[capture] gagal start ffmpeg: $e');
      _proc = null;
      return false;
    }

    _stdoutSub = _proc!.stdout.listen(
      _onData,
      onError: (e) => debugPrint('[capture] stdout error: $e'),
      cancelOnError: false,
    );
    _proc!.stderr.transform(const SystemEncoding().decoder).listen((line) {
      final t = line.trim();
      if (t.isNotEmpty) debugPrint('[capture][ffmpeg] $t');
    });
    _proc!.exitCode.then((code) {
      debugPrint('[capture] ffmpeg exit code: $code');
      _proc = null;
      // Auto-restart bila masih diinginkan (mis. sinyal Canon sempat drop).
      if (_wantRunning) {
        _restartAttempts++;
        final delayMs = (300 * _restartAttempts).clamp(300, 3000);
        Future.delayed(Duration(milliseconds: delayMs), () {
          if (_wantRunning) _spawn();
        });
      }
    });

    return true;
  }

  void _onData(List<int> chunk) {
    // Gabungkan sisa + chunk baru lalu ekstrak frame JPEG utuh.
    if (_pending.isEmpty) {
      _pending = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    } else {
      final merged = Uint8List(_pending.length + chunk.length);
      merged.setRange(0, _pending.length, _pending);
      merged.setRange(_pending.length, merged.length, chunk);
      _pending = merged;
    }
    _extractFrames();
  }

  void _extractFrames() {
    var buf = _pending;
    var searchFrom = 0;
    while (true) {
      final start = _indexOfMarker(buf, 0xD8, searchFrom); // SOI FFD8
      if (start < 0) {
        // Tidak ada SOI; simpan 1 byte terakhir kalau 0xFF (boundary).
        if (buf.isNotEmpty && buf.last == 0xFF) {
          _pending = Uint8List.sublistView(buf, buf.length - 1);
        } else {
          _pending = Uint8List(0);
        }
        return;
      }
      final end = _indexOfMarker(buf, 0xD9, start + 2); // EOI FFD9
      if (end < 0) {
        // Frame belum lengkap; buang byte sebelum SOI, tunggu chunk berikut.
        _pending = Uint8List.sublistView(buf, start);
        return;
      }
      final frame = Uint8List.fromList(
          Uint8List.sublistView(buf, start, end + 2));
      _emit(frame);
      // Lanjut cari frame berikutnya di sisa buffer.
      buf = Uint8List.sublistView(buf, end + 2);
      searchFrom = 0;
    }
  }

  // Cari penanda 0xFF <second> mulai dari index `from`.
  int _indexOfMarker(Uint8List data, int second, int from) {
    for (int i = from; i + 1 < data.length; i++) {
      if (data[i] == 0xFF && data[i + 1] == second) return i;
    }
    return -1;
  }

  void _emit(Uint8List frame) {
    _latestFrame = frame;
    _restartAttempts = 0; // stream sehat → reset backoff restart
    if (!_frameController.isClosed) _frameController.add(frame);
    if (_buffering) _clipFrames.add(frame);
  }

  // Mulai merekam (buffer) frame untuk klip video foto ini.
  void startClipBuffer() {
    _clipFrames.clear();
    _buffering = true;
  }

  // Hentikan buffer & encode klip ke MP4. `hflip` agar konsisten dengan
  // foto yang di-mirror (selfie). Mengembalikan path bila sukses.
  Future<String?> stopClipAndEncode(String outPath) async {
    _buffering = false;
    final frames = List<Uint8List>.from(_clipFrames);
    _clipFrames.clear();
    if (frames.isEmpty) {
      debugPrint('[capture] tidak ada frame untuk klip video');
      return null;
    }

    final ff = VideoComposer.resolveFfmpeg();
    try {
      final p = await Process.start(ff, [
        '-y',
        '-hide_banner',
        '-loglevel', 'error',
        '-f', 'image2pipe',
        '-framerate', '$_fps',
        '-vcodec', 'mjpeg',
        '-i', 'pipe:0',
        '-vf', 'hflip,scale=trunc(iw/2)*2:trunc(ih/2)*2',
        '-c:v', 'libx264',
        '-pix_fmt', 'yuv420p',
        '-preset', 'veryfast',
        outPath,
      ]);
      for (final f in frames) {
        p.stdin.add(f);
      }
      await p.stdin.flush();
      await p.stdin.close();
      final code = await p.exitCode;
      if (code == 0) {
        debugPrint('[capture] klip video tersimpan: $outPath');
        return outPath;
      }
      debugPrint('[capture] encode klip gagal (code $code)');
      return null;
    } catch (e) {
      debugPrint('[capture] encode klip error: $e');
      return null;
    }
  }

  Future<void> stop() async {
    _wantRunning = false;
    await _stdoutSub?.cancel();
    _stdoutSub = null;
    try {
      _proc?.kill();
    } catch (_) {}
    _proc = null;
  }

  Future<void> dispose() async {
    await stop();
    if (!_frameController.isClosed) await _frameController.close();
  }
}
