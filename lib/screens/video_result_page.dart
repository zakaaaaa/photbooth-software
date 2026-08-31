import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../providers/photo_provider.dart';
import '../services/video_result_service.dart';

// ================================================================
// VIDEO RESULT PAGE
// Memutar video hasil (slot diisi klip + overlay frame) secara loop.
// Akan compose sendiri bila perlu, dan otomatis berganti sumber saat
// video di-recompose (mis. filter berubah dari preview).
// ================================================================
class VideoResultPage extends StatefulWidget {
  const VideoResultPage({super.key});

  @override
  State<VideoResultPage> createState() => _VideoResultPageState();
}

class _VideoResultPageState extends State<VideoResultPage> {
  Player? _player;
  VideoController? _controller;
  String? _currentPath;
  bool _ensuring = false;
  bool _failed = false;

  void _openPath(String path) {
    if (_currentPath == path) return;
    _currentPath = path;
    _failed = false;
    _player ??= Player();
    _controller ??= VideoController(_player!);
    _player!.setPlaylistMode(PlaylistMode.loop);
    _player!.open(Media(path));
    if (mounted) setState(() {});
  }

  Future<void> _ensure() async {
    if (_ensuring) return;
    final provider = context.read<PhotoProvider>();

    // Sudah ada & sesuai filter terkini → putar (atau ganti bila beda path).
    if (provider.finalVideoPath != null &&
        provider.finalVideoFilter == provider.selectedFilter) {
      _openPath(provider.finalVideoPath!);
      return;
    }

    // Sedang diproses di tempat lain → tunggu (rebuild saat selesai).
    if (provider.videoProcessing) return;

    if (!provider.hasAllVideoClips) {
      if (mounted && !_failed) setState(() => _failed = true);
      return;
    }

    _ensuring = true;
    await VideoResultService.ensure(provider);
    _ensuring = false;
    if (!mounted) return;

    final p = provider.finalVideoPath;
    if (p != null) {
      _openPath(p);
    } else {
      setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // watch agar rebuild saat finalVideoPath/processing/filter berubah.
    context.watch<PhotoProvider>();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensure());

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(child: _buildContent()),
          Positioned(
            top: 40,
            left: 20,
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  border: Border.all(color: Colors.white30),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.arrow_back,
                    color: Colors.white, size: 24),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_controller != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Video(
          controller: _controller!,
          fit: BoxFit.contain,
          controls: NoVideoControls,
        ),
      );
    }
    if (_failed) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.videocam_off_rounded, color: Colors.white38, size: 48),
          SizedBox(height: 14),
          Text(
            'Video belum tersedia.\nPastikan ffmpeg terpasang lalu ambil foto lagi.',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white54, fontFamily: 'Quicksand', fontSize: 14),
          ),
        ],
      );
    }
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(color: Colors.white70),
        SizedBox(height: 16),
        Text(
          'Menyiapkan video...',
          style: TextStyle(
              color: Colors.white70, fontFamily: 'Quicksand', fontSize: 15),
        ),
      ],
    );
  }
}
