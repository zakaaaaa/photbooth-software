import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import '../services/config_service.dart';
import '../services/gif_result_service.dart';
import '../providers/photo_provider.dart';
import 'customization_page.dart';
import 'preview_page.dart';
import 'splash_screen.dart';
import '../utils/frame_composer.dart';
import '../utils/photo_processor.dart';
import '../services/video_result_service.dart';
import '../services/digicam_camera_service.dart';
import '../services/capture_card_service.dart';
import '../services/edsdk_camera_service.dart';
import '../services/upload_queue_service.dart';
import '../services/queue_service.dart';

class CameraPage extends StatefulWidget {
  // Mode khusus pengembangan: lewati inisialisasi kamera dan anggap kamera
  // sudah siap, supaya tata letaknya bisa dirender & di-screenshot pada
  // ukuran layar monitor customer walau kameranya tidak ada.
  // Dipakai oleh lib/main_layout_preview.dart — TIDAK dipakai produksi.
  final bool layoutPreview;

  const CameraPage({super.key, this.layoutPreview = false});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> {
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isCameraInitialized = false;
  String _debugMessage = "Mendeteksi kamera...";

  // Jalur capture card (ffmpeg/DirectShow) untuk chip MS2109 dkk yang tidak
  // kompatibel dengan Media Foundation (camera_windows). Bila terpakai,
  // _cameraController tetap null dan preview/foto/video lewat _capture.
  CaptureCardService? _capture;
  bool _useCaptureCard = false;

  // Jalur UTAMA: Canon EDSDK lewat edsdk_bridge.exe (USB tether tunggal).
  // Memberi live view EVF langsung dari kamera + foto shutter 18MP penuh —
  // tidak lagi terkunci 720p seperti EOS Webcam Utility versi gratis.
  // Bila terpakai, _cameraController & _capture tetap null.
  EdsdkCameraService? _edsdk;
  bool _useEdsdk = false;

  // Fallback ke EOS Webcam / capture card / webcam laptop HANYA untuk
  // pengembangan UI di mesin tanpa Canon. Di booth sungguhan ini harus
  // mati: lebih baik layar berkata "kamera tidak terdeteksi" daripada
  // pelanggan pulang membawa cetakan 720p tanpa ada yang tahu.
  //   flutter run -d windows --dart-define=PHOTOBOOTH_CAMERA_FALLBACK=true
  static const bool _allowFallback =
      bool.fromEnvironment('PHOTOBOOTH_CAMERA_FALLBACK');

  // Kamera sering baru dinyalakan setelah app terbuka, dan bodi Canon
  // mati sendiri saat menganggur. Tanpa coba-ulang, operator harus
  // me-restart app hanya karena kamera telat hidup.
  Timer? _retryTimer;
  static const Duration _retryInterval = Duration(seconds: 4);

  bool _isSessionActive = false;
  bool _isCapturing = false;
  int _countdown = 0;
  bool _showBlink = false;
  bool _isWaitingForManualStart = false;
  int _retakeCount = 0;
  bool _isDSLRProcessing = false;

  // Shutter DSLR via digiCamControl (USB tether). Bila siap, foto diambil
  // dari shutter kamera (18MP, bersih tanpa overlay HDMI) sedangkan preview
  // tetap dari capture card (jalur HDMI terpisah → tidak rebutan USB).
  final DigiCamCameraService _dslrService = DigiCamCameraService();
  bool _dslrReady = false;

  bool _isRendering = false;
  bool _renderDone = false;

  // Sembunyikan/tampilkan tag KERTAS-CAM + preview foto (animasi scrapbook).
  bool _rightPanelHidden = false;

  // Lebar area yang "dipesan" untuk preview frame di kanan, supaya kontrol
  // bawah ter-center di area kamera (kiri) seperti di reference design.
  static const double _framePreviewReserved = 320;
  static const double _deg2rad = 3.141592653589793 / 180;

  // ---- Proporsi panel kanan ----
  // Semua dinyatakan sebagai PECAHAN DARI TINGGI LAYAR, bukan piksel tetap.
  // Alasannya: tag KERTAS-CAM di belakang kartu adalah Image dengan
  // BoxFit.fitHeight setinggi layar, jadi ia selalu berskala mengikuti
  // tinggi layar. Kalau kartunya memakai piksel tetap, keduanya hanya
  // sejajar pada satu ukuran layar — persis bug yang terlihat saat pindah
  // dari laptop 900px ke monitor customer 1080px.
  static const double _kTagAspect = 0.5; // KERTAS-CAM.png = 1000x2000
  static const double _kTagRightOverhang = 20; // tag digeser keluar layar
  static const double _kCardPadding = 9; // bingkai putih di sekeliling foto
  static const double _kCardHeightRatio = 0.55; // tinggi kartu : tinggi layar
  static const double _kCardVerticalShift = 0.145; // turun dari tengah layar

  static final String _backendUrl = ConfigService().baseUrl;

  @override
  void initState() {
    super.initState();
    if (widget.layoutPreview) {
      _isCameraInitialized = true; // jangan tampilkan overlay "memuat kamera"
      _debugMessage = "";
    } else {
      _initCamera();
    }
    // Deteksi DSLR tether (digiCamControl) dinonaktifkan sementara: saat pakai
    // EOS Webcam Utility, kamera dipegang via USB oleh utility itu, jadi jangan
    // ada proses lain (DCC) yang ikut merebut USB. Aktifkan lagi bila balik ke
    // jalur tether. // _initDSLR();
  }

  // Tampilkan sebab kegagalan apa adanya, lalu terus mencoba di latar.
  // Begitu kamera dinyalakan, preview menyambung sendiri tanpa restart.
  void _reportCameraProblem(String reason) {
    debugPrint('[CAMERA] $reason');
    if (mounted) {
      setState(() {
        _isCameraInitialized = false;
        _debugMessage = reason;
      });
    }
    _retryTimer ??= Timer.periodic(_retryInterval, (_) {
      if (!mounted || _isCameraInitialized) {
        _retryTimer?.cancel();
        _retryTimer = null;
        return;
      }
      _initCamera();
    });
  }

  Future<void> _initDSLR() async {
    final ok = await _dslrService.initialize();
    if (!ok) {
      debugPrint('[DSLR] digiCamControl tidak terinstall → pakai capture card.');
      return;
    }
    // Cek kamera benar-benar terhubung via USB sebelum mengandalkan shutter.
    final connected = await _dslrService.detectCamera();
    if (mounted) setState(() => _dslrReady = connected);
    debugPrint(connected
        ? '[DSLR] Kamera tether siap → foto pakai shutter DSLR 18MP.'
        : '[DSLR] digiCamControl ada tapi kamera tidak terdeteksi via USB.');
  }

  @override
  void dispose() {
    debugPrint('[CameraPage] dispose — melepas sumber kamera '
        '(edsdk=${_edsdk != null}, capture=${_capture != null})');
    _retryTimer?.cancel();
    _retryTimer = null;
    _cameraController?.dispose();
    _capture?.dispose();
    // Penting: bridge harus ditutup rapi (QUIT) supaya live view dimatikan
    // dan sesi USB dilepas — kalau tidak, kamera menolak sesi berikutnya dan
    // app turun diam-diam ke EOS Webcam 720p. dispose() di sini sinkron
    // sehingga future-nya tidak bisa ditunggu; itulah kenapa bridge juga
    // punya watchdog sendiri dan kenapa spawn berikutnya menyapu sisa.
    _edsdk?.dispose();
    super.dispose();
  }

  // ================================================================
  // INIT CAMERA
  // ================================================================
  bool _initInFlight = false;

  Future<void> _initCamera() async {
    // Satu percobaan bisa makan beberapa detik (probe + buka sesi + tunggu
    // frame pertama). Tanpa penjaga ini, timer coba-ulang akan menumpuk
    // percobaan yang saling berebut sesi USB.
    if (_initInFlight) return;
    _initInFlight = true;
    try {
      // SUMBER TUNGGAL: Canon EDSDK (tether USB langsung). Satu sesi USB
      // melayani live view EVF + shutter 18MP sekaligus.
      //
      // TIDAK ADA fallback diam-diam ke EOS Webcam Utility. Alasannya:
      // utility itu terkunci 720p, jadi kalau EDSDK gagal di tengah acara
      // pelanggan akan menerima cetakan pecah TANPA ada yang menyadarinya —
      // persis kejadian 2026-08-24. Dan saat kamera memang mati, fallback
      // itu pun cuma menampilkan layar placeholder "EOS WEBCAM UTILITY",
      // yang lebih buruk daripada pesan kesalahan yang jujur.
      // Gagal terang-terangan + coba ulang otomatis jauh lebih aman.
      if (Platform.isWindows) {
        final present = await EdsdkCameraService.isCameraPresent();
        if (present) {
          final svc = EdsdkCameraService();
          if (await svc.initialize(evfFps: 30)) {
            if (await svc.startLiveView(fps: 30)) {
              _edsdk = svc;
              _useEdsdk = true;
              _retryTimer?.cancel();
              debugPrint('[OK] Canon EDSDK aktif: ${svc.model ?? "kamera Canon"}');
              if (mounted) {
                setState(() {
                  _isCameraInitialized = true;
                  _debugMessage = "";
                });
              }
              return;
            }
            debugPrint('[WARN] EDSDK live view tidak menghasilkan frame.');
          }
          final reason = svc.lastError;
          await svc.dispose();
          if (!_allowFallback) {
            _reportCameraProblem(reason ??
                'Kamera terdeteksi tapi live view tidak mau jalan.\n'
                    'Coba matikan lalu nyalakan kembali kameranya.');
            return;
          }
        } else if (!_allowFallback) {
          _reportCameraProblem(EdsdkCameraService.lastProbeError ??
              'Kamera tidak terdeteksi.');
          return;
        }
        debugPrint('[WARN] EDSDK gagal → fallback dev aktif, lanjut sumber lain.');
      }

      // 1) EOS Webcam Utility (virtual webcam Canon via USB).
      //    Ini device Media Foundation biasa → jalur camera_windows. Diutamakan
      //    agar tidak keburu diambil capture card bila MS2109 masih tercolok.
      _cameras = await availableCameras();
      final eos = _cameras.where((c) {
        final n = c.name.toLowerCase();
        return n.contains('eos webcam') || n.contains('eos-webcam');
      }).toList();
      if (eos.isNotEmpty) {
        // Utamakan varian "Pro" (resolusi lebih tinggi) bila ada.
        eos.sort((a, b) {
          final ap = a.name.toLowerCase().contains('pro') ? 0 : 1;
          final bp = b.name.toLowerCase().contains('pro') ? 0 : 1;
          return ap.compareTo(bp);
        });
        for (final cam in eos) {
          debugPrint("[OK] Coba EOS Webcam Utility: ${cam.name}");
          if (await _initWebcamController(cam)) return;
        }
        debugPrint("[WARN] Semua EOS Webcam Utility gagal, lanjut deteksi lain.");
      }

      // 2) Capture card (HDMI→USB, mis. MS2109) via ffmpeg/DirectShow.
      //    Chip ini gagal di camera_windows (Media Foundation), tapi mulus
      //    lewat DirectShow.
      final dshowDevices = await CaptureCardService.listDshowVideoDevices();
      final captureDevice = CaptureCardService.pickCaptureDevice(dshowDevices);
      if (captureDevice != null) {
        debugPrint("[OK] Capture card terdeteksi: $captureDevice");
        final svc = CaptureCardService();
        final ok = await svc.start(captureDevice);
        if (ok && mounted) {
          _capture = svc;
          _useCaptureCard = true;
          setState(() {
            _isCameraInitialized = true;
            _debugMessage = "";
          });
          return;
        } else {
          await svc.dispose();
          debugPrint("[WARN] Gagal start capture card, fallback ke webcam.");
        }
      }

      // 3) Fallback: webcam biasa via camera_windows.
      if (_cameras.isEmpty) {
        if (mounted) setState(() => _debugMessage = "Kamera tidak ditemukan");
        return;
      }
      // Prioritaskan external (capture card / EOS Webcam) → front (webcam laptop).
      final camera = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.external,
        orElse: () => _cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.front,
          orElse: () => _cameras.first,
        ),
      );
      await _initWebcamController(camera);
    } catch (e) {
      if (mounted) setState(() => _debugMessage = "Error kamera: $e");
      debugPrint("[ERR] Camera error: $e");
    } finally {
      _initInFlight = false;
    }
  }

  // Inisialisasi CameraController (camera_windows) dengan fallback resolusi
  // dari tinggi ke sedang. Return true bila berhasil.
  Future<bool> _initWebcamController(CameraDescription camera) async {
    const presets = [
      ResolutionPreset.max,
      ResolutionPreset.veryHigh,
      ResolutionPreset.high,
      ResolutionPreset.medium,
    ];
    Object? lastError;
    for (final preset in presets) {
      try {
        final controller =
            CameraController(camera, preset, enableAudio: false);
        await controller.initialize();
        _cameraController = controller;
        _useCaptureCard = false;
        debugPrint("[OK] Camera '${camera.name}' initialized @ $preset");
        break;
      } catch (e) {
        lastError = e;
        debugPrint("[WARN] Gagal @ $preset: $e");
        await _cameraController?.dispose();
        _cameraController = null;
      }
    }
    if (_cameraController == null) {
      if (mounted) setState(() => _debugMessage = "Error kamera: $lastError");
      return false;
    }
    if (mounted) {
      setState(() {
        _isCameraInitialized = true;
        _debugMessage = "";
      });
    }
    return true;
  }

  // ================================================================
  // SESI FOTO
  // ================================================================
  void _initializeSession() async {
    if (_isSessionActive) return;

    final provider = Provider.of<PhotoProvider>(context, listen: false);

    // Filter tidak lagi dikunci di sini — foto diambil RAW (tanpa color filter)
    // dan filter dipilih nanti di PreviewPage.
    provider.clearPhotos();
    setState(() {
      _isSessionActive = true;
      _isWaitingForManualStart = true;
      _retakeCount = 0;
      _renderDone = false;
    });

    // Kunci fokus SEKALI di awal sesi, bukan tiap jepret: jarak tamu ke
    // kamera praktis tetap di booth, dan AF per-foto menambah jeda 0,3–1
    // detik plus sering gagal hunting di ruangan remang.
    if (_useEdsdk && _edsdk != null && _edsdk!.isRunning) {
      unawaited(_edsdk!.autoFocus());
    }
  }

  Future<void> _proceedToCapture() async {
    if (!_isSessionActive || _isCapturing) return;

    setState(() {
      _isWaitingForManualStart = false;
    });

    await _performSingleCapture();

    if (!mounted) return;
    final provider = Provider.of<PhotoProvider>(context, listen: false);
    final int total = provider.targetPhotoCount;

    if (mounted) {
      if (provider.photos.length < total) {
        setState(() {
          _isWaitingForManualStart = true;
        });
      } else {
        setState(() {
          _isSessionActive = false;
        });
        _triggerBackgroundRender();
      }
    }
  }

  void _retakeSpecificPhoto(int index) async {
    if (_isSessionActive || _isCapturing) return;

    final provider = Provider.of<PhotoProvider>(context, listen: false);
    provider.removePhotoAt(index);

    setState(() {
      _retakeCount++;
      _isSessionActive = true;
      _renderDone = false;
    });

    await _performSingleCapture();

    if (mounted) setState(() => _isSessionActive = false);

    if (!mounted) return;
    final prov = Provider.of<PhotoProvider>(context, listen: false);
    if (mounted && prov.isComplete) {
      _triggerBackgroundRender();
    }
  }

  Future<void> _performSingleCapture() async {
    setState(() => _isCapturing = true);

    // Mulai rekam video (silent) selama countdown 5 detik.
    bool recording = false;
    try {
      if (_useEdsdk && _edsdk != null && _edsdk!.isRunning) {
        // Klip video dirakit dari frame live view EVF (sama seperti jalur
        // capture card) — kamera DSLR tidak bisa merekam video sambil siap
        // menjepret still.
        _edsdk!.startClipBuffer();
        recording = true;
      } else if (_useCaptureCard && _capture != null && _capture!.isRunning) {
        _capture!.startClipBuffer();
        recording = true;
      } else if (_cameraController != null &&
          _cameraController!.value.isInitialized &&
          !_cameraController!.value.isRecordingVideo) {
        await _cameraController!.startVideoRecording();
        recording = true;
      }
    } catch (e) {
      debugPrint('[WARN] Mulai rekam video gagal: $e');
    }

    for (int i = 5; i > 0; i--) {
      if (!mounted) {
        if (recording) {
          try {
            if (_useEdsdk) {
              await _edsdk?.stopClipAndEncode(await _newClipPath());
            } else if (_useCaptureCard) {
              await _capture?.stopClipAndEncode(await _newClipPath());
            } else {
              await _cameraController!.stopVideoRecording();
            }
          } catch (_) {}
        }
        return;
      }
      setState(() => _countdown = i);
      await Future.delayed(const Duration(seconds: 1));
    }

    if (!mounted) return;
    setState(() => _countdown = 0);

    // Hentikan rekam → simpan klip ke lokasi stabil.
    String? videoPath;
    if (recording) {
      try {
        if (_useEdsdk) {
          videoPath = await _edsdk!.stopClipAndEncode(await _newClipPath());
        } else if (_useCaptureCard) {
          videoPath = await _capture!.stopClipAndEncode(await _newClipPath());
        } else {
          final XFile vf = await _cameraController!.stopVideoRecording();
          videoPath = await _persistVideoClip(vf);
        }
      } catch (e) {
        debugPrint('[WARN] Stop rekam video gagal: $e');
      }
    }

    setState(() => _showBlink = true);
    await Future.delayed(const Duration(milliseconds: 120));
    if (mounted) setState(() => _showBlink = false);

    await _takePictureAndSave(videoPath);
    if (mounted) setState(() => _isCapturing = false);
  }

  // Path baru untuk klip video (dipakai jalur capture card yang encode
  // langsung ke folder stabil).
  Future<String> _newClipPath() async {
    final dir = await getApplicationDocumentsDirectory();
    final destDir = Directory('${dir.path}/PhotoboothVideos');
    if (!await destDir.exists()) await destDir.create(recursive: true);
    return '${destDir.path}/clip_${DateTime.now().millisecondsSinceEpoch}.mp4';
  }

  // Salin klip hasil rekaman ke folder stabil (XFile awal di temp).
  Future<String?> _persistVideoClip(XFile vf) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final destDir = Directory('${dir.path}/PhotoboothVideos');
      if (!await destDir.exists()) await destDir.create(recursive: true);
      final dest =
          '${destDir.path}/clip_${DateTime.now().millisecondsSinceEpoch}.mp4';
      await File(vf.path).copy(dest);
      debugPrint('[OK] Klip tersimpan: $dest');
      return dest;
    } catch (e) {
      debugPrint('[WARN] Simpan klip gagal: $e');
      return vf.path; // fallback ke path asli
    }
  }

  // ================================================================
  // AMBIL FOTO
  // ================================================================
  Future<void> _takePictureAndSave([String? videoPath]) async {
    try {
      Uint8List? raw;

      // 0) Prioritas tertinggi: shutter Canon via EDSDK. JPEG 18MP dikirim
      //    balik lewat pipe (bukan file), fokus sudah dikunci di awal sesi
      //    sehingga shutter tidak menunggu lensa hunting.
      if (_useEdsdk && _edsdk != null && _edsdk!.isRunning) {
        if (mounted) setState(() => _isDSLRProcessing = true);
        try {
          raw = await _edsdk!.takePicture();
        } catch (e) {
          debugPrint('[WARN] Shutter EDSDK gagal: $e');
        }
        if (mounted) setState(() => _isDSLRProcessing = false);
        if (raw != null) {
          debugPrint('[OK] Foto EDSDK (${raw.length} bytes) 18MP via tether.');
        } else {
          // Jangan gagalkan sesi: pakai frame live view terakhir sebagai
          // cadangan supaya slot foto tetap terisi.
          raw = _edsdk!.latestFrame;
          debugPrint(raw != null
              ? '[WARN] Shutter EDSDK kosong → pakai frame live view.'
              : '[WARN] Shutter EDSDK kosong dan tidak ada frame live view.');
        }
      }

      // 1) Prioritas: shutter DSLR via digiCamControl (18MP, bersih, tanpa
      //    overlay HDMI). Preview boleh dari capture card — jalur beda.
      if (raw == null && _dslrReady) {
        if (mounted) setState(() => _isDSLRProcessing = true);
        try {
          raw = await _dslrService.takePicture();
        } catch (e) {
          debugPrint('[WARN] Shutter DSLR gagal: $e');
        }
        if (mounted) setState(() => _isDSLRProcessing = false);
        if (raw != null) {
          debugPrint('[OK] Foto DSLR (${raw.length} bytes) via tether.');
        } else {
          debugPrint('[WARN] Shutter DSLR kosong → fallback.');
        }
      }

      // 2) Fallback: frame terakhir dari capture card.
      if (raw == null && _useCaptureCard) {
        raw = _capture?.latestFrame;
        if (raw != null) {
          debugPrint("[OK] Fallback frame capture card (${raw.length} bytes).");
        }
      }

      // 3) Fallback: webcam via camera_windows.
      if (raw == null &&
          _cameraController != null &&
          _cameraController!.value.isInitialized) {
        debugPrint("[OK] Fallback capture via webcam...");
        final XFile result = await _cameraController!.takePicture();
        raw = await result.readAsBytes();
      }

      if (raw == null) {
        debugPrint('[ERR] Tidak ada sumber foto yang tersedia.');
        return;
      }

      if (!mounted) return;
      final Uint8List imageBytes = raw;

      final provider = Provider.of<PhotoProvider>(context, listen: false);

      // Foto diambil RAW: hanya mirror + resize, TANPA color filter.
      // Filter dipilih & diterapkan nanti di PreviewPage dari bytes base ini.
      final swProc = Stopwatch()..start();
      final Uint8List base = await PhotoProcessor.makeBase(imageBytes);
      final msFilter = swProc.elapsedMilliseconds;

      final int photoIndex = provider.photos.length;
      await _savePhotoLocally(base, photoIndex, provider.sessionUuid);
      debugPrint('[TIMING] olah foto ${msFilter}ms, simpan '
          '${swProc.elapsedMilliseconds - msFilter}ms '
          '(${imageBytes.length ~/ 1024}KB → ${base.length ~/ 1024}KB)');
      _uploadPhotoToServer(
          base, photoIndex, provider.sessionUuid); // fire & forget
      provider.addPhoto(base, baseImageData: base, videoPath: videoPath);
    } catch (e) {
      debugPrint('[ERR] Error capture: $e');
    }
  }

  Future<void> _savePhotoLocally(
      Uint8List bytes, int index, String sessionId) async {
    try {
      final id = sessionId.isNotEmpty
          ? sessionId
          : "session_${DateTime.now().millisecondsSinceEpoch}";
      final dir = await getApplicationDocumentsDirectory();
      final sessionDir = Directory('${dir.path}/Photobooth/$id');
      if (!await sessionDir.exists()) await sessionDir.create(recursive: true);
      final file = File('${sessionDir.path}/photo_$index.jpg');
      await file.writeAsBytes(bytes);
      debugPrint("[OK] Tersimpan: ${file.path}");
    } catch (e) {
      debugPrint("[ERR] Gagal simpan: $e");
    }
  }

  Future<void> _uploadPhotoToServer(
      Uint8List bytes, int index, String sessionUuid) async {
    try {
      if (sessionUuid.isEmpty) return;
      final provider = Provider.of<PhotoProvider>(context, listen: false);
      if (provider.machineId.isEmpty) {
        await provider.initMachineId();
      }
      final hwid = provider.machineId;
      if (hwid.isEmpty) {
        debugPrint("[ERR] Upload foto dibatalkan: HWID kosong.");
        return;
      }
      debugPrint("[OK] Upload foto ${index + 1} ke server...");

      final tempDir = await getTemporaryDirectory();
      final tempFile = File(
          '${tempDir.path}/photo_${index}_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await tempFile.writeAsBytes(bytes);

      final uri = Uri.parse('$_backendUrl/api/photobooth/upload');
      final request = http.MultipartRequest('POST', uri)
        ..fields['session_uuid'] = sessionUuid
        ..fields['hwid'] = hwid
        ..fields['photo_order'] = (index + 1).toString()
        ..files.add(await http.MultipartFile.fromPath('photo', tempFile.path,
            contentType: MediaType('image', 'jpeg')));

      final streamed = await request.send();
      final response = await http.Response.fromStream(streamed);

      try {
        await tempFile.delete();
      } catch (_) {}

      if (response.statusCode == 200 || response.statusCode == 201) {
        debugPrint("[OK] Foto ${index + 1} terupload!");
      } else {
        debugPrint("[ERR] Upload foto ${index + 1} gagal: ${response.statusCode}");
        await _queuePhotoRetry(index, sessionUuid);
      }
    } catch (e) {
      debugPrint("[ERR] Upload foto error: $e");
      await _queuePhotoRetry(index, sessionUuid);
    }
  }

  /// Foto yang gagal dikirim tidak dibiarkan hilang: salinan permanennya
  /// (ditulis _savePhotoLocally sebelum upload) dimasukkan ke antrean supaya
  /// dicoba lagi sampai berhasil, bahkan setelah aplikasi ditutup.
  Future<void> _queuePhotoRetry(int index, String sessionUuid) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      await UploadQueueService.instance.enqueue(
        kind: UploadKind.photo,
        sessionUuid: sessionUuid,
        sourcePath: '${dir.path}/Photobooth/$sessionUuid/photo_$index.jpg',
        photoOrder: index + 1,
      );
    } catch (e) {
      debugPrint('[ERR] Gagal mengantre foto ${index + 1}: $e');
    }
  }

  // ================================================================
  // BACKGROUND RENDER & UPLOAD (fire & forget, tidak block UI)
  // ================================================================
  void _triggerBackgroundRender() {
    debugPrint("[OK] Trigger background render...");
    if (mounted) {
      setState(() {
        _isRendering = true;
        _renderDone = false;
      });
    }
    final provider = Provider.of<PhotoProvider>(context, listen: false);
    _renderAndUploadInBackground(provider);
  }

  Future<void> _renderAndUploadInBackground(PhotoProvider provider) async {
    try {
      debugPrint("[OK] Rendering frame result...");

      // Render RAW (tanpa filter) sebagai default cepat. Bila user memilih
      // filter di PreviewPage, hasil ini akan dirender ulang di sana.
      final pngBytes = await FrameComposer.compose(provider);
      debugPrint("[OK] PNG encode done: ${pngBytes.length} bytes");

      provider.setFinalImageBytes(pngBytes);
      await _uploadFinalResult(pngBytes, provider.sessionUuid);

      if (mounted) {
        setState(() {
          _isRendering = false;
          _renderDone = true;
        });
      }

      // Setelah foto selesai, susun video hasil di background (jika ada klip).
      _composeVideoInBackground(provider);
    } catch (e) {
      debugPrint("[ERR] Render error: $e");
      if (mounted) {
        setState(() {
          _isRendering = false;
        });
      }
    }
  }

  // ================================================================
  // KOMPOSIT VIDEO (fire & forget) — slot diisi klip + overlay frame.
  // Orkestrasi (compose bila perlu + upload) ada di VideoResultService.
  // ================================================================
  Future<void> _composeVideoInBackground(PhotoProvider provider) async {
    // GIF dirakit dari foto (bukan klip), jadi tidak perlu menunggu video
    // selesai — keduanya jalan berbarengan supaya total tunggu lebih pendek.
    final gif = GifResultService.ensure(provider);
    await VideoResultService.ensure(provider);
    await gif;
  }

  /// Upload hasil akhir. QR "Unduh Softfile" baru terbuka setelah ini berhasil,
  /// jadi kegagalan sesaat (WiFi venue) dicoba ulang beberapa kali dulu.
  Future<void> _uploadFinalResult(
      Uint8List pngBytes, String sessionUuid) async {
    const int maxAttempts = 3;
    final provider = Provider.of<PhotoProvider>(context, listen: false);

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      final ok = await _uploadFinalAttempt(pngBytes, sessionUuid, provider);
      if (ok) return;
      if (attempt < maxAttempts) {
        debugPrint("[..] Upload final gagal, ulangi ($attempt/$maxAttempts)...");
        await Future.delayed(Duration(seconds: 2 * attempt));
      }
    }

    debugPrint("[ERR] Upload final gagal setelah $maxAttempts percobaan.");
    provider.setFinalUploadFailed();
  }

  Future<bool> _uploadFinalAttempt(
      Uint8List pngBytes, String sessionUuid, PhotoProvider provider) async {
    try {
      if (provider.machineId.isEmpty) {
        await provider.initMachineId();
      }
      final hwid = provider.machineId;
      if (hwid.isEmpty) {
        debugPrint("Upload final dibatalkan: HWID kosong.");
        return false;
      }

      debugPrint("[OK] Mengupload hasil ke server...");

      final tempDir = await getTemporaryDirectory();
      final tempFile = File(
          '${tempDir.path}/result_${DateTime.now().millisecondsSinceEpoch}.png');
      await tempFile.writeAsBytes(pngBytes);

      final uri = Uri.parse('$_backendUrl/api/photobooth/upload/final');
      final request = http.MultipartRequest('POST', uri)
        ..fields['session_uuid'] = sessionUuid
        ..fields['hwid'] = hwid
        ..files.add(await http.MultipartFile.fromPath('photo', tempFile.path,
            contentType: MediaType('image', 'png')));

      final streamed = await request.send();
      final response = await http.Response.fromStream(streamed);

      if (response.statusCode == 200 || response.statusCode == 201) {
        try {
          await tempFile.delete();
        } catch (_) {}
        debugPrint("[OK] Upload berhasil!");
        // Tandai supaya QR di PreviewPrintPage boleh dipindai.
        String? resultUrl;
        try {
          resultUrl = jsonDecode(response.body)['url'] as String?;
        } catch (_) {}
        provider.setFinalUploaded(resultUrl);
        return true;
      }

      debugPrint("[ERR] Upload gagal: ${response.statusCode} - ${response.body}");
      // Strip final adalah hasil yang dibayar pelanggan — antre sebelum
      // berkas sementaranya dihapus, jangan sampai hilang.
      await UploadQueueService.instance.enqueue(
        kind: UploadKind.finalStrip,
        sessionUuid: sessionUuid,
        sourcePath: tempFile.path,
      );
      try {
        await tempFile.delete();
      } catch (_) {}
      return false;
    } catch (e) {
      debugPrint("[ERR] Upload error: $e");
      return false;
    }
  }

  // ================================================================
  // NAVIGASI (render tetap jalan di background)
  // ================================================================
  void _onNextPressed() {
    final provider = Provider.of<PhotoProvider>(context, listen: false);

    // Kamera sudah bebas mulai detik ini — sisa sesi hanya memilih filter,
    // membayar, dan mencetak. Kabari server supaya orang berikutnya di antrean
    // mulai berjalan kembali ke booth sekarang, bukan nanti saat gilirannya
    // benar-benar tiba; itu yang menghapus waktu booth menganggur.
    //
    // Sengaja tanpa await: pemberitahuan antrean tidak boleh menahan navigasi
    // pelanggan yang sedang berdiri di depan layar.
    if (QueueService.instance.aktif != null) {
      QueueService.instance.preCall(provider.machineId);
    }

    if (provider.selectedMode == FrameMode.static) {
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => const PreviewPage()));
    } else {
      Navigator.pushReplacement(context,
          MaterialPageRoute(builder: (_) => const CustomizationPage()));
    }
  }

  // ================================================================
  // BUILD
  // ================================================================
  @override
  Widget build(BuildContext context) {
    final provider = context.watch<PhotoProvider>();
    final int total = provider.targetPhotoCount;
    final int done = provider.photos.length;
    final bool complete = provider.isComplete;
    final bool showBack = !_isSessionActive && done == 0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. CAMERA PREVIEW (full-screen). Tanpa color filter — filter
          //    dipilih nanti di PreviewPage, foto diambil RAW.
          if (_useEdsdk && _edsdk != null)
            SizedBox.expand(
              // Mirror (selfie) agar konsisten dengan foto yang di-mirror.
              child: Transform.scale(
                scaleX: -1,
                child: StreamBuilder<Uint8List>(
                  stream: _edsdk!.frames,
                  builder: (_, snap) {
                    final Uint8List? data = snap.data ?? _edsdk!.latestFrame;
                    if (data == null) return const SizedBox.expand();
                    return Image.memory(
                      data,
                      gaplessPlayback: true,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                    );
                  },
                ),
              ),
            )
          else if (_useCaptureCard && _capture != null)
            SizedBox.expand(
              // Mirror (selfie) agar konsisten dengan foto yang di-mirror.
              child: Transform.scale(
                scaleX: -1,
                child: StreamBuilder<Uint8List>(
                  stream: _capture!.frames,
                  builder: (_, snap) {
                    final Uint8List? data = snap.data ?? _capture!.latestFrame;
                    if (data == null) return const SizedBox.expand();
                    return Image.memory(
                      data,
                      gaplessPlayback: true,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                    );
                  },
                ),
              ),
            )
          else if (_cameraController != null &&
              _cameraController!.value.isInitialized)
            SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _cameraController!.value.previewSize?.width ?? 1,
                  height: _cameraController!.value.previewSize?.height ?? 1,
                  child: CameraPreview(_cameraController!),
                ),
              ),
            )
          else
            const SizedBox(),

          // Loading overlay kamera belum siap
          if (!_isCameraInitialized)
            Container(
              color: Colors.black87,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: Colors.white),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 60),
                      child: Text(
                        _debugMessage.isEmpty
                            ? "Memuat kamera..."
                            : _debugMessage,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            height: 1.5),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    // Operator perlu tahu app masih berusaha sendiri, supaya
                    // tidak buru-buru me-restart aplikasi.
                    if (_retryTimer != null) ...[
                      const SizedBox(height: 12),
                      const Text(
                        "Mencoba menyambung ulang otomatis…",
                        style: TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                    ],
                  ],
                ),
              ),
            ),

          // 2. OVERLAY INTERFACE (transparent PNG dekoratif)
          Positioned.fill(
            child: IgnorePointer(
              child: Image.asset("assets/images/gifoverlay.png",
                  fit: BoxFit.cover),
            ),
          ),

          // 3. TAG KERTAS-CAM (dekorasi kanan, posisi seperti interface_1.png:
          //    menempel kanan, tinggi penuh layar). Berada di belakang preview.
          Positioned(
            top: -20, // geser ke atas 5px
            bottom: 20,
            right: -20, // geser ke kanan 5px
            child: IgnorePointer(
              child: _scrapbookHide(
                Image.asset(
                  "assets/images/KERTAS-CAM.png",
                  fit: BoxFit.fitHeight,
                  alignment: Alignment.centerRight,
                  filterQuality: FilterQuality.high, // upscale lebih halus
                ),
                tilt: 0.02,
              ),
            ),
          ),

          // 4. PREVIEW FRAME (kanan / kertas)
          _buildFramePreview(provider, total, done, complete),

          // 5. COUNTDOWN
          if (_countdown > 0)
            Container(
              color: Colors.black54,
              child: Center(
                child: TweenAnimationBuilder<double>(
                  key: ValueKey(_countdown),
                  tween: Tween(begin: 1.3, end: 1.0),
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.elasticOut,
                  builder: (_, scale, child) =>
                      Transform.scale(scale: scale, child: child),
                  child: Text(
                    '$_countdown',
                    style: const TextStyle(
                      fontFamily: 'Quicksand',
                      fontSize: 260,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      shadows: [
                        Shadow(offset: Offset(4, 4), color: Colors.black)
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // 6. BLINK FLASH
          if (_showBlink) Container(color: Colors.white),

          // 6.5 DSLR PROCESSING OVERLAY
          if (_isDSLRProcessing)
            Container(
              color: Colors.black.withValues(alpha: 0.7),
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 20),
                    Text(
                      "Processing High Quality Photo...",
                      style: TextStyle(
                        fontFamily: 'Ambitsek',
                        color: Colors.white,
                        fontSize: 24,
                        letterSpacing: 1.2,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      "Please wait, transferring data from camera",
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),

          // 7. BOTTOM CONTROLS (center di area kamera)
          Positioned(
            left: 0,
            right: _framePreviewReserved,
            bottom: 40,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (complete && !_isSessionActive)
                  StartButton(onPressed: _onNextPressed, label: "Cek Hasil"),
              ],
            ),
          ),

          // 7.5 PROMPT MULAI (teks tengah layar)
          if (!complete &&
              _countdown == 0 &&
              !_isCapturing &&
              (!_isSessionActive || _isWaitingForManualStart))
            Positioned.fill(
              child: Center(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap:
                      _isSessionActive ? _proceedToCapture : _initializeSession,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: 40, vertical: 24),
                    child: Text(
                      "Tekan Untuk Mulai",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Quicksand',
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        fontSize: 54,
                        letterSpacing: 1.5,
                        shadows: [
                          Shadow(
                              offset: Offset(0, 3),
                              blurRadius: 12,
                              color: Colors.black87),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // 8. BACK BUTTON
          if (showBack)
            Positioned(
              bottom: 40,
              left: 28,
              child: BackPillButton(onPressed: () => Navigator.pop(context)),
            ),

          // 9. TOGGLE HIDE (ikon dropdown + circle bg) di bagian KIRI tag.
          //    Hanya tampil saat panel sedang ditampilkan.
          if (!_rightPanelHidden)
            Positioned(
              top: -20,
              bottom: 20,
              right: -20,
              width: MediaQuery.of(context).size.height * 0.5,
              child: Align(
                // x: -1 = mepet kiri, +1 = kanan. y: -1 = atas, +1 = bawah.
                alignment: const Alignment(-0.6, -0.56),
                child: Transform.rotate(
                  angle: 2 * _deg2rad, // miring ~2° ke kanan
                  child: _PanelToggleIcon(
                    hidden: _rightPanelHidden,
                    onPressed: () =>
                        setState(() => _rightPanelHidden = !_rightPanelHidden),
                  ),
                ),
              ),
            ),

          // 10. HANDLE UNHIDE — tab setengah-rounded di tepi kanan, tengah
          //     vertikal. Hanya tampil saat panel tersembunyi.
          if (_rightPanelHidden)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: Center(
                child: _UnhideHandle(
                  onPressed: () =>
                      setState(() => _rightPanelHidden = !_rightPanelHidden),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ================================================================
  // ANIMASI SCRAPBOOK — membungkus elemen kanan (tag + preview) agar
  // tergeser keluar ke kanan + miring + memudar saat disembunyikan,
  // dan menyelip kembali dengan sedikit "settle" saat ditampilkan.
  // ================================================================
  Widget _scrapbookHide(Widget child, {double tilt = 0.035}) {
    final bool hidden = _rightPanelHidden;
    const Duration dur = Duration(milliseconds: 620);
    final Curve curve = hidden ? Curves.easeInBack : Curves.easeOutBack;
    return IgnorePointer(
      ignoring: hidden,
      child: AnimatedSlide(
        duration: dur,
        curve: curve,
        offset: hidden ? const Offset(1.3, 0.06) : Offset.zero,
        child: AnimatedRotation(
          duration: dur,
          curve: curve,
          turns: hidden ? tilt : 0.0,
          child: AnimatedScale(
            duration: dur,
            curve: curve,
            scale: hidden ? 0.92 : 1.0,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 420),
              opacity: hidden ? 0.0 : 1.0,
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  // ================================================================
  // PREVIEW FRAME (kanan / kertas) - render frame terpilih + slot,
  // terisi foto saat di-take dengan animasi.
  // ================================================================
  Widget _buildFramePreview(
      PhotoProvider provider, int total, int done, bool complete) {
    final double frameW = provider.selectedFrameWidth;
    final double frameH = provider.selectedFrameHeight;
    final double screenH = MediaQuery.of(context).size.height;

    // Dulu: (screenH * 0.60).clamp(240, 460) — batas atas 460px itu yang
    // membuat kartu berhenti tumbuh di layar tinggi, sementara tag terus
    // membesar. Sekarang murni proporsional.
    final double boxH = screenH * _kCardHeightRatio;
    final double boxW = boxH * (frameW / frameH);

    // Pusatkan kartu tepat di tengah tag, berapa pun ukuran layarnya.
    // Tag melebar ke kanan sampai (_kTagRightOverhang) di luar layar, jadi
    // titik tengahnya berjarak (tagW/2 - overhang) dari tepi kanan.
    final double tagW = screenH * _kTagAspect;
    final double cardOuterW = boxW + _kCardPadding * 2;
    final double rightInset =
        (tagW / 2) - (cardOuterW / 2) - _kTagRightOverhang;

    return Positioned(
      right: rightInset,
      top: 0,
      bottom: 0,
      child: Center(
        child: _scrapbookHide(
          Transform.translate(
          offset: Offset(0, screenH * _kCardVerticalShift),
          child: Transform.rotate(
            angle: 2 * _deg2rad,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // pushpin
              Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [Color(0xFFF87171), Color(0xFFC0322F)],
                    center: Alignment(-0.3, -0.3),
                  ),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black45,
                        blurRadius: 6,
                        offset: Offset(1, 3)),
                  ],
                ),
              ),
              Transform.translate(
                offset: const Offset(0, -2),
                child: Container(
                  padding: const EdgeInsets.all(_kCardPadding),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFDF6),
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: const [
                      BoxShadow(
                          color: Colors.black45,
                          blurRadius: 16,
                          offset: Offset(0, 9)),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child:
                            _buildFrameBox(provider, boxW, boxH, done, complete),
                      ),
                      const SizedBox(height: 6),
                      _buildFrameStatus(done, total, complete),
                    ],
                  ),
                ),
              ),
            ],
          ),
          ),
        ),
        ), // tutup _scrapbookHide
      ),
    );
  }

  // Status kecil di bawah preview: progress / render / upload / retake.
  Widget _buildFrameStatus(int done, int total, bool complete) {
    late final IconData icon;
    late final Color color;
    late final String label;

    if (_isRendering) {
      icon = Icons.autorenew_rounded;
      color = const Color(0xFFD98C5F);
      label = 'Merangkai frame...';
    } else if (_renderDone) {
      icon = Icons.cloud_done_rounded;
      color = const Color(0xFF4E9A5B);
      label = _retakeCount > 0 ? 'Tersimpan (retake $_retakeCount×)' : 'Tersimpan';
    } else if (complete) {
      icon = Icons.touch_app_rounded;
      color = const Color(0xFF8A6A52);
      label = 'Tap foto untuk retake';
    } else {
      // Counting foto di-hapus: tidak menampilkan apa-apa saat sesi berjalan.
      return const SizedBox.shrink();
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            fontFamily: 'Ambitsek',
            color: color,
            fontSize: 13,
            letterSpacing: 1,
          ),
        ),
      ],
    );
  }

  Widget _buildFrameBox(
      PhotoProvider provider, double w, double h, int done, bool complete) {
    final List<Widget> slotWidgets = provider.hasCustomSlots
        ? _buildCustomSlots(provider, w, h, done, complete)
        : _buildFallbackSlots(provider, w, h, done, complete);

    return SizedBox(
      width: w,
      height: h,
      child: Stack(
        children: [
          Positioned.fill(child: Container(color: Colors.white)),
          ...slotWidgets,
          if (provider.selectedFrameAsset != null)
            Positioned.fill(
              child: IgnorePointer(
                child: _frameImage(provider.selectedFrameAsset!, BoxFit.fill),
              ),
            ),
        ],
      ),
    );
  }

  Widget _frameImage(String path, BoxFit fit) {
    if (path.startsWith('http')) {
      return Image.network(path,
          fit: fit, errorBuilder: (_, __, ___) => const SizedBox());
    }
    return Image.asset(path,
        fit: fit, errorBuilder: (_, __, ___) => const SizedBox());
  }

  List<Widget> _buildCustomSlots(
      PhotoProvider provider, double w, double h, int done, bool complete) {
    final double sx = w / provider.selectedFrameWidth;
    final double sy = h / provider.selectedFrameHeight;
    // Clamp photoIndex ke jumlah foto yang ADA — persis seperti FrameComposer
    // (yang meng-clamp ke decodedPhotos.length - 1). Ini menangani frame yang
    // slot-nya pakai photo_index 1-based atau melebihi jumlah foto.
    final int photoCount = provider.photos.length;
    final int maxIdx = photoCount > 0 ? photoCount - 1 : 0;
    return provider.photoSlots.map((slot) {
      final int pidx = slot.photoIndex.clamp(0, maxIdx);
      // Saat sesi selesai, isi SEMUA slot sama persis dengan hasil akhir
      // (FrameComposer menggambar tiap slot tanpa syarat). Saat sesi masih
      // berjalan, slot hanya terisi bila fotonya memang sudah diambil.
      final bool hasPhoto =
          complete ? photoCount > 0 : (slot.photoIndex < done);
      final bool active = _isSessionActive && slot.photoIndex == done;
      return Positioned(
        left: slot.x * sx,
        top: slot.y * sy,
        width: slot.width * sx,
        height: slot.height * sy,
        child: Transform.rotate(
          angle: slot.rotation * _deg2rad,
          child: _slotContent(
            provider: provider,
            photoIndex: pidx,
            hasPhoto: hasPhoto,
            active: active,
            complete: complete,
            tag: slot.id,
          ),
        ),
      );
    }).toList();
  }

  List<Widget> _buildFallbackSlots(
      PhotoProvider provider, double w, double h, int done, bool complete) {
    final int count = provider.targetPhotoCount;
    final int cols = count == 3 ? 1 : 2;
    final int rows = (count / cols).ceil();
    final layout = provider.selectedLayout;
    final double sx = w / provider.selectedFrameWidth;
    final double sy = h / provider.selectedFrameHeight;

    final double lTop = layout.topPadding * sy;
    final double lBottom = layout.bottomPadding * sy;
    final double lLeft = layout.leftPadding * sx;
    final double lRight = layout.rightPadding * sx;
    final double lH = layout.horizontalSpacing * sx;
    final double lV = layout.verticalSpacing * sy;

    final double paddedW = w - lLeft - lRight;
    final double paddedH = h - lTop - lBottom;
    final double cellW = (paddedW - (cols - 1) * lH) / cols;
    final double cellH = (paddedH - (rows - 1) * lV) / rows;

    final List<Widget> out = [];
    for (int i = 0; i < count; i++) {
      final int col = i % cols;
      final int row = i ~/ cols;
      final double dx = lLeft + col * (cellW + lH);
      final double dy = lTop + row * (cellH + lV);
      final bool hasPhoto = i < done;
      final bool active = _isSessionActive && i == done;
      out.add(Positioned(
        left: dx,
        top: dy,
        width: cellW,
        height: cellH,
        child: _slotContent(
          provider: provider,
          photoIndex: i,
          hasPhoto: hasPhoto,
          active: active,
          complete: complete,
          tag: 1000 + i,
        ),
      ));
    }
    return out;
  }

  // Satu slot foto, dengan AnimatedSwitcher untuk efek "foto masuk ke frame".
  Widget _slotContent({
    required PhotoProvider provider,
    required int photoIndex,
    required bool hasPhoto,
    required bool active,
    required bool complete,
    required int tag,
  }) {
    final bool canRetake = hasPhoto && complete && !_isSessionActive;

    final Widget child = hasPhoto
        ? Container(
            key: ValueKey('photo_$tag'),
            decoration: BoxDecoration(
              image: DecorationImage(
                image: MemoryImage(provider.photos[photoIndex].imageData),
                fit: BoxFit.cover,
              ),
            ),
            child: canRetake
                ? Align(
                    alignment: Alignment.bottomRight,
                    child: Container(
                      margin: const EdgeInsets.all(3),
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                        color: Color(0xFFEF4444),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.refresh,
                          size: 12, color: Colors.white),
                    ),
                  )
                : null,
          )
        : Container(
            key: ValueKey('empty_$tag'),
            decoration: BoxDecoration(
              color: active
                  ? const Color(0xFFFFD84D).withValues(alpha: 0.22)
                  : Colors.black.withValues(alpha: 0.05),
              border: active
                  ? Border.all(color: const Color(0xFFE5484D), width: 2)
                  : null,
            ),
            child: Center(
              child: active && _isCapturing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Color(0xFFE5484D)),
                    )
                  : Icon(Icons.camera_alt,
                      size: 16,
                      color:
                          active ? const Color(0xFFE5484D) : Colors.black26),
            ),
          );

    return GestureDetector(
      onTap: canRetake ? () => _retakeSpecificPhoto(photoIndex) : null,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 480),
        switchInCurve: Curves.easeOutBack,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 1.25, end: 1.0).animate(anim),
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, -0.25),
                end: Offset.zero,
              ).animate(anim),
              child: child,
            ),
          ),
        ),
        child: child,
      ),
    );
  }
}

// Tombol "lanjut" memakai widget StartButton dari splash_screen.dart
// (lihat penggunaannya di bottom controls) agar konsisten dengan tombol start.

// ================================================================
// WIDGET: BACK BUTTON (gaya konsisten dengan StartButton, panah di kiri)
// ================================================================
class BackPillButton extends StatefulWidget {
  final VoidCallback onPressed;
  final String label;
  const BackPillButton({super.key, required this.onPressed, this.label = "kembali"});

  @override
  State<BackPillButton> createState() => _BackPillButtonState();
}

class _BackPillButtonState extends State<BackPillButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final double scale = _pressed ? 0.96 : (_hover ? 1.06 : 1.0);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onPressed();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: scale,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: _hover
                    ? const [Color(0xFFD0452F), Color(0xFFB23320)]
                    : const [Color(0xFFC23A2A), Color(0xFFA62D1D)],
              ),
              borderRadius: BorderRadius.circular(40),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: _hover ? 16 : 10,
                  offset: Offset(0, _hover ? 7 : 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSlide(
                  offset: _hover ? const Offset(-0.22, 0) : Offset.zero,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  child: const Icon(
                    Icons.arrow_back_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  widget.label,
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ================================================================
// WIDGET: TOGGLE (ikon dropdown + lingkaran) untuk sembunyikan/
// tampilkan panel kanan. Diletakkan di bagian kiri tag KERTAS-CAM.
// ================================================================
class _PanelToggleIcon extends StatefulWidget {
  final bool hidden;
  final VoidCallback onPressed;
  const _PanelToggleIcon({required this.hidden, required this.onPressed});

  @override
  State<_PanelToggleIcon> createState() => _PanelToggleIconState();
}

class _PanelToggleIconState extends State<_PanelToggleIcon> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final double scale = _pressed ? 0.92 : (_hover ? 1.08 : 1.0);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onPressed();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: scale,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF7A4636), // lingkaran coklat
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: _hover ? 12 : 7,
                  offset: Offset(0, _hover ? 5 : 3),
                ),
              ],
            ),
            child: AnimatedRotation(
              // berputar 180° saat tersembunyi sebagai indikasi buka/tutup
              turns: widget.hidden ? 0.5 : 0.0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              child: const Icon(
                Icons.expand_more_rounded,
                color: Color(0xFFFCE9CE),
                size: 28,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ================================================================
// WIDGET: HANDLE UNHIDE — tab setengah-rounded menempel di tepi kanan
// (sudut kiri membulat, sisi kanan rata tepi layar), ikon "<".
// ================================================================
class _UnhideHandle extends StatefulWidget {
  final VoidCallback onPressed;
  const _UnhideHandle({required this.onPressed});

  @override
  State<_UnhideHandle> createState() => _UnhideHandleState();
}

class _UnhideHandleState extends State<_UnhideHandle> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final double w = _pressed ? 34 : (_hover ? 42 : 38);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onPressed();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          width: w,
          height: 92,
          decoration: const BoxDecoration(
            color: Color(0xFF7A4636),
            // setengah-rounded: hanya sudut kiri yang membulat
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(20),
              bottomLeft: Radius.circular(20),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black45,
                blurRadius: 12,
                offset: Offset(-3, 4),
              ),
            ],
          ),
          child: const Center(
            child: Icon(
              Icons.chevron_left_rounded,
              color: Color(0xFFFCE9CE),
              size: 30,
            ),
          ),
        ),
      ),
    );
  }
}
