import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../utils/video_composer.dart';

// ================================================================
// EDSDK CAMERA SERVICE (sisi Dart)
//
// Mengendalikan Canon EOS Kiss X7 / 100D langsung lewat Canon EDSDK,
// menggantikan EOS Webcam Utility (yang versi gratisnya mentok 720p →
// hasil cetak pecah) dan digiCamControl (live view-nya lag).
//
// EDSDK dijalankan di PROSES TERPISAH (`edsdk_bridge.exe`, x86) karena:
//   - EDSDK.dll yang tersedia 32-bit, app Flutter 64-bit;
//   - EDSDK butuh message pump Win32 sendiri;
//   - kalau kamera dicabut / SDK crash, app photobooth tidak ikut mati.
//
// Komunikasi lewat pipe stdio — BUKAN HTTP/web server, jadi tidak ada
// overhead encoding ulang maupun delay: frame JPEG mentah dari kamera
// langsung mendarat di Flutter.
//
//   stdout bridge : "EDS1" | type u32 LE | length u32 LE | payload
//                   type 1 = frame live view, type 2 = foto full-res
//   stderr bridge : baris teks READY / EVENT / LOG / ERR
//   stdin  bridge : LIVEVIEW ON|OFF, AF, CAPTURE, INFO, QUIT
//
// API-nya sengaja dibuat sebangun dengan [CaptureCardService] supaya
// wiring di camera_page seragam: frames (preview), latestFrame /
// takePicture (foto), startClipBuffer / stopClipAndEncode (video).
// ================================================================
class EdsdkCameraService {
  Process? _proc;
  StreamSubscription<List<int>>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  final StreamController<Uint8List> _frameController =
      StreamController<Uint8List>.broadcast();

  Uint8List? _latestFrame;
  Uint8List? _lastPhoto;
  String? _model;

  // Alasan kegagalan terakhir, dalam bahasa yang bisa dibaca operator booth.
  // Tanpa ini, layar hanya bisa bilang "kamera tidak ditemukan" padahal
  // bridge sudah tahu persis sebabnya (kamera mati, dipakai app lain, dll).
  String? _lastError;
  String? get lastError => _lastError;

  // Alasan gagal dari probe --list (statis karena probe berjalan sebelum
  // ada instance yang hidup).
  static String? lastProbeError;
  bool _wantRunning = false;
  bool _liveViewOn = false;
  int _evfFps = 30;
  int _restartAttempts = 0;

  Completer<bool>? _readyCompleter;
  Completer<Uint8List?>? _photoCompleter;
  Completer<void>? _afCompleter;

  // Denyut nadi ke bridge. Harus jauh lebih rapat dari _idleTimeoutSec agar
  // bridge tidak pernah salah mengira app-nya hilang saat booth menganggur.
  static const int _idleTimeoutSec = 30;
  static const Duration _heartbeatInterval = Duration(seconds: 8);
  Timer? _heartbeat;

  // Buffer perakitan frame dari pipe (bisa terpotong di tengah header).
  Uint8List _pending = Uint8List(0);

  // Buffer frame untuk klip video (per foto), sama seperti capture card.
  bool _buffering = false;
  final List<Uint8List> _clipFrames = [];
  DateTime? _clipStart;

  Stream<Uint8List> get frames => _frameController.stream;
  Uint8List? get latestFrame => _latestFrame;
  bool get isRunning => _proc != null;
  bool get isLiveViewOn => _liveViewOn;
  String? get model => _model;

  static const int _frameTypeEvf = 1;
  static const int _frameTypePhoto = 2;
  static const List<int> _magic = [0x45, 0x44, 0x53, 0x31]; // "EDS1"

  // Mode AF live view — penentu fps terbesar, tapi hati-hati:
  //   live  (default) deteksi kontras di sensor, ~17fps, AF JALAN saat LV
  //   quick           sensor fase, ~19fps, TAPI preview blur karena kamera
  //                   tidak bisa fokus tanpa menurunkan cermin
  //   face            deteksi wajah, ~16fps
  //   multi           multi-titik (setelan awal body), ~12fps
  //   keep            biarkan setelan bodi apa adanya
  // Ganti tanpa ubah kode:
  //   flutter run -d windows --dart-define=PHOTOBOOTH_AF_MODE=face
  static const String _afMode =
      String.fromEnvironment('PHOTOBOOTH_AF_MODE', defaultValue: 'live');

  // ---------------------------------------------------------------
  // Lokasi edsdk_bridge.exe. Urutannya mengikuti pola resolveFfmpeg()
  // supaya sama-sama jalan di `flutter run` maupun di build rilis.
  // Catatan: EDSDK.dll & EdsImage.dll HARUS bersebelahan dengan exe ini.
  // ---------------------------------------------------------------
  static String? resolveBridge() {
    final env = Platform.environment['EDSDK_BRIDGE_PATH'];
    if (env != null && env.isNotEmpty && File(env).existsSync()) return env;

    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    final String cwd = Directory.current.path;
    final candidates = [
      '$exeDir/edsdk_bridge.exe',
      '$exeDir/data/flutter_assets/assets/bin/edsdk_bridge.exe',
      '$cwd/assets/bin/edsdk_bridge.exe',
      '$cwd/tools/edsdk_bridge.exe',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  // Cek cepat: ada kamera Canon tertambat? Memakai mode --list yang hanya
  // meng-enumerasi lalu keluar, jadi TIDAK merebut sesi USB.
  static Future<bool> isCameraPresent() async {
    final exe = resolveBridge();
    if (exe == null) {
      debugPrint('[EDSDK] edsdk_bridge.exe tidak ditemukan.');
      return false;
    }
    try {
      final res = await Process.run(exe, ['--list'])
          .timeout(const Duration(seconds: 8));
      if (res.exitCode != 0) {
        final msg = res.stderr.toString().trim();
        debugPrint('[EDSDK] --list: $msg');
        lastProbeError = _humanize(msg);
        return false;
      }
      lastProbeError = null;
      return true;
    } catch (e) {
      debugPrint('[EDSDK] --list error: $e');
      lastProbeError = 'Gagal menjalankan edsdk_bridge.exe.';
      return false;
    }
  }

  // ---------------------------------------------------------------
  // Jalankan bridge & buka sesi kamera. Return false → pemanggil harus
  // fallback (EOS Webcam Utility / capture card / webcam biasa).
  // ---------------------------------------------------------------
  Future<bool> initialize({int evfFps = 30, int waitSeconds = 6}) async {
    if (_proc != null) return true;
    await _killStrayBridges();
    _evfFps = evfFps;
    _wantRunning = true;
    _restartAttempts = 0;
    return _spawn(waitSeconds: waitSeconds);
  }

  // Saat layar kamera dibuka, TIDAK boleh ada bridge lain yang berjalan —
  // hanya satu sesi USB yang mungkin. Kalau ada sisa dari layar sebelumnya
  // yang gagal ditutup, ia akan menolak sesi kita (EdsOpenSession 0xC0) dan
  // app diam-diam turun ke EOS Webcam 720p. Jadi sapu bersih dulu.
  static Future<void> _killStrayBridges() async {
    if (!Platform.isWindows) return;
    try {
      final res = await Process.run(
        'taskkill',
        ['/F', '/IM', 'edsdk_bridge.exe'],
      ).timeout(const Duration(seconds: 5));
      // exitCode 128 = tidak ada proses seperti itu (kondisi normal).
      if (res.exitCode == 0) {
        debugPrint('[EDSDK] membersihkan bridge yatim dari sesi sebelumnya.');
      }
    } catch (e) {
      debugPrint('[EDSDK] gagal menyapu bridge yatim: $e');
    }
  }

  Future<bool> _spawn({int waitSeconds = 6}) async {
    if (!_wantRunning) return false;
    final exe = resolveBridge();
    if (exe == null) return false;

    _pending = Uint8List(0);
    final ready = Completer<bool>();
    _readyCompleter = ready;

    try {
      _proc = await Process.start(exe, [
        '--wait', '$waitSeconds',
        '--evf-fps', '$_evfFps',
        '--af-mode', _afMode,
        // Bridge bunuh diri kalau kita berhenti mengirim PING. Tanpa ini,
        // satu kali dispose() yang gagal = bridge yatim memegang USB dan
        // SEMUA sesi foto berikutnya diam-diam turun ke EOS Webcam 720p.
        '--idle-timeout', '$_idleTimeoutSec',
      ]);
    } catch (e) {
      debugPrint('[EDSDK] gagal start bridge: $e');
      _proc = null;
      _readyCompleter = null;
      return false;
    }

    _stdoutSub = _proc!.stdout.listen(
      _onStdout,
      onError: (e) => debugPrint('[EDSDK] stdout error: $e'),
      cancelOnError: false,
    );
    _stderrSub = _proc!.stderr
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen(_onStderrLine);

    _proc!.exitCode.then(_onExit);

    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(_heartbeatInterval, (_) {
      if (_proc == null) return;
      _send('PING');
    });

    // Bridge menunggu kamera sampai `waitSeconds`, beri kelonggaran sedikit.
    try {
      return await ready.future
          .timeout(Duration(seconds: waitSeconds + 6), onTimeout: () => false);
    } finally {
      _readyCompleter = null;
    }
  }

  void _onExit(int code) {
    debugPrint('[EDSDK] bridge exit code: $code');
    _proc = null;
    _liveViewOn = false;

    // Jangan biarkan pemanggil menggantung kalau bridge mati di tengah jalan.
    if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
      _readyCompleter!.complete(false);
    }
    if (_photoCompleter != null && !_photoCompleter!.isCompleted) {
      _photoCompleter!.complete(null);
    }
    if (_afCompleter != null && !_afCompleter!.isCompleted) {
      _afCompleter!.complete();
    }

    // Exit 2/3 = kamera tidak ada / dipakai aplikasi lain: me-respawn hanya
    // akan berputar sia-sia, biarkan app fallback ke sumber kamera lain.
    if (_wantRunning && code != 2 && code != 3) {
      _restartAttempts++;
      if (_restartAttempts <= 5) {
        final delayMs = (400 * _restartAttempts).clamp(400, 4000);
        Future.delayed(Duration(milliseconds: delayMs), () async {
          if (!_wantRunning) return;
          final ok = await _spawn();
          // Pulihkan live view supaya preview tidak diam setelah reconnect.
          if (ok && _liveViewWanted) await startLiveView(fps: _evfFps);
        });
      } else {
        debugPrint('[EDSDK] menyerah me-restart bridge setelah 5 percobaan.');
        _wantRunning = false;
      }
    }
  }

  bool _liveViewWanted = false;

  // ---------------------------------------------------------------
  // Parsing bingkai biner dari stdout.
  // ---------------------------------------------------------------
  void _onStdout(List<int> chunk) {
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
    var offset = 0;
    final buf = _pending;
    while (true) {
      if (buf.length - offset < 12) break;

      // Sinkronisasi: kalau magic tidak cocok, majukan 1 byte. Normalnya
      // tidak pernah terjadi, tapi ini menjaga stream tetap pulih sendiri
      // seandainya ada byte nyasar.
      if (buf[offset] != _magic[0] ||
          buf[offset + 1] != _magic[1] ||
          buf[offset + 2] != _magic[2] ||
          buf[offset + 3] != _magic[3]) {
        offset++;
        continue;
      }

      final type = _readU32(buf, offset + 4);
      final len = _readU32(buf, offset + 8);
      if (buf.length - offset - 12 < len) break; // payload belum lengkap

      final payload =
          Uint8List.fromList(Uint8List.sublistView(buf, offset + 12, offset + 12 + len));
      offset += 12 + len;
      _emit(type, payload);
    }

    _pending = offset == 0
        ? buf
        : Uint8List.fromList(Uint8List.sublistView(buf, offset));
  }

  int _readU32(Uint8List b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

  void _emit(int type, Uint8List payload) {
    if (type == _frameTypeEvf) {
      _latestFrame = payload;
      _restartAttempts = 0; // stream sehat → reset backoff
      if (!_frameController.isClosed) _frameController.add(payload);
      if (_buffering) _clipFrames.add(payload);
    } else if (type == _frameTypePhoto) {
      _lastPhoto = payload;
      if (_photoCompleter != null && !_photoCompleter!.isCompleted) {
        _photoCompleter!.complete(payload);
      }
    }
  }

  // ---------------------------------------------------------------
  // Event teks dari stderr.
  // ---------------------------------------------------------------
  void _onStderrLine(String line) {
    final t = line.trim();
    if (t.isEmpty) return;

    if (t.startsWith('READY')) {
      final m = RegExp(r'model=(.*?)(?:\s+port=|$)').firstMatch(t);
      _model = m?.group(1)?.trim();
      debugPrint('[EDSDK] siap: $t');
      if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
        _readyCompleter!.complete(true);
      }
      return;
    }

    if (t.startsWith('EVENT ')) {
      final ev = t.substring(6);
      if (ev.startsWith('LIVEVIEW=')) {
        _liveViewOn = ev.endsWith('ON');
      } else if (ev.startsWith('AF_DONE') || ev.startsWith('AF_FAIL')) {
        if (_afCompleter != null && !_afCompleter!.isCompleted) {
          _afCompleter!.complete();
        }
      } else if (ev.startsWith('CAPTURE_FAIL')) {
        if (_photoCompleter != null && !_photoCompleter!.isCompleted) {
          _photoCompleter!.complete(null);
        }
      }
      debugPrint('[EDSDK] $ev');
      return;
    }

    if (t.startsWith('ERR')) {
      debugPrint('[EDSDK][err] $t');
      _lastError = _humanize(t);
      if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
        _readyCompleter!.complete(false);
      }
      return;
    }

    debugPrint('[EDSDK] $t');
  }

  // Ubah baris ERR mentah dari bridge jadi kalimat yang berguna di layar
  // booth. Operator butuh tahu APA yang harus dilakukan, bukan kode heksa.
  static String _humanize(String raw) {
    final s = raw.replaceFirst(RegExp(r'^ERR\s+(0x[0-9A-Fa-f]+|\w+)\s*'), '');
    if (raw.contains('NO_CAMERA')) {
      return 'Kamera tidak terdeteksi.\n'
          'Periksa: kamera menyala, kabel USB tersambung,\n'
          'dan mode putar di M / Av / Tv (bukan Auto).';
    }
    if (raw.contains('DEVICE_BUSY') || raw.contains('dipakai aplikasi lain')) {
      return 'Kamera sedang dipakai aplikasi lain.\n'
          'Tutup EOS Webcam Utility / EOS Utility / digiCamControl.';
    }
    return s.isEmpty ? raw : s;
  }

  void _send(String cmd) {
    final p = _proc;
    if (p == null) return;
    try {
      p.stdin.writeln(cmd);
    } catch (e) {
      debugPrint('[EDSDK] gagal kirim "$cmd": $e');
    }
  }

  // ---------------------------------------------------------------
  // Kontrol
  // ---------------------------------------------------------------
  Future<bool> startLiveView({int fps = 30}) async {
    if (_proc == null) return false;
    _evfFps = fps;
    _liveViewWanted = true;
    _send('LIVEVIEW ON $fps');

    // Tunggu frame pertama benar-benar datang, bukan sekadar ACK, supaya
    // pemanggil tahu preview sudah bisa ditampilkan.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (_latestFrame != null) return true;
      await Future.delayed(const Duration(milliseconds: 60));
    }
    debugPrint('[EDSDK] live view tidak menghasilkan frame dalam 5 detik.');
    return false;
  }

  Future<void> stopLiveView() async {
    _liveViewWanted = false;
    if (_proc == null) return;
    _send('LIVEVIEW OFF');
    _liveViewOn = false;
  }

  // Kunci fokus sekali di awal sesi. Setelah ini takePicture() memakai
  // shutter non-AF, jadi tidak ada jeda hunting fokus saat countdown habis.
  Future<void> autoFocus() async {
    if (_proc == null) return;
    final c = Completer<void>();
    _afCompleter = c;
    _send('AF');
    try {
      await c.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    } finally {
      _afCompleter = null;
    }
  }

  // Jepret foto resolusi penuh (18MP). Bytes JPEG dikirim balik lewat pipe,
  // tidak lewat file, jadi tidak ada I/O disk di jalur kritis.
  Future<Uint8List?> takePicture({bool withAf = false}) async {
    if (_proc == null) return null;
    final c = Completer<Uint8List?>();
    _photoCompleter = c;
    _send(withAf ? 'CAPTURE AF' : 'CAPTURE');
    try {
      return await c.future
          .timeout(const Duration(seconds: 20), onTimeout: () => null);
    } finally {
      _photoCompleter = null;
    }
  }

  Uint8List? get lastPhoto => _lastPhoto;

  // ---------------------------------------------------------------
  // Klip video (dipakai fitur "Video" — sama seperti CaptureCardService).
  // ---------------------------------------------------------------
  void startClipBuffer() {
    _clipFrames.clear();
    _clipStart = DateTime.now();
    _buffering = true;
  }

  Future<String?> stopClipAndEncode(String outPath) async {
    _buffering = false;
    final frames = List<Uint8List>.from(_clipFrames);
    final started = _clipStart;
    _clipFrames.clear();
    _clipStart = null;
    if (frames.isEmpty) {
      debugPrint('[EDSDK] tidak ada frame untuk klip video');
      return null;
    }

    // JANGAN pakai _evfFps di sini. Nilai itu hanya BATAS ATAS yang kita
    // minta; laju nyata EVF pada EOS 100D cuma ~11fps (EdsDownloadEvfImage
    // ~80ms per frame). Kalau ffmpeg diberi tahu 30fps, klip jadi ~3x lebih
    // cepat dari kejadian aslinya. Jadi ukur laju sebenarnya.
    double fps = _evfFps.toDouble();
    if (started != null) {
      final ms = DateTime.now().difference(started).inMilliseconds;
      if (ms > 300) fps = frames.length * 1000 / ms;
    }
    final fpsArg = fps.clamp(4.0, 60.0).toStringAsFixed(2);
    debugPrint('[EDSDK] klip: ${frames.length} frame @ $fpsArg fps');

    final ff = VideoComposer.resolveFfmpeg();
    try {
      final p = await Process.start(ff, [
        '-y',
        '-hide_banner',
        '-loglevel', 'error',
        '-f', 'image2pipe',
        '-framerate', fpsArg,
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
      if (code == 0) return outPath;
      debugPrint('[EDSDK] encode klip gagal (code $code)');
      return null;
    } catch (e) {
      debugPrint('[EDSDK] encode klip error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------
  Future<void> stop() async {
    _wantRunning = false;
    _liveViewWanted = false;
    _heartbeat?.cancel();
    _heartbeat = null;

    final p = _proc;
    if (p != null) {
      // Beri kesempatan bridge menutup sesi & mematikan live view dengan
      // rapi; kalau kamera ditinggal dalam keadaan EVF aktif, ia bisa
      // menolak sesi berikutnya sampai dimatikan-hidupkan manual.
      debugPrint('[EDSDK] menghentikan bridge (pid ${p.pid})...');
      _send('QUIT');
      var exited = false;
      try {
        await p.exitCode.timeout(const Duration(seconds: 2));
        exited = true;
      } catch (_) {}

      if (!exited) {
        // JANGAN mengandalkan QUIT saja. Terbukti 2026-08-24 bridge bisa
        // tetap hidup dan memegang sesi USB, membuat sesi foto berikutnya
        // jatuh ke EOS Webcam 720p tanpa ada yang sadar.
        debugPrint('[EDSDK] bridge tidak keluar setelah QUIT → kill.');
        try {
          p.kill(ProcessSignal.sigkill);
        } catch (_) {}
        try {
          await p.exitCode.timeout(const Duration(seconds: 2));
        } catch (_) {
          debugPrint('[EDSDK] PERINGATAN: bridge pid ${p.pid} masih hidup.');
        }
      }
    }
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    _proc = null;
    _liveViewOn = false;
  }

  Future<void> dispose() async {
    await stop();
    if (!_frameController.isClosed) await _frameController.close();
  }
}
