import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../data/model/subtitle_document.dart';
import '../../data/repository/settings_repository.dart';
import '../../domain/media/bilibili_resolver.dart';
import '../../domain/media/network_header_helper.dart';
import '../../domain/tts/audio_file_validator.dart';
import 'dual_volume_sheet.dart';
import 'subtitle_control_sheet.dart';
import 'subtitle_overlay.dart';
import 'transcript_sheet.dart';

class VideoPlayerScreen extends StatefulWidget {
  final String videoPath;
  final SubtitleDocument document;

  const VideoPlayerScreen({
    super.key,
    required this.videoPath,
    required this.document,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  VideoPlayerController? _controller;
  final AudioPlayer _ttsPlayer = AudioPlayer();
  late SettingsRepository _settings;
  bool _isInitialized = false;
  bool _showControls = true;
  String? _playerError;
  int _currentPosMs = 0;
  int? _activeTtsItemId;
  bool _isSyncingTts = false;
  DateTime _lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _initSettingsAndPlayer();
  }

  Future<void> _initSettingsAndPlayer() async {
    _settings = await SettingsRepository.getInstance();

    try {
      var playablePath = widget.videoPath;
      var httpHeaders = const <String, String>{};
      if (BilibiliResolver.isBilibiliPageUrl(playablePath)) {
        final resolver = BilibiliResolver();
        final target = await resolver.resolveUrl(playablePath);
        final details = await resolver.getVideoDetails(
          target,
          _settings.bilibiliSessData,
        );
        playablePath = await resolver.getMuxedVideoUrl(
          details,
          _settings.bilibiliSessData,
        );
        httpHeaders = BilibiliResolver.requestHeaders(
          _settings.bilibiliSessData,
        );
      }

      final isRemote =
          playablePath.startsWith('http://') ||
          playablePath.startsWith('https://');
      if (isRemote) {
        if (httpHeaders.isEmpty) {
          httpHeaders = NetworkHeaderHelper.getHeadersForUri(playablePath);
        }
        _controller = VideoPlayerController.networkUrl(
          Uri.parse(playablePath),
          httpHeaders: httpHeaders,
        );
      } else {
        _controller = VideoPlayerController.file(File(playablePath));
      }

      await _controller!.initialize();
      if (!mounted) {
        await _controller!.dispose();
        return;
      }
      _controller!.addListener(_onPlayerUpdate);
      await _calibratePlaybackSpeeds();
      await _applyAudioVolumes();
      setState(() {
        _isInitialized = true;
      });
      await _controller!.play();
    } catch (e) {
      if (!mounted) return;
      setState(() => _playerError = 'Không mở được video: $e');
    }
  }

  void _onPlayerUpdate() {
    final controller = _controller;
    if (!mounted || controller == null || !controller.value.isInitialized) {
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastUiUpdate).inMilliseconds >= 50) {
      _lastUiUpdate = now;
      setState(() {
        _currentPosMs = controller.value.position.inMilliseconds;
      });
    }
    _syncTtsAudio(controller);
  }

  @override
  void dispose() {
    _controller?.removeListener(_onPlayerUpdate);
    _controller?.dispose();
    _ttsPlayer.dispose();
    super.dispose();
  }

  void _seekTo(int targetMs) {
    _activeTtsItemId = null;
    _ttsPlayer.stop();
    _controller?.seekTo(Duration(milliseconds: targetMs));
  }

  Future<void> _applyAudioVolumes() async {
    final hasTts = widget.document.items.any(
      (item) =>
          item.audioFilePath != null && File(item.audioFilePath!).existsSync(),
    );
    final useTts = hasTts && _settings.isTtsPlaybackEnabled;
    await _controller?.setVolume(useTts ? _settings.originalVideoVolume : 1.0);
    await _ttsPlayer.setVolume(_settings.ttsVolume);
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
          final srtDurationMs = max(200, item.endMs - item.startMs);
          if (item.audioDurationMs > srtDurationMs) {
            final targetPlayDurationMs = max(180, srtDurationMs - 100);
            item.playbackSpeed = ((item.audioDurationMs / targetPlayDurationMs)
                    .clamp(1.05, 2.5) *
                100).round() / 100;
          } else {
            item.playbackSpeed = 1.0;
          }
        }
      }
    }
  }

  Future<void> _syncTtsAudio(VideoPlayerController controller) async {
    if (_isSyncingTts || !_settings.isTtsPlaybackEnabled) return;
    _isSyncingTts = true;
    try {
      final positionMs = controller.value.position.inMilliseconds;
      final item = widget.document.getActiveItem(positionMs);
      final path = item?.audioFilePath;

      if (item == null || path == null || !File(path).existsSync()) {
        if (!controller.value.isPlaying && _ttsPlayer.playing) {
          await _ttsPlayer.pause();
        }
        if (_activeTtsItemId != null) {
          final activeItem = widget.document.items
              .where((it) => it.id == _activeTtsItemId)
              .firstOrNull;
          // Nếu video đã trôi quá 1200ms sau khi câu hiện tại kết thúc hoặc trước startMs:
          if (activeItem == null ||
              positionMs < activeItem.startMs ||
              positionMs > activeItem.endMs + 1200) {
            _activeTtsItemId = null;
            await _ttsPlayer.stop();
          }
        }
        return;
      }

      // Đảm bảo tốc độ phát đã được tính toán chính xác
      if (item.playbackSpeed <= 1.0 && item.audioDurationMs > 0) {
        final srtDurationMs = max(200, item.endMs - item.startMs);
        if (item.audioDurationMs > srtDurationMs) {
          final targetPlayDurationMs = max(180, srtDurationMs - 100);
          item.playbackSpeed = ((item.audioDurationMs / targetPlayDurationMs)
                  .clamp(1.05, 2.5) *
              100).round() / 100;
        }
      }

      var speed = item.playbackSpeed.clamp(0.5, 2.5);
      final timelineOffsetMs = max(0, positionMs - item.startMs);
      final sourceOffsetMs = (timelineOffsetMs * speed).round();

      // Nếu đã phát vượt quá thời lượng câu thoại này:
      if (item.audioDurationMs > 0 && sourceOffsetMs >= item.audioDurationMs) {
        return;
      }

      if (_activeTtsItemId != item.id) {
        _activeTtsItemId = item.id;
        await _ttsPlayer.stop();
        // Tránh seek đầu câu nếu offset nhỏ hơn 200ms để không bị nuốt âm đầu
        final initialPos = sourceOffsetMs >= 200
            ? Duration(milliseconds: sourceOffsetMs)
            : null;
        final duration = await _ttsPlayer.setFilePath(
          path,
          initialPosition: initialPos,
        );
        if (duration != null && duration.inMilliseconds > 0) {
          item.audioDurationMs = duration.inMilliseconds;
          final srtDurationMs = max(200, item.endMs - item.startMs);
          if (item.audioDurationMs > srtDurationMs) {
            final targetPlayDurationMs = max(180, srtDurationMs - 100);
            speed = ((item.audioDurationMs / targetPlayDurationMs)
                    .clamp(1.05, 2.5) *
                100).round() / 100;
            item.playbackSpeed = speed;
          }
        }
        // Áp dụng tăng tốc độ phát audio để khớp thời lượng phụ đề!
        await _ttsPlayer.setSpeed(speed);
        await _ttsPlayer.setVolume(_settings.ttsVolume);

        if (controller.value.isPlaying) {
          await _ttsPlayer.play();
        }
      } else {
        if (_ttsPlayer.processingState != ProcessingState.completed) {
          final actualPosMs = _ttsPlayer.position.inMilliseconds;
          final drift = (actualPosMs - sourceOffsetMs).abs();
          if (drift > 600) {
            await _ttsPlayer.seek(Duration(milliseconds: sourceOffsetMs));
          }
        }

        if (controller.value.isPlaying) {
          if (!_ttsPlayer.playing &&
              _ttsPlayer.processingState != ProcessingState.completed) {
            unawaited(_ttsPlayer.play());
          }
        } else if (_ttsPlayer.playing) {
          await _ttsPlayer.pause();
        }
      }
    } catch (_) {
      _activeTtsItemId = null;
      await _ttsPlayer.stop();
    } finally {
      _isSyncingTts = false;
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
                            _activeTtsItemId = null;
                          });
                          await _ttsPlayer.stop();
                          await _applyAudioVolumes();
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
                                    await _ttsPlayer.setVolume(val);
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

                // Nút Play / Pause ở giữa màn hình
                Center(
                  child: IconButton(
                    iconSize: 56,
                    icon: Icon(
                      controller.value.isPlaying
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_filled,
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                    onPressed: () {
                      setState(() {
                        controller.value.isPlaying
                            ? controller.pause()
                            : controller.play();
                      });
                    },
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
                            _formatDuration(controller.value.position),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            _formatDuration(controller.value.duration),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      VideoProgressIndicator(
                        controller,
                        allowScrubbing: true,
                        colors: const VideoProgressColors(
                          playedColor: Colors.blueAccent,
                          bufferedColor: Colors.white24,
                          backgroundColor: Colors.white12,
                        ),
                      ),
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

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = duration.inHours > 0 ? '${duration.inHours}:' : '';
    return '$hours$minutes:$seconds';
  }
}
