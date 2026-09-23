import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../data/model/subtitle_document.dart';
import '../../data/repository/settings_repository.dart';
import '../../domain/media/bilibili_resolver.dart';
import '../../domain/media/media_storage.dart';
import '../../domain/media/network_header_helper.dart';
import '../../domain/tts/audio_file_validator.dart';
import '../../player/tts_audio_scheduler.dart';
import '../theme/app_theme.dart';
import 'dual_volume_sheet.dart';
import 'subtitle_control_sheet.dart';
import 'subtitle_overlay.dart';
import 'transcript_sheet.dart';

class VideoPlayerScreen extends StatefulWidget {
  final String videoPath;
  final SubtitleDocument document;
  final int initialPositionMs;
  final Future<void> Function(int positionMs)? onPlaybackPositionChanged;

  const VideoPlayerScreen({
    super.key,
    required this.videoPath,
    required this.document,
    this.initialPositionMs = 0,
    this.onPlaybackPositionChanged,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen>
    with WidgetsBindingObserver {
  static const _playbackSpeeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
  static const _stallThreshold = Duration(milliseconds: 700);
  static const _positionSaveInterval = Duration(seconds: 3);

  VideoPlayerController? _controller;
  late final TtsAudioScheduler _ttsScheduler;
  late SettingsRepository _settings;
  bool _isInitialized = false;
  bool _showControls = true;
  String? _playerError;
  int _currentPosMs = 0;
  DateTime _lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  bool _isScrubbing = false;
  int _scrubMs = 0;
  bool _wasPlayingBeforeScrub = false;
  Timer? _playbackMonitor;
  int _lastObservedPositionMs = 0;
  DateTime _lastPositionAdvanceAt = DateTime.now();
  bool _isPlaybackStalled = false;
  double _playbackSpeed = 1.0;
  DateTime _lastPositionSaveAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastSavedPositionMs = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ttsScheduler = TtsAudioScheduler(widget.document);
    _initSettingsAndPlayer();
  }

  Future<void> _initSettingsAndPlayer() async {
    _settings = await SettingsRepository.getInstance();

    try {
      var playablePath = widget.videoPath;
      var playableUrls = <String>[playablePath];
      var httpHeaders = const <String, String>{};
      if (BilibiliResolver.isBilibiliPageUrl(playablePath)) {
        final resolver = BilibiliResolver();
        final target = await resolver.resolveUrl(playablePath);
        final details = await resolver.getVideoDetails(
          target,
          _settings.bilibiliSessData,
        );
        playableUrls = await resolver.getMuxedVideoUrls(
          details,
          _settings.bilibiliSessData,
        );
        playablePath = playableUrls.first;
        httpHeaders = BilibiliResolver.requestHeaders(
          _settings.bilibiliSessData,
        );
      }

      final isRemote =
          playablePath.startsWith('http://') ||
          playablePath.startsWith('https://');
      final videoOptions = VideoPlayerOptions(mixWithOthers: true);
      if (isRemote) {
        if (httpHeaders.isEmpty) {
          httpHeaders = NetworkHeaderHelper.getHeadersForUri(playablePath);
        }
        _controller = await _initializeNetworkController(
          playableUrls,
          httpHeaders,
          videoOptions,
        );
      } else if (MediaStorage.isContentUri(playablePath)) {
        _controller = VideoPlayerController.contentUri(
          Uri.parse(playablePath),
          videoPlayerOptions: videoOptions,
        );
        await _controller!.initialize();
      } else {
        _controller = VideoPlayerController.file(
          File(playablePath),
          videoPlayerOptions: videoOptions,
        );
        await _controller!.initialize();
      }

      if (!mounted) {
        await _controller!.dispose();
        return;
      }
      final durationMs = _controller!.value.duration.inMilliseconds;
      final resumePositionMs = widget.initialPositionMs.clamp(0, durationMs);
      final shouldRestorePosition =
          resumePositionMs > 0 && resumePositionMs < durationMs;
      _isScrubbing = shouldRestorePosition;
      _currentPosMs = 0;
      _lastObservedPositionMs = 0;
      _lastPositionAdvanceAt = DateTime.now();
      _controller!.addListener(_onPlayerUpdate);
      _playbackMonitor = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => _monitorPlaybackStall(),
      );
      await _calibratePlaybackSpeeds();
      await _applyAudioVolumes();
      await _ttsScheduler.warmUp(resumePositionMs);
      setState(() {
        _isInitialized = true;
      });
      await _controller!.play();
      if (shouldRestorePosition) {
        try {
          await Future.wait([
            _controller!.seekTo(Duration(milliseconds: resumePositionMs)),
            _ttsScheduler.onSeek(resumePositionMs),
          ]);
        } catch (error) {
          debugPrint('Không thể khôi phục vị trí video online: $error');
          await _ttsScheduler.onSeek(
            _controller!.value.position.inMilliseconds,
          );
        } finally {
          _isScrubbing = false;
          _syncTtsWithVideo();
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _playerError = 'Không mở được video: $e');
    }
  }

  Future<VideoPlayerController> _initializeNetworkController(
    List<String> urls,
    Map<String, String> headers,
    VideoPlayerOptions options,
  ) async {
    Object? lastError;
    final candidates = urls
        .map((url) => url.trim())
        .where((url) => url.startsWith('http://') || url.startsWith('https://'))
        .toSet();

    for (final url in candidates) {
      for (var attempt = 0; attempt < 2; attempt++) {
        final controller = VideoPlayerController.networkUrl(
          Uri.parse(url),
          httpHeaders: headers,
          videoPlayerOptions: options,
        );
        try {
          await controller.initialize();
          return controller;
        } catch (error) {
          lastError = error;
          try {
            await controller.dispose();
          } catch (_) {}
          if (attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 300));
          }
        }
      }
    }
    throw lastError ?? StateError('Không có URL video online hợp lệ.');
  }

  void _onPlayerUpdate() {
    final controller = _controller;
    if (!mounted || controller == null || !controller.value.isInitialized) {
      return;
    }
    final now = DateTime.now();
    final positionMs = controller.value.position.inMilliseconds;
    if (controller.value.isPlaying && positionMs != _lastObservedPositionMs) {
      _lastPositionAdvanceAt = now;
    }
    _lastObservedPositionMs = positionMs;
    final stallChanged = _refreshPlaybackStall(now);
    if (!_isScrubbing && now.difference(_lastUiUpdate).inMilliseconds >= 50) {
      _lastUiUpdate = now;
      setState(() {
        _currentPosMs = positionMs;
      });
    } else if (stallChanged) {
      setState(() {});
    }
    unawaited(_persistPlaybackPosition());
    _syncTtsWithVideo();
  }

  bool _refreshPlaybackStall(DateTime now) {
    final value = _controller?.value;
    if (value == null) return false;
    final stalled =
        value.isPlaying &&
        value.isBuffering &&
        now.difference(_lastPositionAdvanceAt) >= _stallThreshold;
    if (stalled == _isPlaybackStalled) return false;
    _isPlaybackStalled = stalled;
    return true;
  }

  void _monitorPlaybackStall() {
    if (!mounted || _controller?.value.isInitialized != true) return;
    if (_refreshPlaybackStall(DateTime.now())) {
      setState(() {});
      _syncTtsWithVideo();
    }
  }

  void _syncTtsWithVideo() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    unawaited(
      _ttsScheduler.onVideoStateUpdate(
        positionMs: controller.value.position.inMilliseconds,
        isPlaying: controller.value.isPlaying,
        isBuffering: _isPlaybackStalled,
        isScrubbing: _isScrubbing,
        playbackSpeed: controller.value.playbackSpeed,
      ),
    );
  }

  Future<void> _persistPlaybackPosition({bool force = false}) async {
    final callback = widget.onPlaybackPositionChanged;
    final controller = _controller;
    if (callback == null || controller?.value.isInitialized != true) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastPositionSaveAt) < _positionSaveInterval) {
      return;
    }
    final durationMs = controller!.value.duration.inMilliseconds;
    final currentMs = controller.value.position.inMilliseconds;
    final positionMs = durationMs > 0 && durationMs - currentMs <= 1000
        ? 0
        : currentMs.clamp(0, durationMs);
    if (!force && positionMs == _lastSavedPositionMs) return;
    _lastPositionSaveAt = now;
    _lastSavedPositionMs = positionMs;
    await callback(positionMs);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_persistPlaybackPosition(force: true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _playbackMonitor?.cancel();
    unawaited(_persistPlaybackPosition(force: true));
    _controller?.removeListener(_onPlayerUpdate);
    _controller?.dispose();
    unawaited(_ttsScheduler.dispose());
    super.dispose();
  }

  void _seekTo(int targetMs) {
    unawaited(_seekAndRestorePlayback(targetMs));
  }

  void _skipBy(int deltaMs) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final durationMs = controller.value.duration.inMilliseconds;
    final targetMs = (controller.value.position.inMilliseconds + deltaMs).clamp(
      0,
      durationMs,
    );
    _seekTo(targetMs);
  }

  Future<void> _seekAndRestorePlayback(int targetMs) async {
    final controller = _controller;
    if (controller == null) return;
    final shouldResume = controller.value.isPlaying;
    if (shouldResume) await controller.pause();
    try {
      await Future.wait([
        controller.seekTo(Duration(milliseconds: targetMs)),
        _ttsScheduler.onSeek(targetMs),
      ]);
    } finally {
      if (shouldResume) await controller.play();
    }
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.setPlaybackSpeed(speed);
      if (mounted) {
        setState(() => _playbackSpeed = speed);
      }
      _syncTtsWithVideo();
    } catch (error) {
      try {
        await controller.setPlaybackSpeed(1);
      } catch (_) {}
      if (!mounted) return;
      setState(() => _playbackSpeed = 1);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nguồn video này không hỗ trợ tốc độ đã chọn.'),
        ),
      );
      _syncTtsWithVideo();
    }
  }

  Future<void> _applyAudioVolumes() async {
    final hasTts = widget.document.items.any(
      (item) =>
          item.audioFilePath != null && File(item.audioFilePath!).existsSync(),
    );
    final useTts = hasTts && _settings.isTtsPlaybackEnabled;
    await _controller?.setVolume(useTts ? _settings.originalVideoVolume : 1.0);
    await _ttsScheduler.setVolume(_settings.ttsVolume);
    await _ttsScheduler.setEnabled(useTts);
  }

  Future<void> _calibratePlaybackSpeeds() async {
    for (final item in widget.document.items) {
      if (item.audioFilePath != null && item.audioFilePath!.isNotEmpty) {
        final file = File(item.audioFilePath!);
        if (file.existsSync()) {
          if (item.audioDurationMs <= 0) {
            final val = await AudioFileValidator.validate(file);
            if (val.isValid && val.durationMs > 0) {
              item.audioDurationMs = val.durationMs;
            }
          }
          item.playbackSpeed = TtsAudioScheduler.calculatePlaybackSpeed(
            audioDurationMs: item.audioDurationMs,
            subtitleDurationMs: item.endMs - item.startMs,
          );
        }
      }
    }
  }

  Future<void> _shareSubtitle() async {
    final rawName = widget.videoPath
        .split(RegExp(r'[/\\]'))
        .last
        .split('?')
        .first;
    final baseName = rawName.replaceAll(RegExp(r'\.[^.]+$'), '').trim();
    final renderBox = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile.fromData(
            utf8.encode(widget.document.toSrtString()),
            mimeType: 'application/x-subrip',
          ),
        ],
        fileNameOverrides: ['${baseName.isEmpty ? 'capsub' : baseName}.srt'],
        subject: 'Phụ đề CapSub',
        sharePositionOrigin: renderBox == null
            ? null
            : renderBox.localToGlobal(Offset.zero) & renderBox.size,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_playerError != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _playerError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      );
    }
    if (!_isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: Colors.blueAccent),
        ),
      );
    }

    final controller = _controller!;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: GestureDetector(
          onTap: () {
            setState(() {
              _showControls = !_showControls;
            });
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 1. Trình phát Video
              Center(
                child: AspectRatio(
                  aspectRatio: controller.value.aspectRatio,
                  child: VideoPlayer(controller),
                ),
              ),

              // Vòng xoay chờ tải mạng (Buffering indicator)
              if (_isPlaybackStalled)
                const Center(
                  child: CircularProgressIndicator(
                    color: AppTheme.primaryEmerald,
                  ),
                ),

              // 2. Lớp Hộp Đen (BlackBox) và Phụ đề nổi
              SubtitleOverlay(
                document: widget.document,
                currentPositionMs: _currentPosMs,
                settings: _settings,
                onDragOffset: (newOffset) {
                  setState(() {
                    _settings.subtitleOffsetY = newOffset.clamp(-120.0, 400.0);
                  });
                },
              ),

              // 3. Thanh điều khiển Video (Controls)
              if (_showControls) ...[
                // Nút quay lại & tiêu đề trên cùng
                Positioned(
                  top: 8,
                  left: 8,
                  right: 8,
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: Icon(
                          _settings.isBlackBoxEnabled
                              ? Icons.crop_portrait
                              : Icons.crop_portrait_outlined,
                          color: _settings.isBlackBoxEnabled
                              ? Colors.yellowAccent
                              : Colors.white70,
                        ),
                        tooltip: 'Bật/Tắt Hộp Đen',
                        onPressed: () {
                          setState(() {
                            _settings.isBlackBoxEnabled =
                                !_settings.isBlackBoxEnabled;
                          });
                        },
                      ),
                      IconButton(
                        icon: Icon(
                          _settings.isTtsPlaybackEnabled
                              ? Icons.record_voice_over
                              : Icons.voice_over_off,
                          color: _settings.isTtsPlaybackEnabled
                              ? Colors.lightGreenAccent
                              : Colors.white70,
                        ),
                        tooltip: 'Bật/Tắt lồng tiếng AI',
                        onPressed: () async {
                          setState(() {
                            _settings.isTtsPlaybackEnabled =
                                !_settings.isTtsPlaybackEnabled;
                          });
                          await _applyAudioVolumes();
                          if (_settings.isTtsPlaybackEnabled) {
                            final positionMs =
                                controller.value.position.inMilliseconds;
                            await _ttsScheduler.onSeek(positionMs);
                            await _ttsScheduler.onVideoStateUpdate(
                              positionMs: positionMs,
                              isPlaying: controller.value.isPlaying,
                              isBuffering: _isPlaybackStalled,
                              isScrubbing: _isScrubbing,
                              playbackSpeed: controller.value.playbackSpeed,
                            );
                          }
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.graphic_eq, color: Colors.white),
                        tooltip: 'Chỉnh âm lượng độc lập',
                        onPressed: () {
                          showModalBottomSheet(
                            context: context,
                            backgroundColor: Colors.transparent,
                            isScrollControlled: true,
                            builder: (ctx) => StatefulBuilder(
                              builder: (context, setSheetState) {
                                return DualVolumeSheet(
                                  originalVolume: _settings.originalVideoVolume,
                                  aiVolume: _settings.ttsVolume,
                                  onOriginalVolumeChanged: (val) async {
                                    setState(() {
                                      _settings.originalVideoVolume = val;
                                    });
                                    await _controller?.setVolume(val);
                                    setSheetState(() {});
                                  },
                                  onAiVolumeChanged: (val) async {
                                    setState(() {
                                      _settings.ttsVolume = val;
                                    });
                                    await _ttsScheduler.setVolume(val);
                                    setSheetState(() {});
                                  },
                                );
                              },
                            ),
                          );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.tune, color: Colors.white),
                        tooltip: 'Tùy chỉnh phụ đề & vị trí',
                        onPressed: () {
                          showModalBottomSheet(
                            context: context,
                            backgroundColor: Colors.transparent,
                            isScrollControlled: true,
                            builder: (ctx) => SubtitleControlSheet(
                              settings: _settings,
                              onChanged: () {
                                setState(() {});
                              },
                            ),
                          );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.ios_share, color: Colors.white),
                        tooltip: 'Xuáº¥t/Chia sáº» SRT',
                        onPressed: _shareSubtitle,
                      ),
                      IconButton(
                        icon: const Icon(Icons.subtitles, color: Colors.white),
                        tooltip: 'Kịch bản phụ đề',
                        onPressed: () {
                          showModalBottomSheet(
                            context: context,
                            backgroundColor: Colors.transparent,
                            isScrollControlled: true,
                            builder: (ctx) =>
                                ValueListenableBuilder<VideoPlayerValue>(
                                  valueListenable: controller,
                                  builder: (_, value, _) =>
                                      FractionallySizedBox(
                                        heightFactor: 0.6,
                                        child: TranscriptSheet(
                                          document: widget.document,
                                          currentPositionMs:
                                              value.position.inMilliseconds,
                                          onSeekTo: (ms) {
                                            _seekTo(ms);
                                            Navigator.pop(ctx);
                                          },
                                        ),
                                      ),
                                ),
                          );
                        },
                      ),
                    ],
                  ),
                ),

                // Điều khiển tua 10 giây và Play / Pause ở giữa màn hình
                Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        iconSize: 38,
                        tooltip: 'Lùi 10 giây',
                        icon: const Icon(Icons.replay_10, color: Colors.white),
                        onPressed: () => _skipBy(-10000),
                      ),
                      const SizedBox(width: 18),
                      IconButton(
                        iconSize: 56,
                        tooltip: controller.value.isPlaying
                            ? 'Tạm dừng'
                            : 'Phát',
                        icon: Icon(
                          controller.value.isPlaying
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                        onPressed: () {
                          setState(() {
                            controller.value.isPlaying
                                ? controller.pause()
                                : controller.play();
                          });
                        },
                      ),
                      const SizedBox(width: 18),
                      IconButton(
                        iconSize: 38,
                        tooltip: 'Tới 10 giây',
                        icon: const Icon(Icons.forward_10, color: Colors.white),
                        onPressed: () => _skipBy(10000),
                      ),
                    ],
                  ),
                ),

                // Thanh trượt tua thời gian ở đáy
                Positioned(
                  bottom: 8,
                  left: 16,
                  right: 16,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatDuration(
                              Duration(
                                milliseconds: _isScrubbing
                                    ? _scrubMs
                                    : controller.value.position.inMilliseconds,
                              ),
                            ),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          PopupMenuButton<double>(
                            tooltip: 'Tốc độ phát',
                            initialValue: _playbackSpeed,
                            onSelected: _setPlaybackSpeed,
                            color: const Color(0xFF252631),
                            itemBuilder: (context) => _playbackSpeeds
                                .map(
                                  (speed) => PopupMenuItem<double>(
                                    value: speed,
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 24,
                                          child: speed == _playbackSpeed
                                              ? const Icon(
                                                  Icons.check,
                                                  size: 18,
                                                  color:
                                                      AppTheme.primaryEmerald,
                                                )
                                              : null,
                                        ),
                                        Text(
                                          '${_formatSpeed(speed)}x',
                                          style: const TextStyle(
                                            color: Colors.white,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                                .toList(),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.speed,
                                    color: Colors.white70,
                                    size: 16,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '${_formatSpeed(_playbackSpeed)}x',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Text(
                            _formatDuration(controller.value.duration),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      _buildProgressBar(controller),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProgressBar(VideoPlayerController controller) {
    final durationMs = controller.value.duration.inMilliseconds;
    if (durationMs <= 0) return const SizedBox(height: 28);

    final currentMs = _isScrubbing
        ? _scrubMs
        : controller.value.position.inMilliseconds.clamp(0, durationMs);

    final bufferedEnd = controller.value.buffered.isNotEmpty
        ? controller.value.buffered.last.end.inMilliseconds.clamp(0, durationMs)
        : 0;
    final bufferedFraction = (bufferedEnd / durationMs).clamp(0.0, 1.0);

    return SizedBox(
      height: 28,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Thanh nền và thanh buffer (bộ nhớ đệm tải trước)
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: 4,
              child: Row(
                children: [
                  Flexible(
                    flex: (bufferedFraction * 1000).toInt().clamp(0, 1000),
                    child: Container(color: Colors.white30),
                  ),
                  Flexible(
                    flex: ((1.0 - bufferedFraction) * 1000).toInt().clamp(
                      0,
                      1000,
                    ),
                    child: Container(color: Colors.white12),
                  ),
                ],
              ),
            ),
          ),
          // Thanh trượt tua thời gian mượt mà (Deferred Scrubbing)
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4.0,
              activeTrackColor: AppTheme.primaryEmerald,
              inactiveTrackColor: Colors.transparent,
              thumbColor: AppTheme.primaryEmerald,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14.0),
              overlayColor: AppTheme.primaryEmerald.withValues(alpha: 0.2),
            ),
            child: Slider(
              value: currentMs.toDouble().clamp(0.0, durationMs.toDouble()),
              min: 0.0,
              max: durationMs.toDouble(),
              onChangeStart: (val) {
                setState(() {
                  _isScrubbing = true;
                  _scrubMs = val.toInt();
                  _wasPlayingBeforeScrub = controller.value.isPlaying;
                });
                unawaited(_ttsScheduler.pause());
                if (_wasPlayingBeforeScrub) {
                  controller.pause();
                }
              },
              onChanged: (val) {
                setState(() {
                  _scrubMs = val.toInt();
                });
              },
              onChangeEnd: (val) async {
                final targetMs = val.toInt();
                await Future.wait([
                  controller.seekTo(Duration(milliseconds: targetMs)),
                  _ttsScheduler.onSeek(targetMs),
                ]);
                if (mounted) {
                  setState(() {
                    _isScrubbing = false;
                  });
                }
                if (_wasPlayingBeforeScrub) {
                  await controller.play();
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = duration.inHours > 0 ? '${duration.inHours}:' : '';
    return '$hours$minutes:$seconds';
  }

  String _formatSpeed(double speed) {
    return speed == speed.roundToDouble()
        ? speed.toInt().toString()
        : speed.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
  }
}
