import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart'; 
import '../services/license_service.dart';

// ==========================================
// 1. ENUMS
// ==========================================
enum PhotoFilter { none, vintage, grayscale, smooth, brightness }
enum FrameShape { rectangle, circle, love }
enum FrameMode { static, custom }
enum CustomLayout { vertical, grid } 

// ==========================================
// 2. DATA MODELS
// ==========================================

class PhotoData {
  // imageData = bytes yang ditampilkan/dipakai (sudah terfilter bila ada filter).
  Uint8List imageData;
  // baseImageData = bytes mentah (RAW, sudah ter-mirror, TANPA color filter).
  // Dipakai untuk menerapkan ulang filter dari preview tanpa kehilangan kualitas.
  final Uint8List baseImageData;
  final PhotoFilter filter;
  // Path klip video (.mp4) yang direkam selama countdown 5 detik foto ini.
  final String? videoPath;
  PhotoData({
    required this.imageData,
    Uint8List? baseImageData,
    required this.filter,
    this.videoPath,
  }) : baseImageData = baseImageData ?? imageData;
}

class StickerData {
  String assetPath;
  Offset position;
  double size;
  double rotation;
  StickerData({
    required this.assetPath,
    this.position = const Offset(50, 50),
    this.size = 100,
    this.rotation = 0,
  });
}

class FrameLayout {
  final double topPadding;
  final double bottomPadding;
  final double leftPadding;
  final double rightPadding;
  final double horizontalSpacing;
  final double verticalSpacing;
  final double childAspectRatio;

  const FrameLayout({
    this.topPadding = 0,
    this.bottomPadding = 0,
    this.leftPadding = 0,
    this.rightPadding = 0,
    this.horizontalSpacing = 10,
    this.verticalSpacing = 10,
    this.childAspectRatio = 1.0, 
  });
}

class PhotoSlot {
  final int id;
  final double x;
  final double y;
  final double width;
  final double height;
  final double rotation;
  final int photoIndex;

  const PhotoSlot({
    required this.id,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.rotation = 0,
    this.photoIndex = 0,
  });

  factory PhotoSlot.fromJson(Map<String, dynamic> json) {
    return PhotoSlot(
      id:         (json['id']          as num).toInt(),
      x:          (json['x']           as num).toDouble(),
      y:          (json['y']           as num).toDouble(),
      width:      (json['width']       as num).toDouble(),
      height:     (json['height']      as num).toDouble(),
      rotation:   (json['rotation']    as num? ?? 0).toDouble(),
      photoIndex: (json['photo_index'] as num? ?? 0).toInt(),
    );
  }
}

// ==========================================
// 3. MAIN PROVIDER CLASS
// ==========================================
class PhotoProvider extends ChangeNotifier {

  // --- A. SESSION & TIMER MANAGEMENT ---
  Timer? _sessionTimer;
  int _remainingTime   = 0;
  bool _isSessionActive = false;

  // ── BARU: durasi dari API, di-set saat fetch /api/frames ──
  int _sessionDurationMin = 5; // fallback default (was 30)

  // ── BARU: callback dipanggil saat timer habis ──
  // Di-assign oleh root widget (mis. SplashScreen atau MaterialApp wrapper)
  VoidCallback? onSessionExpired;

  int  get remainingTime      => _remainingTime;
  int  get remainingSeconds   => _remainingTime; // alias untuk SessionTimerOverlay
  bool get isSessionActive    => _isSessionActive;
  int  get sessionDurationMin => _sessionDurationMin;

  // ── BARU: progress 1.0 (penuh) → 0.0 (habis), untuk progress bar ──
  double get timerProgress {
    final total = _sessionDurationMin * 60;
    if (total <= 0) return 0;
    return (_remainingTime / total).clamp(0.0, 1.0);
  }

  // ── BARU: warna otomatis hijau → kuning → merah ──
  Color get timerColor {
    if (timerProgress > 0.5) return const Color(0xFF34d399); // hijau
    if (timerProgress > 0.2) return const Color(0xFFfbbf24); // kuning
    return const Color(0xFFf87171);                           // merah
  }

  String get timerString {
    final minutes = (_remainingTime / 60).floor().toString().padLeft(2, '0');
    final seconds = (_remainingTime % 60).toString().padLeft(2, '0');
    return "$minutes:$seconds";
  }

  // ── BARU: dipanggil saat response /api/frames diterima ──
  void setSessionDuration(int minutes) {
    _sessionDurationMin = minutes <= 0 ? 5 : minutes;
    debugPrint('⏱ Session duration set from config: $_sessionDurationMin menit');
  }

  String _sessionUuid = ''; 
  String get sessionUuid => _sessionUuid;

  String _machineId = '';
  String get machineId => _machineId;

  Future<void> initMachineId() async {
    if (_machineId.isEmpty) {
      try {
        _machineId = await LicenseService().getHardwareId();
        notifyListeners();
        debugPrint("Machine ID Loaded: $_machineId");
      } catch (e) {
        debugPrint("Gagal Load Machine ID: $e");
      }
    }
  }

  void setSessionUuid(String uuid) {
    _sessionUuid = uuid;
    notifyListeners();
  }

  void removePhotoAt(int index) {
    if (index >= 0 && index < _photos.length) {
      _photos.removeAt(index);
      notifyListeners();
    }
  }

  // ── startSession: gunakan durasi hasil bootstrap/config ──
  void startSession() {
    _sessionTimer?.cancel();
    _remainingTime      = _sessionDurationMin * 60; 
    _isSessionActive    = true;
    notifyListeners();

    debugPrint('⏱ Timer dimulai: $_sessionDurationMin menit ($_remainingTime detik)');

    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remainingTime > 0) {
        _remainingTime--;
        notifyListeners();
      } else {
        debugPrint('⏱ Timer habis! Memanggil onSessionExpired...');
        timer.cancel();
        _isSessionActive = false;
        notifyListeners();
        // ── panggil callback → screen navigasi ke SplashScreen ──
        onSessionExpired?.call();
      }
    });
  }

  void stopSession() {
    _sessionTimer?.cancel();
    _isSessionActive = false;
    _remainingTime   = 0;
    notifyListeners();
  }

  Uint8List? _finalImageBytes;
  Uint8List? get finalImageBytes => _finalImageBytes;

  String? _finalFramePath;
  String? get finalFramePath => _finalFramePath;

  /// Hasil akhir sudah benar-benar tersimpan di server.
  /// Render & upload berjalan di latar belakang dari CameraPage, sementara
  /// halaman QR bisa terbuka lebih dulu — flag ini yang mencegah pelanggan
  /// memindai QR ke halaman unduh yang masih kosong.
  bool _finalUploaded = false;
  bool get finalUploaded => _finalUploaded;

  String? _finalResultUrl;
  String? get finalResultUrl => _finalResultUrl;

  /// Upload sudah dicoba sampai habis dan tetap gagal. Dipakai supaya panel QR
  /// menampilkan pesan jujur, bukan spinner yang berputar selamanya.
  bool _finalUploadFailed = false;
  bool get finalUploadFailed => _finalUploadFailed;

  void setFinalUploaded(String? url) {
    _finalUploaded = true;
    _finalUploadFailed = false;
    _finalResultUrl = url;
    notifyListeners();
  }

  void setFinalUploadFailed() {
    if (_finalUploaded) return; // sudah pernah berhasil, abaikan
    _finalUploadFailed = true;
    notifyListeners();
  }

  void setFinalImageBytes(Uint8List bytes) {
    _finalImageBytes = bytes;
    notifyListeners();
  }

  void setFinalFrame(String path) {
    _finalFramePath = path;
    notifyListeners();
  }

  // --- B. FRAME CONFIGURATION STATE ---
  FrameMode _selectedMode = FrameMode.static;
  CustomLayout _customLayout = CustomLayout.vertical; 
  int _targetPhotoCount = 3; 
  String? _selectedFrameAsset;
  FrameLayout _selectedLayout = const FrameLayout();
  double? _selectedFrameWidth;
  double? _selectedFrameHeight;

  List<PhotoSlot> _photoSlots = [];

  FrameMode get selectedMode => _selectedMode;
  CustomLayout get customLayout => _customLayout;
  int get targetPhotoCount => _targetPhotoCount;
  String? get selectedFrameAsset => _selectedFrameAsset;
  FrameLayout get selectedLayout => _selectedLayout;
  double get selectedFrameWidth  => _selectedFrameWidth  ?? 344.0;
  double get selectedFrameHeight => _selectedFrameHeight ?? 515.0;

  List<PhotoSlot> get photoSlots => _photoSlots;
  bool get hasCustomSlots => _photoSlots.isNotEmpty;

  void setFrameMode(
    FrameMode mode, {
    int photoCount = 3, 
    String? frameAsset,
    FrameLayout? layout,
    double? customWidth,
    double? customHeight,
  }) {
    _selectedMode        = mode;
    _selectedFrameAsset  = frameAsset;
    _selectedLayout      = layout ?? const FrameLayout();
    _selectedFrameWidth  = customWidth;
    _selectedFrameHeight = customHeight;
    _photoSlots          = [];
    if (mode == FrameMode.custom) {
      _targetPhotoCount = 4; 
    } else {
      _targetPhotoCount = photoCount;
    }
    notifyListeners();
  }

  void setFrameModeWithSlots(
    FrameMode mode, {
    required int photoCount,
    required String frameAsset,
    required List<PhotoSlot> photoSlots,
    double? customWidth,
    double? customHeight,
  }) {
    _selectedMode        = mode;
    _selectedFrameAsset  = frameAsset;
    _selectedLayout      = const FrameLayout();
    _selectedFrameWidth  = customWidth;
    _selectedFrameHeight = customHeight;
    _photoSlots          = photoSlots;
    _targetPhotoCount    = photoCount;
    notifyListeners();
  }

  void setCustomLayout(CustomLayout layout) {
    _customLayout = layout;
    notifyListeners();
  }

  // --- C. PHOTO DATA MANAGEMENT ---
  final List<PhotoData> _photos = [];
  PhotoFilter _selectedFilter = PhotoFilter.none;

  List<PhotoData> get photos => _photos;
  int get photoCount => _photos.length;
  bool get isComplete => _photos.length >= _targetPhotoCount;
  PhotoFilter get selectedFilter => _selectedFilter;

  void addPhoto(Uint8List imageData,
      {Uint8List? baseImageData, String? videoPath}) {
    if (_photos.length < _targetPhotoCount) {
      _photos.add(PhotoData(
        imageData: imageData,
        baseImageData: baseImageData,
        filter: _selectedFilter,
        videoPath: videoPath,
      ));
      notifyListeners();
    }
  }

  // Apakah semua foto punya klip video (untuk kompositkan video hasil).
  bool get hasAllVideoClips =>
      _photos.isNotEmpty &&
      _photos.every((p) => p.videoPath != null && p.videoPath!.isNotEmpty);

  // Hasil video komposit (slot diisi klip + overlay frame), path file lokal.
  String? _finalVideoPath;
  String? get finalVideoPath => _finalVideoPath;
  // Filter yang dipakai saat _finalVideoPath dibuat (untuk deteksi stale).
  PhotoFilter? _finalVideoFilter;
  PhotoFilter? get finalVideoFilter => _finalVideoFilter;

  void setFinalVideoPath(String? path) {
    _finalVideoPath = path;
    notifyListeners();
  }

  void setFinalVideo(String? path, PhotoFilter? filter) {
    _finalVideoPath = path;
    _finalVideoFilter = filter;
    notifyListeners();
  }

  // Penanda agar komposit video tidak berjalan dobel (camera vs preview).
  bool _videoProcessing = false;
  bool get videoProcessing => _videoProcessing;
  void setVideoProcessing(bool v) {
    _videoProcessing = v;
    notifyListeners();
  }

  // ── GIF hasil sesi ────────────────────────────────────────────────
  // GIF dirakit dari foto-foto sesi (bukan klip video), jadi bisa dibuat
  // walau perekaman video gagal — cukup ada minimal 2 foto.
  bool get canBuildGif => _photos.length >= 2;

  String? _finalGifPath;
  String? get finalGifPath => _finalGifPath;

  // Filter saat GIF dibuat, untuk deteksi hasil basi ketika user ganti filter.
  PhotoFilter? _finalGifFilter;
  PhotoFilter? get finalGifFilter => _finalGifFilter;

  void setFinalGif(String? path, PhotoFilter? filter) {
    _finalGifPath = path;
    _finalGifFilter = filter;
    notifyListeners();
  }

  bool _gifProcessing = false;
  bool get gifProcessing => _gifProcessing;
  void setGifProcessing(bool v) {
    _gifProcessing = v;
    notifyListeners();
  }

  void addPhotoPath(String path) {}

  void setSelectedFilter(PhotoFilter filter) {
    _selectedFilter = filter;
    notifyListeners();
  }

  // Ganti bytes terfilter untuk satu foto (hasil re-apply filter dari base).
  void updatePhotoImage(int index, Uint8List data) {
    if (index >= 0 && index < _photos.length) {
      _photos[index].imageData = data;
      notifyListeners();
    }
  }

  void clearPhotos() {
    _photos.clear();
    _selectedFilter = PhotoFilter.none;
    notifyListeners();
  }

  // --- D. CUSTOMIZATION STATE ---
  Color _frameColor = Colors.blue;
  String? _frameTexture;
  FrameShape _frameShape = FrameShape.rectangle;
  Color _frameContainerColor = Colors.white;
  String? _frameContainerTexture;
  final List<StickerData> _stickers = [];
  String _headlineText = '';
  double _textSize = 28;
  double _textRotation = 0;
  Offset _textPosition = const Offset(0, 0);

  Color get frameColor => _frameColor;
  String? get frameTexture => _frameTexture;
  FrameShape get frameShape => _frameShape;
  Color get frameContainerColor => _frameContainerColor;
  String? get frameContainerTexture => _frameContainerTexture;
  List<StickerData> get stickers => _stickers;
  String get headlineText => _headlineText;
  double get textSize => _textSize;
  double get textRotation => _textRotation;
  Offset get textPosition => _textPosition;

  void setFrameColor(Color color)                 { _frameColor = color; _frameTexture = null; notifyListeners(); }
  void setFrameTexture(String texturePath)        { _frameTexture = texturePath; notifyListeners(); }
  void setFrameContainerColor(Color color)        { _frameContainerColor = color; _frameContainerTexture = null; notifyListeners(); }
  void setFrameContainerTexture(String p)         { _frameContainerTexture = p; notifyListeners(); }
  void setFrameShape(FrameShape shape)            { _frameShape = shape; notifyListeners(); }
  void addSticker(String assetPath)               { _stickers.add(StickerData(assetPath: assetPath)); notifyListeners(); }
  void updateStickerPosition(int i, Offset p)     { if (i < _stickers.length) { _stickers[i].position = p; notifyListeners(); } }
  void updateStickerSize(int i, double s)         { if (i < _stickers.length) { _stickers[i].size = s; notifyListeners(); } }
  void updateStickerRotation(int i, double r)     { if (i < _stickers.length) { _stickers[i].rotation = r; notifyListeners(); } }
  void removeSticker(int i)                       { if (i < _stickers.length) { _stickers.removeAt(i); notifyListeners(); } }
  void setHeadlineText(String text)               { _headlineText = text; notifyListeners(); }
  void updateTextSize(double size)                { _textSize = size; notifyListeners(); }
  void updateTextRotation(double rotation)        { _textRotation = rotation; notifyListeners(); }
  void updateTextPosition(Offset position)        { _textPosition = position; notifyListeners(); }

  // --- E. SAVE PHOTOS LOCALLY ---
  Future<String> savePhotosLocally(String userEmail, Uint8List? finalStripBytes) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final dateStr = DateTime.now().toString().split(' ')[0];
      final sessionId = DateTime.now().millisecondsSinceEpoch.toString();
      final sessionFolder = Directory('${directory.path}/Photobooth_Backup/$dateStr/$sessionId');
      if (!await sessionFolder.exists()) await sessionFolder.create(recursive: true);
      for (int i = 0; i < _photos.length; i++) {
        final file = File('${sessionFolder.path}/raw_photo_$i.jpg');
        await file.writeAsBytes(_photos[i].imageData);
      }
      if (finalStripBytes != null) {
        final stripFile = File('${sessionFolder.path}/final_strip_result.png');
        await stripFile.writeAsBytes(finalStripBytes);
      }
      final logFile = File('${directory.path}/Photobooth_Backup/$dateStr/data_pengunjung.csv');
      final csvLine = '$sessionId,$userEmail,${sessionFolder.path},PENDING\n';
      await logFile.writeAsString(csvLine, mode: FileMode.append);
      return sessionFolder.path;
    } catch (e) {
      debugPrint("Gagal Simpan Lokal: $e");
      return "";
    }
  }

  // --- F. RESET & DISPOSE ---
  void reset() {
    _photos.clear();
    _finalImageBytes       = null;
    _finalUploaded         = false;
    _finalUploadFailed     = false;
    _finalResultUrl        = null;
    _finalFramePath        = null;
    _finalVideoPath        = null;
    _finalVideoFilter      = null;
    _finalGifPath          = null;
    _finalGifFilter        = null;
    _gifProcessing         = false;
    _selectedFilter        = PhotoFilter.none;
    _isSessionActive       = false;
    _remainingTime         = 0;
    _sessionTimer?.cancel();
    _frameColor            = Colors.blue;
    _frameTexture          = null;
    _frameContainerColor   = Colors.white; 
    _frameContainerTexture = null;       
    _frameShape            = FrameShape.rectangle;
    _stickers.clear();
    _headlineText          = '';
    _textSize              = 28;
    _textRotation          = 0;
    _textPosition          = const Offset(0, 0);
    _selectedFrameWidth    = null;
    _selectedFrameHeight   = null;
    // _photoSlots      TIDAK direset — tetap sampai pilih frame baru
    // _sessionDurationMin TIDAK direset — tetap dari API
    // onSessionExpired TIDAK direset — dikontrol oleh widget
    notifyListeners();
  }

  @override
  void dispose() {
    _sessionTimer?.cancel();
    super.dispose();
  }
}
