import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../data/model/subtitle_document.dart';
import '../../data/repository/history_repository.dart';
import '../../data/repository/settings_repository.dart';
import '../../domain/media/bilibili_resolver.dart';
import '../../domain/media/hongguo_prefetch_manager.dart';
import '../../domain/media/hongguo_resolver.dart';
import '../../domain/media/video_cache_manager.dart';
import '../../domain/media/media_storage.dart';
import '../../domain/media/network_header_helper.dart';
import '../../domain/tts/audio_file_validator.dart';
import '../../player/tts_audio_scheduler.dart';
import '../theme/app_theme.dart';
import 'dual_volume_sheet.dart';
import 'subtitle_control_sheet.dart';
import 'subtitle_overlay.dart';
import 'transcript_sheet.dart';
import '../hongguo/hongguo_settings_sheet.dart';

class VideoPlayerScreen extends StatefulWidget {
  final String videoPath;
  final SubtitleDocument? document;
  final String? title;
  final int initialPositionMs;
  final Future<void> Function(int positionMs)? onPlaybackPositionChanged;

  // Hỗ trợ phim bộ Hồng Quả & Gối đầu tập tiếp theo
  final HongguoDramaDetail? dramaDetail;
  final int? currentEpisodeIndex;
  final bool? initialTtsEnabled;

  const VideoPlayerScreen({
    super.key,
    required this.videoPath,
    this.document,
    this.title,
    this.initialPositionMs = 0,
    this.onPlaybackPositionChanged,
    this.dramaDetail,
    this.currentEpisodeIndex,
    this.initialTtsEnabled,
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
  late TtsAudioScheduler _ttsScheduler;
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

  // Quản lý trạng thái phim bộ Hồng Quả
  late int _currentEpisodeIndex;
  late String _currentVideoPath;
  late String _currentTitle;
  late SubtitleDocument _currentDocument;
  HongguoPrefetchManager? _prefetchManager;
  bool _autoPlayNextEpisode = true;
  bool _isSwitchingEpisode = false;
  bool _isDownloadingVideo = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentEpisodeIndex = widget.currentEpisodeIndex ?? 1;
    _currentVideoPath = widget.videoPath;
    _currentTitle = widget.title ?? '';
    _currentDocument = widget.document ?? SubtitleDocument();

    _ttsScheduler = TtsAudioScheduler(_currentDocument);

    _initSettingsAndPlayer();
  }

  Future<void> _initSettingsAndPlayer() async {
    _settings = await SettingsRepository.getInstance();
    if (widget.initialTtsEnabled != null) {
      _settings.isTtsPlaybackEnabled = widget.initialTtsEnabled!;
    }
    if (mounted) {
      setState(() {
        _autoPlayNextEpisode = _settings.autoPlayNextEpisode;
      });
    }

    // Khởi tạo HongguoPrefetchManager nếu có thông tin phim bộ
    if (widget.dramaDetail != null) {
      _prefetchManager = HongguoPrefetchManager(widget.dramaDetail!);
      _prefetchManager!.registerVideoUrl(_currentEpisodeIndex, widget.videoPath);
      if (_currentDocument.isNotEmpty) {
        _prefetchManager!.registerDocument(_currentEpisodeIndex, _currentDocument);
      }

      // Kích hoạt dịch ngay tập hiện tại (nếu trống) và gối đầu tập tiếp theo
      _prefetchManager!.onEpisodePlaying(
        _currentEpisodeIndex,
        translateCurrentIfEmpty: _currentDocument.isEmpty,
        onCurrentSubtitleReady: (newDoc) async {
          if (!mounted || _currentEpisodeIndex != (widget.currentEpisodeIndex ?? 1)) {
            return;
          }
          setState(() {
            _currentDocument = newDoc;
            _ttsScheduler.dispose();
            _ttsScheduler = TtsAudioScheduler(newDoc);
          });
          await _applyAudioVolumes();
          if (_settings.isTtsPlaybackEnabled) {
            final pos = _controller?.value.position.inMilliseconds ?? 0;
            await _ttsScheduler.onSeek(pos);
            _syncTtsWithVideo();
          }
        },
      );
    }

    await _initPlayerForPath(
      _currentVideoPath,
      startPosMs: widget.initialPositionMs,
    );
  }

  Future<void> _initPlayerForPath(
    String playablePath, {
    int startPosMs = 0,
  }) async {
    try {
      var targetPath = playablePath;
      var playableUrls = <String>[targetPath];
      var httpHeaders = const <String, String>{};
      if (BilibiliResolver.isBilibiliPageUrl(targetPath)) {
        final resolver = BilibiliResolver();
        final target = await resolver.resolveUrl(targetPath);
        final details = await resolver.getVideoDetails(
          target,
          _settings.bilibiliSessData,
        );

        playableUrls = await resolver.getMuxedVideoUrls(
          details,
          _settings.bilibiliSessData,
        );
        targetPath = playableUrls.first;
        httpHeaders = BilibiliResolver.requestHeaders(
          _settings.bilibiliSessData,
        );
      } else if (widget.dramaDetail != null &&
          (targetPath.startsWith('http://') || targetPath.startsWith('https://'))) {
        final cached = await VideoCacheManager.findCachedFile(
          url: targetPath,
          seriesId: widget.dramaDetail?.seriesId,
          episodeIndex: _currentEpisodeIndex,
        );
        if (cached != null && await cached.exists()) {
          targetPath = cached.path;
          playableUrls = [cached.path];
        }
      }

      _currentVideoPath = targetPath;

      final isRemote =
          targetPath.startsWith('http://') || targetPath.startsWith('https://');
      final videoOptions = VideoPlayerOptions(mixWithOthers: true);
      if (isRemote) {
        if (httpHeaders.isEmpty) {
          httpHeaders = NetworkHeaderHelper.getHeadersForUri(targetPath);
        }
        _controller = await _initializeNetworkController(
          playableUrls,
          httpHeaders,
          videoOptions,
        );
      } else if (MediaStorage.isContentUri(targetPath)) {
        _controller = VideoPlayerController.contentUri(
          Uri.parse(targetPath),
          videoPlayerOptions: videoOptions,
        );
        await _controller!.initialize();
      } else {
        _controller = VideoPlayerController.file(
          File(targetPath),
          videoPlayerOptions: videoOptions,
        );
        await _controller!.initialize();
      }

      if (!mounted) {
        await _controller!.dispose();
        return;
      }
      final durationMs = _controller!.value.duration.inMilliseconds;
      final resumePositionMs = startPosMs.clamp(0, durationMs);
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
        .where((url) => url.isNotEmpty)
        .toList();
    if (candidates.isEmpty) {
      throw StateError('Không tìm thấy link video mạng hợp lệ để phát.');
    }
    for (var i = 0; i < candidates.length; i++) {
      final candidateUrl = candidates[i];
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(candidateUrl),
        httpHeaders: headers,
        videoPlayerOptions: options,
      );
      try {
        await controller.initialize();
        return controller;
      } catch (error) {
        lastError = error;
        await controller.dispose();
      }
    }
    throw lastError ??
        StateError('Không thể khởi tạo luồng video mạng nào trong danh sách.');
  }

  bool get _hasNextEpisode {
    if (widget.dramaDetail == null) return false;
    final total = widget.dramaDetail!.episodes.isNotEmpty
        ? widget.dramaDetail!.episodes.length
        : widget.dramaDetail!.totalEpisodes;
    return _currentEpisodeIndex < total;
  }

  bool get _hasPreviousEpisode {
    return widget.dramaDetail != null && _currentEpisodeIndex > 1;
  }

  Future<void> _playNextEpisode() async {
    if (!_hasNextEpisode || _isSwitchingEpisode) return;
    await _goToEpisode(_currentEpisodeIndex + 1);
  }

  Future<void> _playPreviousEpisode() async {
    if (!_hasPreviousEpisode || _isSwitchingEpisode) return;
    await _goToEpisode(_currentEpisodeIndex - 1);
  }

  Future<void> _goToEpisode(int targetIndex) async {
    if (_isSwitchingEpisode) return;
    setState(() => _isSwitchingEpisode = true);

    try {
      final playUrl = await _prefetchManager?.getOrResolveUrl(targetIndex);
      if (playUrl == null) {
        if (mounted) {
          setState(() => _isSwitchingEpisode = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Không thể lấy đường dẫn Tập $targetIndex!')),
          );
        }
        return;
      }
      if (!mounted) return;

      var doc = _prefetchManager?.getCachedDocument(targetIndex);
      final epTitle = '${widget.dramaDetail!.title} - Tập $targetIndex';

      _currentEpisodeIndex = targetIndex;
      await _switchVideo(
        newVideoPath: playUrl,
        newDocument: doc ?? SubtitleDocument(),
        newTitle: epTitle,
      );

      // Kích hoạt dịch gối đầu tập tiếp theo
      _prefetchManager?.onEpisodePlaying(
        targetIndex,
        translateCurrentIfEmpty: doc == null,
        onCurrentSubtitleReady: (newDoc) {
          if (!mounted || _currentEpisodeIndex != targetIndex) return;
          setState(() {
            _currentDocument = newDoc;
            _ttsScheduler.dispose();
            _ttsScheduler = TtsAudioScheduler(newDoc);
          });
          _applyAudioVolumes();
          if (_settings.isTtsPlaybackEnabled) {
            final pos = _controller?.value.position.inMilliseconds ?? 0;
            _ttsScheduler.onSeek(pos);
            _syncTtsWithVideo();
          }
        },
      );
    } finally {
      if (mounted) {
        setState(() => _isSwitchingEpisode = false);
      }
    }
  }

  void _showEpisodeListSheet() {
    final detail = widget.dramaDetail;
    if (detail == null) return;
    final total = detail.episodes.isNotEmpty
        ? detail.episodes.length
        : (detail.totalEpisodes > 0 ? detail.totalEpisodes : 1);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.7,
          decoration: const BoxDecoration(
            color: Color(0xFF1A1C24),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        'Danh sách tập: ${detail.title}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.tune_rounded,
                          color: AppTheme.primaryEmerald, size: 20),
                      tooltip: 'Cài đặt Hồng Quả',
                      onPressed: () {
                        Navigator.pop(ctx);
                        HongguoSettingsSheet.show(context);
                      },
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryEmerald.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'Đang phát: Tập $_currentEpisodeIndex',
                        style: const TextStyle(
                          color: AppTheme.primaryEmerald,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white12, height: 1),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 1.3,
                  ),
                  itemCount: total,
                  itemBuilder: (ctx, i) {
                    final ep = i + 1;
                    final isPlaying = ep == _currentEpisodeIndex;
                    final isCached = _prefetchManager?.getCachedDocument(ep) != null;

                    return InkWell(
                      onTap: () {
                        Navigator.pop(ctx);
                        if (ep != _currentEpisodeIndex) {
                          _goToEpisode(ep);
                        }
                      },
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isPlaying
                              ? AppTheme.primaryEmerald.withValues(alpha: 0.25)
                              : (isCached
                                  ? const Color(0xFF132F24)
                                  : const Color(0xFF252631)),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isPlaying
                                ? AppTheme.primaryEmerald
                                : (isCached
                                    ? AppTheme.primaryEmerald.withValues(alpha: 0.5)
                                    : Colors.white12),
                            width: isPlaying ? 1.8 : 1,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '$ep',
                              style: TextStyle(
                                color: isPlaying
                                    ? AppTheme.primaryEmerald
                                    : Colors.white,
                                fontWeight: isPlaying ? FontWeight.bold : FontWeight.w500,
                                fontSize: 13,
                              ),
                            ),
                            if (isCached && !isPlaying)
                              const Text(
                                'Đã sub',
                                style: TextStyle(
                                  color: AppTheme.primaryEmerald,
                                  fontSize: 8,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _switchVideo({
    required String newVideoPath,
    required SubtitleDocument newDocument,
    required String newTitle,
  }) async {
    await _controller?.pause();
    _controller?.removeListener(_onPlayerUpdate);
    await _controller?.dispose();
    _controller = null;

    _playbackMonitor?.cancel();
    _ttsScheduler.dispose();

    setState(() {
      _isInitialized = false;
      _currentVideoPath = newVideoPath;
      _currentDocument = newDocument;
      _currentTitle = newTitle;
      _currentPosMs = 0;
      _lastObservedPositionMs = 0;
      _isScrubbing = false;
      _isPlaybackStalled = false;
    });

    _ttsScheduler = TtsAudioScheduler(newDocument);
    await _initPlayerForPath(newVideoPath);
  }

  Future<void> _downloadCurrentBilibiliVideo() async {
    final videoUrl = _currentVideoPath;
    if (!videoUrl.startsWith('http')) return;

    setState(() {
      _isDownloadingVideo = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('📥 Đang tải video Bilibili về máy qua 4 cụm máy chủ CDN...'),
        duration: Duration(seconds: 2),
      ),
    );

    try {
      final resolver = BilibiliResolver();
      final target = await resolver.resolveUrl(videoUrl);
      final details = await resolver.getVideoDetails(
        target,
        _settings.bilibiliSessData,
      );
      final cachedVideo = await VideoCacheManager.getCachedVideoFile(
        url: videoUrl,
        bvid: details.bvid,
        bilibiliPage: details.selectedPageIndex,
      );
      final partFile = File('${cachedVideo.path}.part');
      await resolver.downloadVideo(
        details,
        partFile,
        _settings.bilibiliSessData,
        concurrency: _settings.downloadThreadCount,
      );
      if (await partFile.exists()) {
        if (await cachedVideo.exists()) {
          try {
            await cachedVideo.delete();
          } catch (_) {}
        }
        try {
          await partFile.rename(cachedVideo.path);
        } catch (_) {
          await partFile.copy(cachedVideo.path);
          try {
            await partFile.delete();
          } catch (_) {}
        }
        unawaited(VideoCacheManager.pruneCacheIfNeeded());
        try {
          final history = await HistoryRepository.getInstance();
          await history.updateVideoPath(videoUrl, cachedVideo.path);
        } catch (_) {}
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ Tải video thành công! Đang chuyển sang phát offline mượt mà...'),
              backgroundColor: AppTheme.primaryEmerald,
            ),
          );
          final currentPos = _controller?.value.position.inMilliseconds ?? 0;
          await _switchVideo(
            newVideoPath: cachedVideo.path,
            newDocument: _currentDocument,
            newTitle: _currentTitle,
          );
          if (currentPos > 0) {
            await _controller?.seekTo(Duration(milliseconds: currentPos));
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('⚠️ Lỗi khi tải video: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDownloadingVideo = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _prefetchManager?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _playbackMonitor?.cancel();
    _controller?.removeListener(_onPlayerUpdate);
    _controller?.dispose();
    _ttsScheduler.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _controller?.pause();
      _ttsScheduler.onSeek(_currentPosMs);
    }
  }

  void _onPlayerUpdate() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final positionMs = controller.value.position.inMilliseconds;
    final durationMs = controller.value.duration.inMilliseconds;
    final now = DateTime.now();

    // Tự động chuyển sang tập tiếp theo khi xem xong (video kết thúc và còn < 1s)
    if (_autoPlayNextEpisode &&
        _hasNextEpisode &&
        !_isSwitchingEpisode &&
        durationMs > 5000 &&
        (positionMs >= durationMs - 500 ||
            (!controller.value.isPlaying && positionMs >= durationMs - 1200))) {
      _playNextEpisode();
      return;
    }

    // Nếu tắt tự động chuyển tập: dừng video khi tới cuối video
    if (!_autoPlayNextEpisode &&
        durationMs > 2000 &&
        positionMs >= durationMs - 200 &&
        controller.value.isPlaying) {
      controller.pause();
    }

    if (positionMs != _lastObservedPositionMs) {
      _lastObservedPositionMs = positionMs;
      _lastPositionAdvanceAt = now;
    }
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

  Future<void> _persistPlaybackPosition() async {
    final callback = widget.onPlaybackPositionChanged;
    if (callback == null || _isScrubbing) return;
    final now = DateTime.now();
    if (now.difference(_lastPositionSaveAt) < _positionSaveInterval) {
      return;
    }
    final positionMs = _currentPosMs;
    if (positionMs == _lastSavedPositionMs) return;
    _lastPositionSaveAt = now;
    _lastSavedPositionMs = positionMs;
    try {
      await callback(positionMs);
    } catch (_) {}
  }

  Future<void> _seekTo(int positionMs) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final durationMs = controller.value.duration.inMilliseconds;
    final clampedMs = positionMs.clamp(0, durationMs);
    setState(() {
      _currentPosMs = clampedMs;
      _lastObservedPositionMs = clampedMs;
      _lastPositionAdvanceAt = DateTime.now();
      _isScrubbing = false;
    });
    await controller.seekTo(Duration(milliseconds: clampedMs));
    await _ttsScheduler.onSeek(clampedMs);
    _syncTtsWithVideo();
  }

  void _skipBy(int deltaMs) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final nextMs = controller.value.position.inMilliseconds + deltaMs;
    _seekTo(nextMs);
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      await controller.setPlaybackSpeed(speed);
      setState(() => _playbackSpeed = speed);
      _syncTtsWithVideo();
    } catch (_) {
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
    final hasTts = _currentDocument.items.any(
      (item) =>
          item.audioFilePath != null && File(item.audioFilePath!).existsSync(),
    );
    final useTts = hasTts && _settings.isTtsPlaybackEnabled;
    await _controller?.setVolume(useTts ? _settings.originalVideoVolume : 1.0);
    await _ttsScheduler.setVolume(_settings.ttsVolume);
    await _ttsScheduler.setEnabled(useTts);
  }

  Future<void> _calibratePlaybackSpeeds() async {
    for (final item in _currentDocument.items) {
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
    final doc = _currentDocument;
    if (doc.items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không có phụ đề để xuất!')),
      );
      return;
    }
    final rawName = _currentVideoPath
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
            utf8.encode(doc.toSrtString()),
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
    final displayTitle = _currentTitle.isNotEmpty
        ? _currentTitle
        : (widget.title ?? '');

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
                document: _currentDocument,
                currentPositionMs: _currentPosMs,
                settings: _settings,
                onDragOffset: (newOffset) {
                  setState(() {
                    _settings.subtitleOffsetY = newOffset.clamp(-120.0, 400.0);
                  });
                },
              ),

              // 3. Lớp chuyển đổi tập phim (Khi đang tải tập kế tiếp)
              if (_isSwitchingEpisode)
                Container(
                  color: Colors.black54,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(
                          color: AppTheme.primaryEmerald,
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Đang mở Tập $_currentEpisodeIndex...',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // Banner tiến trình dịch cho tập hiện tại (khi chưa có sub hoặc đang xử lý)
              if (_prefetchManager != null && _currentDocument.isEmpty)
                Positioned(
                  top: 56,
                  left: 20,
                  right: 20,
                  child: ValueListenableBuilder<PrefetchState?>(
                    valueListenable: _prefetchManager!.prefetchStateNotifier,
                    builder: (context, state, _) {
                      if (state == null ||
                          state.episodeIndex != _currentEpisodeIndex) {
                        return const SizedBox.shrink();
                      }
                      final isTranslating = state.isTranslating;
                      final isFailed = state.status == 'failed';
                      if (!isTranslating && !isFailed) {
                        return const SizedBox.shrink();
                      }

                      return Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.82),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isFailed
                                  ? Colors.redAccent.withValues(alpha: 0.6)
                                  : AppTheme.primaryEmerald.withValues(alpha: 0.6),
                              width: 1,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.5),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (isTranslating)
                                    const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: AppTheme.primaryEmerald,
                                      ),
                                    )
                                  else if (isFailed)
                                    const Icon(
                                      Icons.error_outline_rounded,
                                      color: Colors.redAccent,
                                      size: 16,
                                    ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      isFailed
                                          ? 'Chưa tạo được phụ đề: ${state.message}'
                                          : (state.message.isNotEmpty
                                              ? state.message
                                              : 'Đang bóc tách & dịch phụ đề (${(state.progress * 100).toInt()}%)...'),
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: isFailed
                                            ? Colors.redAccent
                                            : Colors.white,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (isFailed) ...[
                                    const SizedBox(width: 8),
                                    InkWell(
                                      onTap: () {
                                        _prefetchManager?.onEpisodePlaying(
                                          _currentEpisodeIndex,
                                          translateCurrentIfEmpty: true,
                                          onCurrentSubtitleReady: (newDoc) {
                                            if (!mounted) return;
                                            setState(() {
                                              _currentDocument = newDoc;
                                              _ttsScheduler.dispose();
                                              _ttsScheduler = TtsAudioScheduler(newDoc);
                                            });
                                            _applyAudioVolumes();
                                          },
                                        );
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.redAccent.withValues(alpha: 0.2),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Text(
                                          'Thử lại',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              if (isTranslating && state.progress > 0) ...[
                                const SizedBox(height: 6),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(2),
                                  child: SizedBox(
                                    width: 160,
                                    height: 3,
                                    child: LinearProgressIndicator(
                                      value: state.progress.clamp(0.0, 1.0),
                                      backgroundColor: Colors.white12,
                                      color: AppTheme.primaryEmerald,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),

              // 4. Thanh điều khiển Video (Controls)
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
                      if (displayTitle.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                displayTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      (!_currentVideoPath.startsWith('http://') &&
                                              !_currentVideoPath.startsWith('https://'))
                                          ? Icons.offline_pin_rounded
                                          : Icons.cloud_queue_rounded,
                                      size: 11,
                                      color: (!_currentVideoPath.startsWith('http://') &&
                                              !_currentVideoPath.startsWith('https://'))
                                          ? AppTheme.primaryEmerald
                                          : const Color(0xFFFFB74D),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      (!_currentVideoPath.startsWith('http://') &&
                                              !_currentVideoPath.startsWith('https://'))
                                          ? 'Phát offline (Bộ nhớ máy)'
                                          : 'Phát trực tuyến (Online)',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: (!_currentVideoPath.startsWith('http://') &&
                                                !_currentVideoPath.startsWith('https://'))
                                            ? AppTheme.primaryEmerald
                                            : const Color(0xFFFFB74D),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (_prefetchManager != null)
                                ValueListenableBuilder<PrefetchState?>(
                                  valueListenable:
                                      _prefetchManager!.prefetchStateNotifier,
                                  builder: (context, state, _) {
                                    if (state == null ||
                                        state.status == 'idle') {
                                      return const SizedBox.shrink();
                                    }
                                    final isReady = state.isReady;
                                    return Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            isReady
                                                ? Icons.bolt_rounded
                                                : Icons.hourglass_top_rounded,
                                            size: 12,
                                            color: isReady
                                                ? AppTheme.primaryEmerald
                                                : AppTheme.accentGold,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            isReady
                                                ? 'Sẵn sàng Tập ${state.episodeIndex}'
                                                : 'Đang dịch Tập ${state.episodeIndex} (${(state.progress * 100).toInt()}%)',
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                              color: isReady
                                                  ? AppTheme.primaryEmerald
                                                  : AppTheme.accentGold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                      ] else
                        const Spacer(),

                      // Nút YouTube-style: Bật/Tắt Tự Động Chuyển Tập & Dịch Ngầm
                      if (widget.dramaDetail != null) ...[
                        InkWell(
                          onTap: () {
                            final newVal = !_autoPlayNextEpisode;
                            setState(() {
                              _autoPlayNextEpisode = newVal;
                            });
                            _settings.autoPlayNextEpisode = newVal;
                            if (newVal) {
                              _prefetchManager
                                  ?.onEpisodePlaying(_currentEpisodeIndex);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                      '▶️ Đã BẬT tự chuyển tập & dịch ngầm'),
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            } else {
                              _prefetchManager?.cancelPrefetch();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                      '⏸️ Đã TẮT tự chuyển tập (Dừng dịch ngầm)'),
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            }
                          },
                          borderRadius: BorderRadius.circular(20),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: _autoPlayNextEpisode
                                  ? AppTheme.primaryEmerald
                                      .withValues(alpha: 0.25)
                                  : Colors.black.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: _autoPlayNextEpisode
                                    ? AppTheme.primaryEmerald
                                    : Colors.white24,
                                width: 1.2,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _autoPlayNextEpisode
                                      ? Icons.play_circle_fill_rounded
                                      : Icons.pause_circle_outline_rounded,
                                  size: 16,
                                  color: _autoPlayNextEpisode
                                      ? AppTheme.primaryEmerald
                                      : Colors.white70,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _autoPlayNextEpisode
                                      ? 'Tự chuyển'
                                      : 'Dừng tập',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: _autoPlayNextEpisode
                                        ? AppTheme.primaryEmerald
                                        : Colors.white70,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(
                            Icons.format_list_numbered_rounded,
                            color: Colors.white,
                          ),
                          tooltip: 'Danh sách tập phim',
                          onPressed: _showEpisodeListSheet,
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.tune_rounded,
                            color: Colors.white70,
                          ),
                          tooltip: 'Cài đặt dịch & xem Hồng Quả',
                          onPressed: () => HongguoSettingsSheet.show(context),
                        ),
                      ],

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
                            if (_prefetchManager != null && _currentDocument.items.isNotEmpty) {
                              _prefetchManager!.ensureTtsGenerated(_currentDocument, episodeIndex: _currentEpisodeIndex);
                            }
                            final positionMs =
                                controller.value.position.inMilliseconds;
                            await _ttsScheduler.onSeek(positionMs);
                            _syncTtsWithVideo();
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
                        tooltip: 'Xuất/Chia sẻ SRT',
                        onPressed: _shareSubtitle,
                      ),
                      if (_currentVideoPath.startsWith('http')) ...[
                        IconButton(
                          icon: _isDownloadingVideo
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppTheme.primaryEmerald,
                                  ),
                                )
                              : const Icon(
                                  Icons.download_for_offline_rounded,
                                  color: Colors.white,
                                ),
                          tooltip: 'Tải video về máy để xem offline (không lag)',
                          onPressed: _isDownloadingVideo
                              ? null
                              : _downloadCurrentBilibiliVideo,
                        ),
                      ],
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
                              builder: (_, value, _) => FractionallySizedBox(
                                heightFactor: 0.6,
                                child: TranscriptSheet(
                                  document: _currentDocument,
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

                // Nút điều khiển trung tâm (Tập trước, Lùi 10s, Play/Pause, Tới 10s, Tập sau)
                Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (widget.dramaDetail != null) ...[
                        IconButton(
                          iconSize: 36,
                          tooltip: 'Tập trước',
                          icon: Icon(
                            Icons.skip_previous_rounded,
                            color: _hasPreviousEpisode
                                ? Colors.white
                                : Colors.white38,
                          ),
                          onPressed:
                              _hasPreviousEpisode ? _playPreviousEpisode : null,
                        ),
                        const SizedBox(width: 8),
                      ],
                      IconButton(
                        iconSize: 38,
                        tooltip: 'Lùi 10 giây',
                        icon: const Icon(Icons.replay_10, color: Colors.white),
                        onPressed: () => _skipBy(-10000),
                      ),
                      const SizedBox(width: 14),
                      IconButton(
                        iconSize: 64,
                        icon: Icon(
                          controller.value.isPlaying
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          color: Colors.white,
                        ),
                        onPressed: () {
                          setState(() {
                            controller.value.isPlaying
                                ? controller.pause()
                                : controller.play();
                          });
                        },
                      ),
                      const SizedBox(width: 14),
                      IconButton(
                        iconSize: 38,
                        tooltip: 'Tới 10 giây',
                        icon: const Icon(Icons.forward_10, color: Colors.white),
                        onPressed: () => _skipBy(10000),
                      ),
                      if (widget.dramaDetail != null) ...[
                        const SizedBox(width: 8),
                        IconButton(
                          iconSize: 36,
                          tooltip: 'Tập kế tiếp',
                          icon: Icon(
                            Icons.skip_next_rounded,
                            color: _hasNextEpisode
                                ? Colors.white
                                : Colors.white38,
                          ),
                          onPressed: _hasNextEpisode ? _playNextEpisode : null,
                        ),
                      ],
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
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3.5,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 14,
                          ),
                          activeTrackColor: AppTheme.primaryEmerald,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: AppTheme.primaryEmerald,
                          overlayColor: AppTheme.primaryEmerald.withValues(
                            alpha: 0.2,
                          ),
                        ),
                        child: Slider(
                          value: (_isScrubbing
                                  ? _scrubMs
                                  : _currentPosMs.clamp(
                                      0,
                                      controller.value.duration.inMilliseconds,
                                    ))
                              .toDouble(),
                          min: 0.0,
                          max: controller.value.duration.inMilliseconds
                              .toDouble(),
                          onChangeStart: (val) {
                            setState(() {
                              _isScrubbing = true;
                              _scrubMs = val.toInt();
                              _wasPlayingBeforeScrub =
                                  controller.value.isPlaying;
                            });
                            controller.pause();
                          },
                          onChanged: (val) {
                            setState(() {
                              _scrubMs = val.toInt();
                            });
                          },
                          onChangeEnd: (val) async {
                            final targetMs = val.toInt();
                            setState(() {
                              _isScrubbing = false;
                              _currentPosMs = targetMs;
                              _lastObservedPositionMs = targetMs;
                              _lastPositionAdvanceAt = DateTime.now();
                            });
                            await controller.seekTo(
                              Duration(milliseconds: targetMs),
                            );
                            await _ttsScheduler.onSeek(targetMs);
                            if (_wasPlayingBeforeScrub) {
                              await controller.play();
                            }
                            _syncTtsWithVideo();
                          },
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
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    if (duration.inHours > 0) {
      return '${twoDigits(duration.inHours)}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  String _formatSpeed(double speed) {
    if (speed == speed.roundToDouble()) {
      return speed.toInt().toString();
    }
    return speed.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '');
  }
}
