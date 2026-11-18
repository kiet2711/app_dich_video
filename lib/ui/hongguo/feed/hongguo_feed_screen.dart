import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:dio/dio.dart';
import 'package:media_kit/media_kit.dart';
import 'package:convert/convert.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../../../data/model/history_item.dart';
import '../../../data/model/subtitle_document.dart';
import '../../../data/model/voice_model.dart';
import '../../../data/model/watch_later_item.dart';
import '../../../data/repository/history_repository.dart';
import '../../../data/repository/settings_repository.dart';
import '../../../data/repository/watch_later_repository.dart';
import '../../../domain/ai/live/live_pcm_stream_extractor.dart';
import '../../../domain/ai/live/live_stream_translator.dart';
import '../../../domain/ai/offline_mlkit_translator.dart';
import '../../../domain/media/audio_extractor.dart';
import '../../../domain/media/hongguo/hongguo_cloud_account_service.dart';
import '../../../domain/media/hongguo/hongguo_codec_capabilities.dart';
import '../../../domain/media/hongguo/hongguo_discovery_service.dart';
import '../../../domain/media/hongguo/hongguo_local_engine.dart';
import '../../../domain/media/hongguo/hongguo_playback_routes.dart';
import '../../../domain/media/hongguo/hongguo_remote_video.dart';
import '../../../domain/media/hongguo/hongguo_similar_engine.dart';
import '../../../domain/media/hongguo/hongguo_stream_proxy_server.dart';
import '../hongguo_related_sheet.dart';
import '../../../domain/media/hongguo_resolver.dart';
import '../../../domain/media/multi_thread_downloader.dart';
import '../../../domain/media/network_header_helper.dart';
import '../../../domain/media/video_cache_manager.dart';
import '../../../domain/pipeline/subtitling_pipeline.dart';
import '../../../domain/tts/audio_file_validator.dart';
import '../../../domain/tts/tts_cache_helper.dart';
import '../../../domain/tts/tts_generation_manager.dart';
import '../../../player/app_player_controller.dart';
import '../../../player/tts_audio_scheduler.dart';
import '../../player/dual_volume_sheet.dart';
import '../../player/live_translate_sheet.dart';
import '../../player/subtitle_control_sheet.dart';
import '../../player/subtitle_overlay.dart';
import '../../settings/settings_screen.dart';
import '../../theme/app_theme.dart';

/// Dữ liệu của một trang trong Feed
class FeedDramaPageItem {
  final HongguoDramaDetail detail;
  final int episodeIndex;
  final String vid;

  const FeedDramaPageItem({
    required this.detail,
    required this.episodeIndex,
    required this.vid,
  });
}

/// Nguồn phát video trực tiếp kèm key giải mã FFmpeg native
class _FeedPlaybackSource {
  final String url;
  final String? decryptionKey;
  final Map<String, String> headers;
  final HongguoVideoInfo? videoInfo;
  final String vid;
  final String seriesId;
  final int episodeIndex;

  const _FeedPlaybackSource({
    required this.url,
    this.decryptionKey,
    this.headers = const {},
    this.videoInfo,
    this.vid = '',
    this.seriesId = '',
    this.episodeIndex = 1,
  });
}

/// Màn hình lướt video ngắn Hồng Quả dạng Shorts / TikTok Feed
/// Thiết kế chuẩn 90% giao diện gốc ByteDance / Douyin Short Drama:
/// - Hai chế độ liền mạch: Lướt khám phá (Discover Feed) và Xem trọn bộ (Drama Episode Mode)
/// - Bottom Sheet chọn tập chuẩn ByteDance với phân trang dải tập (1-30, 31-60...), lưới 6 cột và icon sóng nhạc 'ıll'
/// - Thanh tua Scrubber cảm ứng mượt mà với bong bóng thời gian thực
/// - Bộ điều tốc độ phát (1.0x, 1.25x, 1.5x, 2.0x) và nút xoay toàn màn hình
class HongguoFeedScreen extends StatefulWidget {
  final HongguoDramaDetail? initialDrama;
  final int initialEpisodeIndex;
  final int? initialPositionMs;
  final List<HongguoDramaItem>? discoverDramas;

  const HongguoFeedScreen({
    super.key,
    this.initialDrama,
    this.initialEpisodeIndex = 1,
    this.initialPositionMs,
    this.discoverDramas,
  });

  @override
  State<HongguoFeedScreen> createState() => _HongguoFeedScreenState();
}

class _HongguoFeedScreenState extends State<HongguoFeedScreen>
    with SingleTickerProviderStateMixin {
  final HongguoResolver _resolver = HongguoResolver();
  late PageController _pageController;

  // Danh sách các trang hiện đang hiển thị
  final List<FeedDramaPageItem> _feedItems = [];
  int _currentIndex = 0;
  bool _isLoadingMore = false;

  // Quản lý chế độ: Đang lướt khám phá nhiều phim (false) hay đang xem các tập của 1 phim (true)
  bool _isDramaEpisodeMode = false;
  HongguoDramaDetail? _currentDramaDetail;
  // Lưu lại danh sách khám phá để quay về khi bấm Back
  List<FeedDramaPageItem> _savedDiscoverItems = [];
  int _savedDiscoverIndex = 0;

  // Quản lý 4 Tab khám phá giống app Hồng Quả gốc:
  // 'follow' (Quan tâm) | 'comic' (Mạn kịch) | 'real' (Người thật) | 'discover' (Đề xuất)
  static const String _tabFollow = 'follow';
  static const String _tabComic = 'comic';
  static const String _tabReal = 'real';
  static const String _tabDiscover = 'discover';

  String _currentFeedTab = _tabDiscover;
  HongguoDiscoveryCursor? _comicCursor;
  HongguoDiscoveryCursor? _realCursor;
  HongguoDiscoverySelection? _comicSelectionOverride;
  HongguoDiscoverySelection? _realSelectionOverride;
  int _followSeedOffset = 0;

  void _saveFeedPreferences() {
    if (_settings == null || _isDramaEpisodeMode) return;
    _settings!.hongguoFeedTab = _currentFeedTab;
  }

  // Lưu vị trí video đang xem của từng tab để khôi phục mượt mà như TikTok
  final Map<String, int> _tabCurrentIndices = {
    _tabFollow: 0,
    _tabComic: 0,
    _tabReal: 0,
    _tabDiscover: 0,
  };

  // Cache danh sách cho từng tab để chuyển qua lại mượt mà không phải tải lại
  final List<FeedDramaPageItem> _followFeedItems = [];
  final List<FeedDramaPageItem> _comicFeedItems = [];
  final List<FeedDramaPageItem> _realFeedItems = [];
  final List<FeedDramaPageItem> _discoverFeedItems = [];

  // Hai player luân phiên: player hiện tại phát, player dự phòng mở sẵn trang kế.
  // Mỗi trang có texture riêng nên kéo giữ giữa hai trang không phải đổi media
  // trên cùng một surface.
  AppPlayerController? _activeController;
  String? _activeMediaKey;
  AppPlayerController? _standbyController;
  String? _standbyMediaKey;
  bool _standbyReady = false;
  int _standbyRequestId = 0;
  int? _activePageIndex;
  int _dramaEpisodeSessionKey = 0;
  int _feedGeneration = 0;
  int _activationRequestId = 0;
  Future<void> _playerSwitchTail = Future<void>.value();
  Future<void> _standbySwitchTail = Future<void>.value();

  // Nguồn phát trực tiếp (URL + Content Key CENC) đã nạp trước trong RAM
  final Map<String, _FeedPlaybackSource> _preloadedSources = {};
  final Set<String> _preloadingMediaKeys = {};

  // Bộ bảo vệ băng thông và nạp trước bậc thang (Bandwidth Gatekeeper)
  CancelToken? _cascadingPreloadCancelToken;

  void _cancelCascadingPreload() {
    final token = _cascadingPreloadCancelToken;
    if (token != null && !token.isCancelled) {
      token.cancel('Bandwidth gatekeeper: prioritizing active stream');
    }
    _cascadingPreloadCancelToken = null;
  }

  void _scheduleCascadingPreloadIfNeeded() {
    if (!mounted || _isPlayerBuffering || _activeController == null) return;
    if (!_activeController!.value.isPlaying || _isManuallyPaused) return;
    Future.delayed(const Duration(milliseconds: 350), () {
      if (!mounted || _isPlayerBuffering || _activeController == null) return;
      if (!_activeController!.value.isPlaying || _isManuallyPaused) return;
      if (_cascadingPreloadCancelToken == null || _cascadingPreloadCancelToken!.isCancelled) {
        unawaited(_preloadAheadEpisodes(_currentIndex));
      }
    });
  }

  // Watchdog giám sát chống đứng hình 1s & hạ cấp tự động
  Timer? _stallWatchdog;
  Duration _lastObservedPos = Duration.zero;
  int _stallTickCount = 0;
  String _preferredQuality = '1080';
  HongguoVideoInfo? _activeVideoInfo;
  final Set<String> _excludedRenditionKeys = <String>{};
  int _downgradeAttempts = 0;
  bool _isRecoveringDowngrade = false;
  StreamSubscription<String>? _errorSub;

  bool _isLoadingVideo = false;
  bool _showLoadingIndicator = false;
  bool _isPlayerBuffering = false;
  String? _errorMessage;
  bool _isManuallyPaused = false;
  bool _showPlayPauseAnim = false;
  Timer? _loadingIndicatorTimer;

  // Animation thả tim khi double tap
  bool _showHeartAnim = false;
  Offset _heartAnimPos = Offset.zero;

  // Tốc độ phát video
  double _playbackSpeed = 1.0;

  // Trạng thái kéo thanh tua (Scrubber)
  bool _isScrubbing = false;
  double _scrubValue = 0.0; // 0.0 -> 1.0

  // Chế độ xoay màn hình ngang
  bool _isLandscapeFullscreen = false;

  // Chế độ ẩn toàn bộ giao diện để xem không bị che (Clean View Mode)
  bool _isCleanMode = false;
  double _edgeSwipeDistance = 0.0;

  // Quản lý mở rộng mô tả phim
  bool _isDescriptionExpanded = false;

  // Subscriptions của Player
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _bufferingSub;
  Duration _currentPos = Duration.zero;
  Duration _currentDur = Duration.zero;
  final ValueNotifier<int> _playbackRevision = ValueNotifier<int>(0);

  // Cấu hình ứng dụng và phụ đề
  SettingsRepository? _settings;

  // Quản lý Phụ đề & Lồng tiếng trực tiếp trên Feed (Key là duy nhất: {seriesId}_ep{episodeIndex})
  final Map<String, SubtitleDocument> _episodeDocuments = {};

  /// Định danh duy nhất cho tài liệu phụ đề của từng video
  String _getVideoDocKey(FeedDramaPageItem item) {
    return '${item.detail.seriesId}_ep${item.episodeIndex}';
  }

  bool _isTranslationEnabled = true;
  final Set<String> _translatingTitles = <String>{};
  final Set<String> _translatingIntros = <String>{};
  bool _showSubtitles = true;
  bool _isTtsActive = false;
  TtsAudioScheduler? _ttsScheduler;
  LiveStreamTranslator? _liveTranslator;
  bool _waitingLiveWarmupResume = false;
  Timer? _liveWarmupTimeoutTimer;

  // Trạng thái dịch trực tiếp của tập hiện tại
  bool _isTranslatingCurrent = false;
  bool _translatingWithTts = false;
  double _translationProgress = 0.0;
  String _translationStatus = '';

  // Quản lý Tự động chuyển tập và Dịch trước ngầm (Pre-translation Queue)
  bool _isAutoNextEpisode = false;
  int _preTranslateCount = 2;
  String _preTranslateMode = 'sub_and_tts'; // 'sub_and_tts' | 'sub_only'
  bool _isPreTranslating = false;
  StreamSubscription<bool>? _completedSub;
  int? _pendingInitialSeekMs;

  @override
  void initState() {
    super.initState();
    _pendingInitialSeekMs = widget.initialPositionMs;
    _initFeedData();
    _pageController = PageController(initialPage: _currentIndex);
    _activeController = AppPlayerController(bufferSizeMb: 32);

    _listenToPlayerStreams();
    _startStallWatchdog();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _bootstrapFeed();
    });
  }

  String _mediaKey(FeedDramaPageItem item) =>
      '${item.detail.seriesId}:${item.episodeIndex}';

  bool _isCurrentMedia(int index, String mediaKey) {
    return mounted &&
        index == _currentIndex &&
        index >= 0 &&
        index < _feedItems.length &&
        _mediaKey(_feedItems[index]) == mediaKey;
  }

  bool _isActivationCurrent({
    required int requestId,
    required int feedGeneration,
    required String mediaKey,
  }) {
    return mounted &&
        requestId == _activationRequestId &&
        feedGeneration == _feedGeneration &&
        _currentIndex >= 0 &&
        _currentIndex < _feedItems.length &&
        _mediaKey(_feedItems[_currentIndex]) == mediaKey;
  }

  void _disposeStandbyPlayer() {
    _standbyRequestId++;
    _standbySwitchTail = Future<void>.value();
    final controller = _standbyController;
    _standbyController = null;
    _standbyMediaKey = null;
    _standbyReady = false;
    if (controller != null && !identical(controller, _activeController)) {
      controller.dispose();
    }
  }

  void _replacePageController(int initialPage) {
    final oldController = _pageController;
    _pageController = PageController(initialPage: initialPage);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      oldController.dispose();
    });
  }

  Future<void> _bootstrapFeed() async {
    unawaited(HongguoCloudAccountService.instance.initialize());
    final settings = await SettingsRepository.getInstance();
    if (!mounted) return;
    final targetFeedTab = settings.hongguoFeedTab;

    setState(() {
      _settings = settings;
      _isTranslationEnabled = settings.hongguoTranslateEnabled;
      _preferredQuality = settings.hongguoPreferredQuality;
      _playbackSpeed = settings.hongguoPlaybackSpeed;
      _liveTranslator?.dispose();
      _liveTranslator = _createLiveTranslator(settings);
      _isAutoNextEpisode = settings.hongguoAutoNextEpisode;
      _preTranslateCount = settings.hongguoPreTranslateCount;
      _preTranslateMode = settings.hongguoPreTranslateMode;
      if (settings.subtitleOffsetY == 0.0) {
        settings.subtitleOffsetY = 90.0;
      }
    });

    final seen = settings.hongguoSeenSeriesIds.toSet();
    final unseenCount = _feedItems
        .where((it) => !seen.contains(it.detail.seriesId))
        .length;
    final shouldReload =
        _feedItems.isEmpty ||
        unseenCount < 6 ||
        targetFeedTab != _currentFeedTab;

    if (!_isDramaEpisodeMode && shouldReload) {
      await _switchFeedTab(targetFeedTab, forceReload: true);
      return;
    }
    _prefetchAdjacentTranslations(_currentIndex);
    await _activatePage(_currentIndex);
  }

  String _displayTitleFor(HongguoDramaDetail detail) {
    if (!_isTranslationEnabled) return detail.title;
    return OfflineMlKitTranslator.getCachedTitle(detail.title) ?? detail.title;
  }

  String _displayIntroFor(HongguoDramaDetail detail) {
    if (detail.intro.isEmpty) return '';
    if (!_isTranslationEnabled) return detail.intro;
    return OfflineMlKitTranslator.getCachedIntro(detail.intro) ?? detail.intro;
  }

  void _ensureMetadataTranslated(FeedDramaPageItem item) {
    if (!_isTranslationEnabled || !mounted) return;
    final rawTitle = item.detail.title.trim();
    if (rawTitle.isNotEmpty &&
        OfflineMlKitTranslator.getCachedTitle(rawTitle) == null &&
        _translatingTitles.add(rawTitle)) {
      OfflineMlKitTranslator.translateHongguoTitle(rawTitle).then((_) {
        _translatingTitles.remove(rawTitle);
        if (mounted && _isTranslationEnabled) {
          setState(() {});
        }
      }).catchError((_) {
        _translatingTitles.remove(rawTitle);
      });
    }

    final rawIntro = item.detail.intro.trim();
    if (rawIntro.isNotEmpty &&
        OfflineMlKitTranslator.getCachedIntro(rawIntro) == null &&
        _translatingIntros.add(rawIntro)) {
      OfflineMlKitTranslator.translateHongguoIntro(rawIntro).then((_) {
        _translatingIntros.remove(rawIntro);
        if (mounted && _isTranslationEnabled) {
          setState(() {});
        }
      }).catchError((_) {
        _translatingIntros.remove(rawIntro);
      });
    }
  }

  void _prefetchAdjacentTranslations(int centerIndex) {
    if (!_isTranslationEnabled || !mounted) return;
    for (var offset = 0; offset <= 1; offset++) {
      final idx = centerIndex + offset;
      if (idx >= 0 && idx < _feedItems.length) {
        _ensureMetadataTranslated(_feedItems[idx]);
      }
    }
  }

  void _toggleFeedTranslation({bool showSnackBar = true}) {
    HapticFeedback.lightImpact();
    final nextVal = !_isTranslationEnabled;
    setState(() {
      _isTranslationEnabled = nextVal;
    });
    _settings?.hongguoTranslateEnabled = nextVal;
    if (nextVal) {
      _prefetchAdjacentTranslations(_currentIndex);
    }
    if (!showSnackBar) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              nextVal ? Icons.translate_rounded : Icons.translate_outlined,
              color: nextVal ? AppColors.primaryEmerald : Colors.white70,
              size: 16,
            ),
            const SizedBox(width: 8),
            Text(
              nextVal
                  ? 'Đã bật tự động dịch tiêu đề & mô tả'
                  : 'Đã tắt dịch — hiển thị nguyên văn tiếng Trung',
              style: const TextStyle(fontSize: 12.5),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF22242A),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  final math.Random _rng = math.Random();

  /// Tạo item lướt ngẫu nhiên từ tập 1-10 theo yêu cầu người dùng
  FeedDramaPageItem _createFeedDramaItem(HongguoDramaItem drama) {
    final detail = _dramaItemToDetail(drama);
    final totalEp = drama.episodeCount > 0
        ? drama.episodeCount
        : (drama.vidList.isNotEmpty ? drama.vidList.length : 1);
    final maxEp = math.min(10, totalEp);
    final randomEp = maxEp > 1 ? (_rng.nextInt(maxEp) + 1) : 1;
    final vid = (drama.vidList.length >= randomEp)
        ? drama.vidList[randomEp - 1]
        : (drama.vidList.isNotEmpty ? drama.vidList.first : '');

    return FeedDramaPageItem(detail: detail, episodeIndex: randomEp, vid: vid);
  }

  /// Ưu tiên hiển thị các phim chưa xem lên đầu, loại bỏ các phim đã xem để tránh lặp lại
  List<HongguoDramaItem> _prioritizeUnwatchedDramas(
    List<HongguoDramaItem> dramas, {
    bool strictFilter = false,
  }) {
    if (dramas.isEmpty) return dramas;
    final seen = _settings?.hongguoSeenSeriesIds.toSet() ?? <String>{};
    if (seen.isEmpty) return dramas;

    final unwatched = <HongguoDramaItem>[];
    final watched = <HongguoDramaItem>[];

    for (final d in dramas) {
      if (seen.contains(d.seriesId)) {
        watched.add(d);
      } else {
        unwatched.add(d);
      }
    }

    // Nếu có đủ phim chưa xem (>= 6) hoặc yêu cầu lọc chặt chẽ, loại bỏ hoàn toàn phim đã xem
    if (unwatched.length >= 6 || strictFilter) {
      return unwatched;
    }

    final rng = math.Random();
    final shuffledWatched = List<HongguoDramaItem>.from(watched)..shuffle(rng);
    return [...unwatched, ...shuffledWatched];
  }

  void _initFeedData() {
    if (widget.initialDrama != null) {
      _isDramaEpisodeMode = true;
      _currentDramaDetail = widget.initialDrama;
      _populateDramaEpisodes(
        _currentDramaDetail!,
        initialEpisode: widget.initialEpisodeIndex,
      );
    } else if (widget.discoverDramas != null &&
        widget.discoverDramas!.isNotEmpty) {
      _isDramaEpisodeMode = false;
      final sorted = _prioritizeUnwatchedDramas(
        List<HongguoDramaItem>.from(widget.discoverDramas!),
      );
      for (final drama in sorted) {
        final item = _createFeedDramaItem(drama);
        _feedItems.add(item);
        _discoverFeedItems.add(item);
      }
      _currentIndex = 0;
    }
  }

  HongguoDramaDetail _dramaItemToDetail(HongguoDramaItem drama) {
    return HongguoDramaDetail(
      seriesId: drama.seriesId,
      title: drama.title,
      cover: drama.cover,
      intro: drama.intro,
      totalEpisodes: drama.episodeCount,
      tags: drama.tags,
      sourceCategory: drama.sourceCategory,
      categoryIds: drama.categoryIds,
      episodes: [
        for (var i = 0; i < drama.vidList.length; i++)
          HongguoEpisodeItem(
            index: i + 1,
            vid: drama.vidList[i],
            title: 'Tập ${i + 1}',
          ),
      ],
    );
  }

  void _populateDramaEpisodes(
    HongguoDramaDetail detail, {
    int initialEpisode = 1,
  }) {
    _disposeStandbyPlayer();
    _feedGeneration++;
    _activationRequestId++;
    _feedItems.clear();
    _preloadedSources.clear();
    _preloadingMediaKeys.clear();

    final episodes = detail.episodes;
    final total = episodes.isNotEmpty
        ? episodes.length
        : (detail.totalEpisodes > 0 ? detail.totalEpisodes : 1);

    for (var i = 1; i <= total; i++) {
      final vid = (episodes.isNotEmpty && i <= episodes.length)
          ? episodes[i - 1].vid
          : '';
      _feedItems.add(
        FeedDramaPageItem(detail: detail, episodeIndex: i, vid: vid),
      );
    }

    _currentIndex = (initialEpisode - 1).clamp(
      0,
      math.max(0, _feedItems.length - 1),
    );
  }

  void _listenToPlayerStreams() {
    _posSub?.cancel();
    _bufferingSub?.cancel();
    _completedSub?.cancel();
    _errorSub?.cancel();

    _errorSub = _activeController?.player.stream.error.listen((errMsg) {
      if (!mounted || errMsg.trim().isEmpty || _isRecoveringDowngrade) return;
      debugPrint('[HongguoFeedScreen] ⚠️ Player stream error: $errMsg');
      unawaited(_attemptFeedAutoDowngrade(_currentIndex, reason: errMsg));
    });

    _posSub = _activeController?.player.stream.position.listen((pos) {
      if (!mounted) return;
      final dur = _activeController?.player.state.duration ?? Duration.zero;
      if (!_isScrubbing) {
        _currentPos = pos;
        _currentDur = dur;
        _playbackRevision.value++;

        if (_isTtsActive &&
            _ttsScheduler != null &&
            _activeController != null) {
          _ttsScheduler!.onVideoStateUpdate(
            positionMs: pos.inMilliseconds,
            isPlaying: _activeController!.value.isPlaying && !_isManuallyPaused,
            isBuffering: _isPlayerBuffering,
            isScrubbing: _isScrubbing,
            playbackSpeed: _playbackSpeed,
          );
        }
        if (_liveTranslator != null &&
            _liveTranslator!.isEnabled &&
            _activeController != null) {
          final isPlaying =
              _activeController!.value.isPlaying && !_isManuallyPaused;
          if (_waitingLiveWarmupResume && isPlaying) {
            _cancelLiveWarmupPause(finishTranslatorWarmup: true);
          }
          _liveTranslator!.onVideoStateUpdate(
            positionMs: pos.inMilliseconds,
            isPlaying: _waitingLiveWarmupResume ? true : isPlaying,
            isBuffering: _isPlayerBuffering,
            isScrubbing: _isScrubbing,
            playbackSpeed: _playbackSpeed,
          );
        }
      }
    });

    _bufferingSub = _activeController?.player.stream.buffering.listen((
      buffering,
    ) {
      if (!mounted) return;
      _isPlayerBuffering = buffering;
      if (buffering) {
        _stallTickCount = 0;
        _cancelCascadingPreload(); // 🛑 BẢO VỆ BĂNG THÔNG: Dừng ngay preload khi video chính bị khựng!
      } else {
        _scheduleCascadingPreloadIfNeeded();
      }
      if (_isTtsActive && _ttsScheduler != null && _activeController != null) {
        _ttsScheduler!.onVideoStateUpdate(
          positionMs: _currentPos.inMilliseconds,
          isPlaying: _activeController!.value.isPlaying && !_isManuallyPaused,
          isBuffering: buffering,
          isScrubbing: _isScrubbing,
          playbackSpeed: _playbackSpeed,
        );
      }
      if (_liveTranslator != null &&
          _liveTranslator!.isEnabled &&
          _activeController != null) {
        _liveTranslator!.onVideoStateUpdate(
          positionMs: _currentPos.inMilliseconds,
          isPlaying: _waitingLiveWarmupResume
              ? true
              : (_activeController!.value.isPlaying && !_isManuallyPaused),
          isBuffering: buffering,
          isScrubbing: _isScrubbing,
          playbackSpeed: _playbackSpeed,
        );
      }
    });

    _completedSub = _activeController?.player.stream.completed.listen((
      completed,
    ) {
      if (completed && _isAutoNextEpisode && !_isScrubbing && mounted) {
        _handleAutoNextEpisode();
      }
    });
  }

  @override
  void dispose() {
    _cancelCascadingPreload();
    _activationRequestId++;
    _feedGeneration++;
    _standbyRequestId++;
    _completedSub?.cancel();
    _errorSub?.cancel();
    _stallWatchdog?.cancel();
    unawaited(HongguoCloudAccountService.instance.flushPendingProgress());
    _loadingIndicatorTimer?.cancel();
    _liveWarmupTimeoutTimer?.cancel();
    _posSub?.cancel();
    _bufferingSub?.cancel();
    _pageController.dispose();
    _ttsScheduler?.dispose();
    _ttsScheduler = null;
    _liveTranslator?.dispose();
    _liveTranslator = null;
    final standbyController = _standbyController;
    _standbyController = null;
    if (standbyController != null &&
        !identical(standbyController, _activeController)) {
      standbyController.dispose();
    }
    _activeController?.dispose();
    _activeController = null;
    _preloadedSources.clear();
    _preloadingMediaKeys.clear();
    _playbackRevision.dispose();
    // Khôi phục hướng màn hình dọc nếu đang xoay ngang
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    super.dispose();
  }

  void _startStallWatchdog() {
    _stallWatchdog?.cancel();
    _stallWatchdog = Timer.periodic(const Duration(milliseconds: 350), (_) {
      if (!mounted ||
          _activeController == null ||
          _isManuallyPaused ||
          _isLoadingVideo) {
        return;
      }
      final player = _activeController!.player;
      final isPlaying = _activeController!.value.isPlaying;
      final currentPos = player.state.position;

      if (_isPlayerBuffering) {
        _stallTickCount = 0;
        _lastObservedPos = currentPos;
        return;
      }

      if (isPlaying &&
          currentPos > Duration.zero &&
          currentPos == _lastObservedPos) {
        _stallTickCount++;
        if (_stallTickCount == 4 || _stallTickCount == 12) {
          debugPrint(
            '[HongguoFeedScreen] ⚡ Phục hồi phát video tại $currentPos',
          );
          player.play();
        } else if (_stallTickCount >= 55 && !_isRecoveringDowngrade) {
          _stallTickCount = 0;
          unawaited(_attemptFeedAutoDowngrade(_currentIndex, reason: 'stall_20s'));
        }
      } else {
        _stallTickCount = 0;
        _lastObservedPos = currentPos;
      }
    });
  }

  /// Thử hạ cấp chất lượng / chuyển từ HEVC sang H.264 tối đa 2 lần khi gặp lỗi codec hoặc đơ mạng.
  Future<void> _attemptFeedAutoDowngrade(
    int index, {
    String reason = '',
  }) async {
    if (!mounted ||
        _isRecoveringDowngrade ||
        _downgradeAttempts >= 2 ||
        index < 0 ||
        index >= _feedItems.length) {
      return;
    }
    final info = _activeVideoInfo;
    final curRendition = info?.selectedRendition;
    if (info == null || curRendition == null || info.ladder == null) return;

    _isRecoveringDowngrade = true;
    try {
      HongguoPlaybackRoutes.instance.markFailed(info.realMainUrl);
      await HongguoCodecCapabilities.instance.learnFailure(curRendition);
      _excludedRenditionKeys.add(curRendition.uniqueKey);

      final support = await HongguoCodecCapabilities.instance.getHardwareSupport();
      final next = info.ladder!.selectDowngrade(
        curRendition,
        hardwareSupport: support,
        lessons: HongguoCodecCapabilities.instance.lessons,
        excludedKeys: _excludedRenditionKeys,
      );
      if (next == null) return;

      _downgradeAttempts++;
      final resumePos = _activeController?.value.position ?? Duration.zero;
      final downgradedInfo = info.downgradeWith(
        next,
        preferredQuality: _preferredQuality,
      );
      if (downgradedInfo == null) return;

      final item = _feedItems[index];
      final mediaKey = _mediaKey(item);
      if (_liveTranslator?.isEnabled == true && downgradedInfo.isDrmProtected) {
        HongguoStreamProxyServer.instance.registerVideoInfo(
          vid: item.vid,
          seriesId: item.detail.seriesId,
          episodeIndex: item.episodeIndex,
          info: downgradedInfo,
        );
      }
      _activeVideoInfo = downgradedInfo;
      _preloadedSources[mediaKey] = _FeedPlaybackSource(
        url: (_liveTranslator?.isEnabled == true && downgradedInfo.isDrmProtected)
            ? HongguoStreamProxyServer.instance.getStreamUrl(
                vid: item.vid,
                seriesId: item.detail.seriesId,
                episodeIndex: item.episodeIndex,
              )
            : downgradedInfo.realMainUrl,
        decryptionKey: (_liveTranslator?.isEnabled == true)
            ? null
            : (downgradedInfo.isDrmProtected
                ? downgradedInfo.contentKeyHex
                : null),
        videoInfo: downgradedInfo,
        vid: item.vid,
        seriesId: item.detail.seriesId,
        episodeIndex: item.episodeIndex,
      );
      _pendingInitialSeekMs = resumePos.inMilliseconds;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Tự động chuyển luồng ${next.normalizedCodec.toUpperCase()} ${next.qualityLabel} để phát mượt hơn',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      await _activatePage(index);
    } catch (e) {
      debugPrint('[HongguoFeedScreen] Auto-downgrade lỗi: $e');
    } finally {
      _isRecoveringDowngrade = false;
    }
  }

  Future<void> _selectFeedQuality(String qualityKey) async {
    if (_preferredQuality == qualityKey) return;
    setState(() {
      _preferredQuality = qualityKey;
    });
    _settings?.hongguoPreferredQuality = qualityKey;
    _excludedRenditionKeys.clear();
    _downgradeAttempts = 0;
    _disposeStandbyPlayer();
    _preloadedSources.clear();
    if (_currentIndex >= 0 && _currentIndex < _feedItems.length) {
      _pendingInitialSeekMs =
          _activeController?.value.position.inMilliseconds ?? 0;
      await _activatePage(_currentIndex, forceReload: true);
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Đã chuyển chất lượng: ${qualityKey == "auto" ? "Tự động theo thiết bị" : "${qualityKey}P"}',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// Mở bộ chọn chất lượng stream ngay trên màn hình Feed.
  Future<void> _showFeedQualitySheet() async {
    final availableTiers = _activeVideoInfo?.ladder?.availableQualityTiers ??
        const <String>['1080', '720', '480', '360'];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF181A22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final options = <({String key, String title})>[
          for (final t in availableTiers)
            (key: t, title: '${t}P${t == "1080" ? " (Sắc nét)" : ""}'),
          const (key: 'auto', title: 'Tự động theo thiết bị'),
        ];
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Chọn chất lượng phát Hồng Quả',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                ...options.map((opt) {
                  final selected = _preferredQuality == opt.key;
                  return ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    leading: Icon(
                      selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      color:
                          selected ? AppColors.primaryEmerald : Colors.white54,
                    ),
                    title: Text(
                      opt.title,
                      style: TextStyle(
                        color: selected
                            ? AppColors.primaryEmerald
                            : Colors.white,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.normal,
                      ),
                    ),
                    onTap: () async {
                      Navigator.of(ctx).pop();
                      await _selectFeedQuality(opt.key);
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Kích hoạt và phát video cho trang được chọn
  void _afterSuccessfulActivation(int index) {
    unawaited(_checkHistoryForEpisode(index));
    _downgradeAttempts = 0;

    if (index >= 0 && index < _feedItems.length) {
      final item = _feedItems[index];
      final info = _preloadedSources[_mediaKey(item)]?.videoInfo;
      if (info != null) {
        _activeVideoInfo = info;
      }
      final posMs = _activeController?.value.position.inMilliseconds ?? 0;
      final durMs = _activeController?.value.duration.inMilliseconds ??
          info?.durationMs ??
          0;
      HongguoCloudAccountService.instance.scheduleProgressUpload(
        HongguoCloudProgress(
          seriesId: item.detail.seriesId,
          title: item.detail.title,
          cover: item.detail.cover,
          episodeId: item.vid,
          episodeIndex: item.episodeIndex,
          positionMs: posMs,
          durationMs: durMs,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
        episodeCount: math.max(
          item.detail.totalEpisodes,
          item.detail.episodes.length,
        ),
      );
      if (!_isDramaEpisodeMode &&
          item.detail.totalEpisodes <= 1 &&
          item.detail.episodes.length <= 1) {
        unawaited(_refreshMissingEpisodeCount(index));
      }
    }

    if (!_isDramaEpisodeMode && index >= 0 && index < _feedItems.length) {
      _settings?.addHongguoSeenSeriesId(_feedItems[index].detail.seriesId);
    }

    if (_liveTranslator?.isEnabled == true) {
      final startMs = _pendingInitialSeekMs ?? _currentPos.inMilliseconds;
      unawaited(
        _syncLiveTranslatorForIndex(index, startPosMs: startMs),
      );
      unawaited(
        _activeController?.setVolume(
          _settings?.originalVideoVolume ?? 0.25,
        ),
      );
    }

    _maintainFeedWindow(index);
    if (_isAutoNextEpisode) {
      _triggerPreTranslationQueue();
    }
  }

  Future<void> _restoreActivePlaybackAfterStandbyOpen(
    AppPlayerController standbyController,
  ) async {
    // Kiểm tra ngay và kiểm tra lại sau một nhịp vì media_kit cập nhật trạng thái
    // playing bất đồng bộ sau lệnh pause/audio-focus trên một số máy Android.
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      final activeController = _activeController;
      if (!mounted ||
          activeController == null ||
          identical(activeController, standbyController) ||
          _isManuallyPaused ||
          _isLoadingVideo ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
          _activePageIndex != _currentIndex ||
          _currentIndex < 0 ||
          _currentIndex >= _feedItems.length ||
          _activeMediaKey != _mediaKey(_feedItems[_currentIndex])) {
        return;
      }

      if (!activeController.player.state.playing) {
        debugPrint(
          '[HongguoFeedScreen] Khôi phục active player sau khi mở standby',
        );
        await activeController.player.play();
      }
    }
  }

  Future<bool> _activatePreparedStandby({
    required int index,
    required int requestId,
    required int feedGeneration,
    required String mediaKey,
  }) async {
    final preparedController = _standbyController;
    if (!_standbyReady ||
        _standbyMediaKey != mediaKey ||
        preparedController == null ||
        preparedController.isDisposed) {
      return false;
    }

    final previousController = _activeController;
    _standbyRequestId++;
    _activeController = preparedController;
    _activeMediaKey = mediaKey;
    _standbyController = previousController;
    _standbyMediaKey = null;
    _standbyReady = false;
    _listenToPlayerStreams();

    _loadingIndicatorTimer?.cancel();
    setState(() {
      _isLoadingVideo = false;
      _showLoadingIndicator = false;
      _errorMessage = null;
      _isManuallyPaused = false;
      _isDescriptionExpanded = false;
    });

    try {
      await previousController?.muteAndPause();
      await preparedController.unmuteAndPlay(
        rate: _playbackSpeed,
        playlistMode:
            _isAutoNextEpisode ? PlaylistMode.none : PlaylistMode.loop,
      );

      if (!_isActivationCurrent(
        requestId: requestId,
        feedGeneration: feedGeneration,
        mediaKey: mediaKey,
      )) {
        return true;
      }

      _afterSuccessfulActivation(index);
      unawaited(_preloadAheadEpisodes(index));
      return true;
    } catch (e) {
      debugPrint('[HongguoFeedScreen] Lỗi đổi sang player đã nạp sẵn: $e');
      return false;
    }
  }

  Future<void> _activatePage(int index, {bool forceReload = false}) async {
    if (!mounted || index < 0 || index >= _feedItems.length) return;

    final requestedMediaKey = _mediaKey(_feedItems[index]);
    if (!forceReload &&
        _activePageIndex == index &&
        _activeMediaKey == requestedMediaKey &&
        _activeController != null &&
        _activeController!.value.isPlaying) {
      return;
    }

    final requestId = ++_activationRequestId;
    final feedGeneration = _feedGeneration;
    final mediaKey = requestedMediaKey;
    _activePageIndex = index;
    _prefetchAdjacentTranslations(index);
    _cancelCascadingPreload();
    _loadingIndicatorTimer?.cancel();
    _currentPos = Duration.zero;
    _currentDur = Duration.zero;
    _isPlayerBuffering = false;
    _playbackRevision.value++;

    if (await _activatePreparedStandby(
      index: index,
      requestId: requestId,
      feedGeneration: feedGeneration,
      mediaKey: mediaKey,
    )) {
      return;
    }

    // Nếu người dùng đến trang khi player dự phòng vẫn đang mở, hủy bản mở
    // dở để active player không phải cạnh tranh decoder/network cho cùng video.
    if (_standbyMediaKey == mediaKey) {
      _disposeStandbyPlayer();
    }

    setState(() {
      _isLoadingVideo = true;
      _showLoadingIndicator = false;
      _errorMessage = null;
      _isManuallyPaused = false;
      _isDescriptionExpanded = false;
    });
    _loadingIndicatorTimer = Timer(const Duration(milliseconds: 400), () {
      if (_isActivationCurrent(
            requestId: requestId,
            feedGeneration: feedGeneration,
            mediaKey: mediaKey,
          ) &&
          _isLoadingVideo) {
        setState(() => _showLoadingIndicator = true);
      }
    });

    var item = _feedItems[index];

    try {
      // 1. Đảm bảo item có đầy đủ danh sách tập và vid thật của ByteDance trước khi nạp
      if (item.vid.isEmpty ||
          item.vid == item.detail.seriesId ||
          item.detail.episodes.isEmpty ||
          item.detail.episodes.length < item.episodeIndex) {
        try {
          final fullDetail = await _resolver.getDramaDetail(
            item.detail.seriesId,
          );
          if (fullDetail.episodes.isNotEmpty) {
            final epIdx = item.episodeIndex.clamp(
              1,
              fullDetail.episodes.length,
            );
            final realVid = fullDetail.episodes[epIdx - 1].vid;
            item = FeedDramaPageItem(
              detail: fullDetail,
              episodeIndex: epIdx,
              vid: realVid,
            );
            if (index < _feedItems.length &&
                _feedItems[index].detail.seriesId == fullDetail.seriesId) {
              _feedItems[index] = item;
            }
            _ensureMetadataTranslated(item);
            if (_isActivationCurrent(
              requestId: requestId,
              feedGeneration: feedGeneration,
              mediaKey: mediaKey,
            )) {
              setState(() {});
            }
          }
        } catch (e) {
          debugPrint(
            '[HongguoFeedScreen] Phân giải chi tiết phim thất bại: $e',
          );
        }
      }

      if (!_isActivationCurrent(
        requestId: requestId,
        feedGeneration: feedGeneration,
        mediaKey: mediaKey,
      )) {
        return;
      }

      // 2. Lấy nguồn phát trực tiếp (ưu tiên từ bộ đệm RAM đã nạp sẵn)
      _FeedPlaybackSource? source =
          forceReload ? null : _preloadedSources[mediaKey];
      if (source == null || source.url.isEmpty) {
        source = await _resolveEpisodeStreamSource(
          item,
          bypassCache: forceReload,
        );
        if (_isActivationCurrent(
          requestId: requestId,
          feedGeneration: feedGeneration,
          mediaKey: mediaKey,
        )) {
          _preloadedSources[mediaKey] = source;
        }
      }

      if (!_isActivationCurrent(
        requestId: requestId,
        feedGeneration: feedGeneration,
        mediaKey: mediaKey,
      )) {
        return;
      }

      if (_activeController == null || _activeController!.isDisposed) {
        _activeController = AppPlayerController(bufferSizeMb: 32);
        _listenToPlayerStreams();
      }

      // Gắn texture vào trang mới ngay trước khi mở media. Trạng thái loading
      // không che surface nên frame đầu hiện ngay khi player giải mã xong.
      _activeMediaKey = mediaKey;
      _activeVideoInfo = source.videoInfo;
      setState(() {});

      // 3. Tuần tự hóa thao tác open trên player. Request cũ đang open sẽ kết
      // thúc trước, nhưng chỉ request mới nhất được phép open/phát tiếp theo.
      final switchFuture = _playerSwitchTail.then<bool>((_) async {
        if (!_isActivationCurrent(
          requestId: requestId,
          feedGeneration: feedGeneration,
          mediaKey: mediaKey,
        )) {
          return false;
        }
        if (source!.url.startsWith('http://') ||
            source.url.startsWith('https://')) {
          await _activeController!.switchMedia(
            networkUrl: source.url,
            decryptionKey: source.decryptionKey,
            headers: source.headers.isNotEmpty
                ? source.headers
                : const {
                    'User-Agent':
                        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0',
                    'Referer': 'https://novel.snssdk.com/',
                  },
            play: false,
          );
        } else {
          await _activeController!.switchMedia(
            file: File(source.url),
            play: false,
          );
        }
        return _isActivationCurrent(
          requestId: requestId,
          feedGeneration: feedGeneration,
          mediaKey: mediaKey,
        );
      });
      _playerSwitchTail = switchFuture.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      final switched = await switchFuture;
      if (!switched) return;

      if (_isAutoNextEpisode) {
        await _activeController!.player.setPlaylistMode(PlaylistMode.none);
      } else {
        await _activeController!.player.setPlaylistMode(PlaylistMode.loop);
      }
      await _activeController!.player.setRate(_playbackSpeed);
      await _activeController!.player.play();

      if (!_isActivationCurrent(
        requestId: requestId,
        feedGeneration: feedGeneration,
        mediaKey: mediaKey,
      )) {
        return;
      }

      if (_pendingInitialSeekMs != null && _pendingInitialSeekMs! > 0) {
        final seekMs = _pendingInitialSeekMs!;
        _pendingInitialSeekMs = null;
        Future.delayed(const Duration(milliseconds: 120), () async {
          if (_activeController == null ||
              !_isActivationCurrent(
                requestId: requestId,
                feedGeneration: feedGeneration,
                mediaKey: mediaKey,
              )) {
            return;
          }
          try {
            await _activeController!.player.seek(
              Duration(milliseconds: seekMs),
            );
            _ttsScheduler?.onSeek(seekMs);
            if (_liveTranslator?.isEnabled == true) {
              unawaited(_liveTranslator!.onSeek(seekMs));
            }
          } catch (e) {
            debugPrint('[HongguoFeedScreen] initial seek error: $e');
          }
        });
      }

      // Kiểm tra tập hiện tại đã có phụ đề trong RAM hoặc Lịch sử chưa
      if (_isActivationCurrent(
        requestId: requestId,
        feedGeneration: feedGeneration,
        mediaKey: mediaKey,
      )) {
        _loadingIndicatorTimer?.cancel();
        setState(() {
          _isLoadingVideo = false;
          _showLoadingIndicator = false;
        });
      }

      // Mở sẵn N+1 trên player dự phòng và chuẩn bị metadata N+2.
      _afterSuccessfulActivation(index);
      unawaited(_preloadAheadEpisodes(index));
    } catch (e) {
      debugPrint('[HongguoFeedScreen] Lỗi kích hoạt tập $index: $e');
      if (_isActivationCurrent(
        requestId: requestId,
        feedGeneration: feedGeneration,
        mediaKey: mediaKey,
      )) {
        _loadingIndicatorTimer?.cancel();
        setState(() {
          _isLoadingVideo = false;
          _showLoadingIndicator = false;
          _errorMessage = 'Lỗi phát video: $e';
        });
      }
    }
  }

  /// Phân giải nguồn phát trực tiếp: Link CDN ByteDance + CENC Decryption Key (Giải mã phần cứng qua FFmpeg Native)
  Future<_FeedPlaybackSource> _resolveEpisodeStreamSource(
    FeedDramaPageItem item, {
    bool bypassCache = false,
  }) async {
    // 0. Đảm bảo item có vid thật trước khi gọi API
    if (item.vid.isEmpty ||
        item.vid == item.detail.seriesId ||
        item.detail.episodes.isEmpty ||
        item.detail.episodes.length < item.episodeIndex) {
      try {
        final fullDetail = await _resolver.getDramaDetail(item.detail.seriesId);
        if (fullDetail.episodes.isNotEmpty) {
          final epIdx = item.episodeIndex.clamp(1, fullDetail.episodes.length);
          final realVid = fullDetail.episodes[epIdx - 1].vid;
          item = FeedDramaPageItem(
            detail: fullDetail,
            episodeIndex: epIdx,
            vid: realVid,
          );
          final idx = _feedItems.indexWhere(
            (it) =>
                it.detail.seriesId == fullDetail.seriesId &&
                it.episodeIndex == epIdx,
          );
          if (idx != -1) {
            _feedItems[idx] = item;
          }
        }
      } catch (e) {
        debugPrint(
          '[HongguoFeedScreen] _resolveEpisodeStreamSource getDramaDetail failed: $e',
        );
      }
    }

    // 1. Kiểm tra cache hoàn chỉnh trên máy nếu có
    if (!bypassCache) {
      try {
        final cached = await VideoCacheManager.findCachedFile(
          url: '',
          seriesId: item.detail.seriesId,
          episodeIndex: item.episodeIndex,
        );
        if (cached != null &&
            cached.existsSync() &&
            cached.lengthSync() > 1024 * 50) {
          return _FeedPlaybackSource(
            url: cached.path,
            vid: item.vid,
            seriesId: item.detail.seriesId,
            episodeIndex: item.episodeIndex,
          );
        }
      } catch (_) {}
    }

    // 2. ƯU TIÊN SỐ 1 TUYỆT ĐỐI: Phân giải trực tiếp từ ByteDance API (720p/1080p, giải mã FFmpeg native)
    try {
      final info = await HongguoLocalEngine.resolveVideoInfo(
        item.vid,
        preferredQuality: _preferredQuality,
        excludedRenditionKeys: _excludedRenditionKeys,
      );
      if (info.realMainUrl.isNotEmpty) {
        if (info.isDrmProtected) {
          HongguoStreamProxyServer.instance.registerVideoInfo(
            vid: item.vid,
            info: info,
            seriesId: item.detail.seriesId,
            episodeIndex: item.episodeIndex,
          );
          if (_liveTranslator?.isEnabled == true) {
            await HongguoStreamProxyServer.instance.ensureStarted();
            final proxyUrl = HongguoStreamProxyServer.instance.getStreamUrl(
              vid: item.vid,
              seriesId: item.detail.seriesId,
              episodeIndex: item.episodeIndex,
            );
            return _FeedPlaybackSource(
              url: proxyUrl,
              videoInfo: info,
              vid: item.vid,
              seriesId: item.detail.seriesId,
              episodeIndex: item.episodeIndex,
            );
          }
        }
        return _FeedPlaybackSource(
          url: info.realMainUrl,
          decryptionKey: info.isDrmProtected ? info.contentKeyHex : null,
          videoInfo: info,
          vid: item.vid,
          seriesId: item.detail.seriesId,
          episodeIndex: item.episodeIndex,
          headers: const {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0',
            'Referer': 'https://novel.snssdk.com/',
          },
        );
      }
    } catch (e) {
      debugPrint(
        '[HongguoFeedScreen] resolveVideoInfo lỗi: $e -> Chuyển sang fallback web',
      );
    }

    // 3. DỰ PHÒNG HY HỮU (Fallback): Chỉ khi API gặp lỗi mới thử lấy link web công khai
    if (item.episodeIndex == 1) {
      try {
        final publicUrl = await _resolver.getPublicWebPlayUrl(
          item.detail.seriesId,
          item.vid,
          episodeIndex: item.episodeIndex,
        );
        if (publicUrl != null && publicUrl.isNotEmpty) {
          return _FeedPlaybackSource(
            url: publicUrl,
            vid: item.vid,
            seriesId: item.detail.seriesId,
            episodeIndex: item.episodeIndex,
          );
        }
      } catch (_) {}
    }

    throw StateError('Không thể lấy link phát cho video ${item.vid}');
  }

  void _warmupConnection(String url, CancelToken? cancelToken) {
    if (cancelToken?.isCancelled == true) return;
    unawaited(() async {
      try {
        final dio = Dio();
        await dio.head(
          url,
          options: Options(
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0',
              'Referer': 'https://novel.snssdk.com/',
            },
            receiveTimeout: const Duration(seconds: 4),
            sendTimeout: const Duration(seconds: 4),
          ),
          cancelToken: cancelToken,
        );
      } catch (_) {}
    }());
  }

  /// Nạp trước metadata & warm-up kết nối CDN; hỗ trợ CancelToken để bảo vệ băng thông
  Future<void> _preloadNextPage(
    int nextIndex, {
    required bool warmStream,
    CancelToken? cancelToken,
  }) async {
    if (!mounted || nextIndex < 0 || nextIndex >= _feedItems.length) return;
    if (cancelToken?.isCancelled == true) return;
    final feedGeneration = _feedGeneration;
    final initialMediaKey = _mediaKey(_feedItems[nextIndex]);
    if (_preloadingMediaKeys.contains(initialMediaKey)) {
      return;
    }

    final cachedSource = _preloadedSources[initialMediaKey];
    if (cachedSource != null && cachedSource.url.isNotEmpty) {
      if (warmStream &&
          (cachedSource.url.startsWith('http://') ||
              cachedSource.url.startsWith('https://'))) {
        _warmupConnection(cachedSource.url, cancelToken);
      }
      return;
    }

    _preloadingMediaKeys.add(initialMediaKey);
    var nextItem = _feedItems[nextIndex];

    try {
      if (nextItem.vid.isEmpty ||
          nextItem.vid == nextItem.detail.seriesId ||
          nextItem.detail.episodes.isEmpty) {
        try {
          final fullDetail = await _resolver.getDramaDetail(
            nextItem.detail.seriesId,
          );
          if (fullDetail.episodes.isNotEmpty) {
            final epIdx = nextItem.episodeIndex.clamp(
              1,
              fullDetail.episodes.length,
            );
            nextItem = FeedDramaPageItem(
              detail: fullDetail,
              episodeIndex: epIdx,
              vid: fullDetail.episodes[epIdx - 1].vid,
            );
            if (nextIndex < _feedItems.length &&
                _feedItems[nextIndex].detail.seriesId == fullDetail.seriesId) {
              _feedItems[nextIndex] = nextItem;
            }
          }
        } catch (_) {}
      }

      if (cancelToken?.isCancelled == true) return;

      final source = await _resolveEpisodeStreamSource(nextItem);
      if (!mounted ||
          feedGeneration != _feedGeneration ||
          nextIndex >= _feedItems.length ||
          _mediaKey(_feedItems[nextIndex]) != initialMediaKey ||
          cancelToken?.isCancelled == true) {
        return;
      }
      _preloadedSources[initialMediaKey] = source;

      if (warmStream &&
          (source.url.startsWith('http://') ||
              source.url.startsWith('https://'))) {
        _warmupConnection(source.url, cancelToken);
      }
    } catch (_) {
    } finally {
      _preloadingMediaKeys.remove(initialMediaKey);
    }
  }

  bool _isStandbyRequestCurrent({
    required int requestId,
    required int feedGeneration,
    required int index,
    required String mediaKey,
    required AppPlayerController controller,
  }) {
    return mounted &&
        requestId == _standbyRequestId &&
        feedGeneration == _feedGeneration &&
        index >= 0 &&
        index < _feedItems.length &&
        _mediaKey(_feedItems[index]) == mediaKey &&
        _standbyMediaKey == mediaKey &&
        identical(_standbyController, controller) &&
        !identical(_activeController, controller);
  }

  Future<void> _prepareStandbyPlayer(int index, {CancelToken? cancelToken}) async {
    if (!mounted || index < 0 || index >= _feedItems.length) return;
    if (cancelToken?.isCancelled == true) return;

    final feedGeneration = _feedGeneration;
    final mediaKey = _mediaKey(_feedItems[index]);
    if (_activeMediaKey == mediaKey || _standbyMediaKey == mediaKey) return;

    final requestId = ++_standbyRequestId;
    final existingController = _standbyController;
    final AppPlayerController controller;
    if (existingController == null ||
        existingController.isDisposed ||
        identical(existingController, _activeController)) {
      controller = AppPlayerController(bufferSizeMb: 16, silent: true);
    } else {
      controller = existingController;
    }

    _standbyController = controller;
    _standbyMediaKey = mediaKey;
    _standbyReady = false;
    setState(() {});

    try {
      await _preloadNextPage(index, warmStream: true, cancelToken: cancelToken);
      if (!_isStandbyRequestCurrent(
        requestId: requestId,
        feedGeneration: feedGeneration,
        index: index,
        mediaKey: mediaKey,
        controller: controller,
      ) || (cancelToken?.isCancelled == true)) {
        return;
      }

      final item = _feedItems[index];
      var source = _preloadedSources[mediaKey];
      if (source == null || source.url.isEmpty) {
        source = await _resolveEpisodeStreamSource(item);
        if (!_isStandbyRequestCurrent(
          requestId: requestId,
          feedGeneration: feedGeneration,
          index: index,
          mediaKey: mediaKey,
          controller: controller,
        ) || (cancelToken?.isCancelled == true)) {
          return;
        }
        _preloadedSources[mediaKey] = source;
      }

      final switchFuture = _standbySwitchTail.then<bool>((_) async {
        if (!_isStandbyRequestCurrent(
          requestId: requestId,
          feedGeneration: feedGeneration,
          index: index,
          mediaKey: mediaKey,
          controller: controller,
        )) {
          return false;
        }
        if (source!.url.startsWith('http://') ||
            source.url.startsWith('https://')) {
          await controller.switchMedia(
            networkUrl: source.url,
            decryptionKey: source.decryptionKey,
            headers: source.headers.isNotEmpty
                ? source.headers
                : const {
                    'User-Agent':
                        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0',
                    'Referer': 'https://novel.snssdk.com/',
                  },
            play: false,
            silentStandby: true,
          );
        } else {
          await controller.switchMedia(
            file: File(source.url),
            play: false,
            silentStandby: true,
          );
        }
        await controller.player.setRate(_playbackSpeed);
        return _isStandbyRequestCurrent(
          requestId: requestId,
          feedGeneration: feedGeneration,
          index: index,
          mediaKey: mediaKey,
          controller: controller,
        );
      });
      _standbySwitchTail = switchFuture.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      final switched = await switchFuture;
      if (!switched) return;

      _standbyReady = true;
      setState(() {});
      await _restoreActivePlaybackAfterStandbyOpen(controller);
    } catch (e) {
      if (_isStandbyRequestCurrent(
        requestId: requestId,
        feedGeneration: feedGeneration,
        index: index,
        mediaKey: mediaKey,
        controller: controller,
      )) {
        debugPrint('[HongguoFeedScreen] Không thể nạp player kế tiếp: $e');
        _standbyReady = false;
      }
    }
  }

  /// N+1 mở trên standby player; N+2 & N+3 nạp trước Chunk 0 vào RAM/Disk; N+4 nạp URL.
  /// Có cơ chế Bảo Vệ Băng Thông (Bandwidth Gatekeeper) tự động nhường mạng cho video đang xem.
  Future<void> _preloadAheadEpisodes(int currentIndex) async {
    final feedGeneration = _feedGeneration;
    final currentMediaKey = _mediaKey(_feedItems[currentIndex]);
    bool isStillCurrent() {
      return mounted &&
          feedGeneration == _feedGeneration &&
          _activePageIndex == currentIndex &&
          currentIndex >= 0 &&
          currentIndex < _feedItems.length &&
          _mediaKey(_feedItems[currentIndex]) == currentMediaKey;
    }

    _cancelCascadingPreload();
    final cancelToken = CancelToken();
    _cascadingPreloadCancelToken = cancelToken;

    // Đợi 500ms để video hiện tại bắt đầu phát và ổn định nhịp render/audio
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!isStillCurrent() || cancelToken.isCancelled || _isPlayerBuffering) return;

    // 1. Bước 1: Nạp N+1 (Standby player + Chunk 0 2MB)
    final nextIndex = currentIndex + 1;
    if (nextIndex < _feedItems.length) {
      await _prepareStandbyPlayer(nextIndex, cancelToken: cancelToken);
    }
    if (!isStillCurrent() || cancelToken.isCancelled || _isPlayerBuffering) return;

    // 2. Bước 2: Nạp metadata & warm-up kết nối CDN cho N+2 (DNS, TLS, TCP)
    final secondNextIndex = currentIndex + 2;
    if (secondNextIndex < _feedItems.length) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!isStillCurrent() || cancelToken.isCancelled || _isPlayerBuffering) return;
      await _preloadNextPage(secondNextIndex, warmStream: true, cancelToken: cancelToken);
    }
    if (!isStillCurrent() || cancelToken.isCancelled || _isPlayerBuffering) return;

    // 3. Bước 3: Nạp metadata & warm-up kết nối CDN cho N+3
    final thirdNextIndex = currentIndex + 3;
    if (thirdNextIndex < _feedItems.length) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!isStillCurrent() || cancelToken.isCancelled || _isPlayerBuffering) return;
      await _preloadNextPage(thirdNextIndex, warmStream: true, cancelToken: cancelToken);
    }
    if (!isStillCurrent() || cancelToken.isCancelled || _isPlayerBuffering) return;

    // 4. Bước 4: Nạp trước URL cho N+4 (warmStream: false, chuẩn bị sẵn link CDN)
    final fourthNextIndex = currentIndex + 4;
    if (fourthNextIndex < _feedItems.length) {
      await _preloadNextPage(fourthNextIndex, warmStream: false, cancelToken: cancelToken);
    }
  }

  /// Duy trì [-2 .. +3] xung quanh vị trí xem trong RAM (Giữ cả tập n-2 theo yêu cầu của bạn).
  void _maintainFeedWindow(int currentIndex) {
    if (currentIndex < 0 || currentIndex >= _feedItems.length) return;
    final retainedMediaKeys = <String>{};
    for (var offset = -2; offset <= 3; offset++) {
      final idx = currentIndex + offset;
      if (idx >= 0 && idx < _feedItems.length) {
        retainedMediaKeys.add(_mediaKey(_feedItems[idx]));
      }
    }
    _preloadedSources.removeWhere((key, _) => !retainedMediaKeys.contains(key));
  }

  void _onPageChanged(int index) {
    HapticFeedback.selectionClick();
    _currentIndex = index;
    _tabCurrentIndices[_currentFeedTab] = index;

    // Dừng ngay lập tức âm thanh lồng tiếng của tập cũ và reset volume video gốc về 100%
    _ttsScheduler?.stop();
    _ttsScheduler?.setDocument(null);
    _activeController?.setVolume(1.0);

    _maintainFeedWindow(index);
    _activatePage(index);

    // Tự động nạp thêm khi ở chế độ khám phá
    if (!_isDramaEpisodeMode &&
        index >= _feedItems.length - 3 &&
        !_isLoadingMore) {
      _loadMoreDiscoverDramas();
    }
  }

  String _normalizeFeedTab(String key) {
    return switch (key) {
      _tabFollow || _tabComic || _tabReal || _tabDiscover => key,
      _ => _tabDiscover,
    };
  }

  String _feedTabLabel(String key) {
    return switch (key) {
      _tabFollow => 'Quan tâm',
      _tabComic => 'Mạn kịch',
      _tabReal => 'Người thật',
      _ => 'Đề xuất',
    };
  }

  List<FeedDramaPageItem> _cacheListForTab(String tabKey) {
    return switch (tabKey) {
      _tabFollow => _followFeedItems,
      _tabComic => _comicFeedItems,
      _tabReal => _realFeedItems,
      _ => _discoverFeedItems,
    };
  }

  Future<({List<HongguoDramaItem> items, HongguoDiscoveryCursor? nextCursor})>
  _fetchChannelBatch(
    HongguoGenreKind kind, {
    HongguoDiscoveryCursor? cursor,
    HongguoDiscoverySelection? overrideSelection,
    Set<String> excludedIds = const <String>{},
  }) async {
    final selection =
        overrideSelection ?? HongguoDiscoverySelection(genreKind: kind);
    final useDefaultSort = overrideSelection == null;
    final seenAll = <String>{
      ...excludedIds,
      ...?_settings?.hongguoSeenSeriesIds,
    };
    var page = await HongguoDiscoveryService.instance.fetchDiscovery(
      selection,
      cursor: cursor,
      seenIds: seenAll,
      useDefaultFeedSort: useDefaultSort,
    );
    if (page.items.isEmpty && cursor != null) {
      page = await HongguoDiscoveryService.instance.fetchDiscovery(
        selection,
        seenIds: excludedIds,
        useDefaultFeedSort: useDefaultSort,
      );
    }
    return (items: page.items, nextCursor: page.nextCursor);
  }

  Future<void> _loadMoreDiscoverDramas() async {
    if (_isLoadingMore) return;
    _isLoadingMore = true;
    final feedGeneration = _feedGeneration;
    final feedTab = _currentFeedTab;
    try {
      final existingSids = _feedItems.map((e) => e.detail.seriesId).toSet();
      List<HongguoDramaItem> dramas = [];

      if (feedTab == _tabFollow) {
        final res = await HongguoSimilarEngine.instance.getFollowFeedList(
          excludedSeriesIds: existingSids,
          seedOffset: ++_followSeedOffset,
        );
        dramas = res.items;
      } else if (feedTab == _tabComic) {
        final batch = await _fetchChannelBatch(
          HongguoGenreKind.comicSeries,
          cursor: _comicCursor,
          overrideSelection: _comicSelectionOverride,
          excludedIds: existingSids,
        );
        _comicCursor = batch.nextCursor;
        dramas = batch.items;
      } else if (feedTab == _tabReal) {
        final batch = await _fetchChannelBatch(
          HongguoGenreKind.realPlay,
          cursor: _realCursor,
          overrideSelection: _realSelectionOverride,
          excludedIds: existingSids,
        );
        _realCursor = batch.nextCursor;
        dramas = batch.items;
      } else {
        dramas = await HongguoSimilarEngine.instance
            .getPersonalizedDiscoverList(excludedSeriesIds: existingSids);
      }

      if (!mounted ||
          feedGeneration != _feedGeneration ||
          feedTab != _currentFeedTab) {
        _isLoadingMore = false;
        return;
      }

      final seenIds = _settings?.hongguoSeenSeriesIds.toSet() ?? <String>{};
      final newItems = <FeedDramaPageItem>[];
      final dedupSids = _feedItems.map((e) => e.detail.seriesId).toSet();

      // Ưu tiên nạp các phim chưa xem
      for (final drama in dramas) {
        if (!dedupSids.contains(drama.seriesId) &&
            !seenIds.contains(drama.seriesId)) {
          newItems.add(_createFeedDramaItem(drama));
          dedupSids.add(drama.seriesId);
        }
      }

      // Fallback nếu toàn bộ phim vừa lấy về đều đã xem:
      if (newItems.isEmpty) {
        for (final drama in dramas) {
          if (!dedupSids.contains(drama.seriesId)) {
            newItems.add(_createFeedDramaItem(drama));
            dedupSids.add(drama.seriesId);
          }
        }
      }

      if (mounted) {
        setState(() {
          _feedItems.addAll(newItems);
          _cacheListForTab(_currentFeedTab).addAll(newItems);
          _isLoadingMore = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  /// Chuyển đổi giữa 4 tab trên Top Bar: 'follow' | 'comic' | 'real' | 'discover'
  Future<void> _switchFeedTab(
    String rawTabKey, {
    bool forceReload = false,
  }) async {
    final tabKey = _normalizeFeedTab(rawTabKey);
    if (_currentFeedTab == tabKey && !forceReload && _feedItems.isNotEmpty) {
      return;
    }
    _disposeStandbyPlayer();
    final switchGeneration = ++_feedGeneration;
    _activationRequestId++;
    _isLoadingMore = false;

    // 1. Lưu lại vị trí và danh sách của tab hiện tại trước khi chuyển
    final prevTargetIds =
        _cacheListForTab(tabKey).map((e) => e.detail.seriesId).toSet();
    if (_currentFeedTab == tabKey) {
      prevTargetIds.addAll(_feedItems.map((e) => e.detail.seriesId));
    }
    _tabCurrentIndices[_currentFeedTab] = _currentIndex;
    final activeCache = _cacheListForTab(_currentFeedTab);
    activeCache
      ..clear()
      ..addAll(_feedItems);

    // Tạm dừng video và TTS ở tab cũ ngay lập tức
    unawaited(_activeController?.muteAndPause());
    _ttsScheduler?.stop();
    _ttsScheduler?.setDocument(null);

    setState(() {
      _currentFeedTab = tabKey;
      _isLoadingVideo = true;
      if (forceReload) {
        _showLoadingIndicator = true;
      }
    });
    _saveFeedPreferences();

    List<FeedDramaPageItem> targetItems = [];
    final cachedForTarget = _cacheListForTab(tabKey);
    bool emptyDirectFollowNotice = false;

    if (cachedForTarget.isNotEmpty && !forceReload) {
      targetItems = cachedForTarget;
    } else {
      _tabCurrentIndices[tabKey] = 0;
      try {
        if (tabKey == _tabFollow) {
          _followSeedOffset = forceReload ? _followSeedOffset + 1 : 0;
          var res = await HongguoSimilarEngine.instance.getFollowFeedList(
            excludedSeriesIds: forceReload ? prevTargetIds : null,
            seedOffset: _followSeedOffset,
          );
          if (res.items.isEmpty && forceReload) {
            res = await HongguoSimilarEngine.instance.getFollowFeedList(
              seedOffset: _followSeedOffset,
            );
          }
          emptyDirectFollowNotice =
              res.directFollowCount == 0 && res.items.isNotEmpty;
          targetItems = res.items.map(_createFeedDramaItem).toList();
        } else if (tabKey == _tabComic || tabKey == _tabReal) {
          final isComic = tabKey == _tabComic;
          final kind = isComic
              ? HongguoGenreKind.comicSeries
              : HongguoGenreKind.realPlay;
          final overrideSel =
              isComic ? _comicSelectionOverride : _realSelectionOverride;
          final currentCursor = isComic ? _comicCursor : _realCursor;

          final batch = await _fetchChannelBatch(
            kind,
            cursor: forceReload ? currentCursor : null,
            overrideSelection: overrideSel,
            excludedIds: forceReload ? prevTargetIds : const <String>{},
          );
          if (isComic) {
            _comicCursor = batch.nextCursor;
          } else {
            _realCursor = batch.nextCursor;
          }
          final sorted = _prioritizeUnwatchedDramas(batch.items);
          targetItems = sorted.map(_createFeedDramaItem).toList();
        } else {
          var list = await HongguoSimilarEngine.instance
              .getPersonalizedDiscoverList(
                excludedSeriesIds: forceReload ? prevTargetIds : null,
                resetCursor: false,
              );
          if (list.isEmpty && forceReload) {
            list = await HongguoSimilarEngine.instance
                .getPersonalizedDiscoverList(resetCursor: true);
          }
          final sorted = _prioritizeUnwatchedDramas(list);
          targetItems = sorted.map(_createFeedDramaItem).toList();
        }
        cachedForTarget
          ..clear()
          ..addAll(targetItems);
      } catch (e) {
        debugPrint('[HongguoFeedScreen] Lỗi nạp tab $tabKey: $e');
      }
    }

    if (!mounted ||
        switchGeneration != _feedGeneration ||
        _currentFeedTab != tabKey) {
      return;
    }

    if (emptyDirectFollowNotice) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Chưa có phim Yêu thích/Xem sau — đang đề xuất phim nổi bật cùng gu',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
          backgroundColor: const Color(0xFF22242A),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }

    if (targetItems.isNotEmpty) {
      _feedItems.clear();
      _feedItems.addAll(targetItems);
      final restoredIndex = forceReload
          ? 0
          : (_tabCurrentIndices[tabKey] ?? 0).clamp(0, targetItems.length - 1);
      _currentIndex = restoredIndex;
      _preloadedSources.clear();
      _preloadingMediaKeys.clear();
      _dramaEpisodeSessionKey++;
      _replacePageController(restoredIndex);
      _activePageIndex = -1;
      await _activatePage(restoredIndex);
    } else {
      setState(() {
        _isLoadingVideo = false;
        _showLoadingIndicator = false;
      });
    }
  }

  /// Lọc nhanh theo thể loại khi người dùng chạm vào thẻ tag trên video hoặc bảng chi tiết.
  /// Khóa chặt hệ sinh thái đang xem (Hoạt hình -> Mạn kịch, Người thật -> Người thật).
  void _filterByTag(String tag, {HongguoDramaDetail? detail}) {
    HapticFeedback.mediumImpact();
    final activeDetail =
        detail ??
        (_currentIndex >= 0 && _currentIndex < _feedItems.length
            ? _feedItems[_currentIndex].detail
            : null);

    var fallbackSource = activeDetail?.sourceCategory ?? '';
    if (fallbackSource.isEmpty) {
      if (_currentFeedTab == _tabComic) {
        fallbackSource = HongguoGenreKind.comicSeries.categorySlug;
      } else if (_currentFeedTab == _tabReal) {
        fallbackSource = HongguoGenreKind.realPlay.categorySlug;
      }
    }

    final cleanZh = tag.replaceAll(RegExp(r'[\[\]#\s]'), '').trim();
    final selection = HongguoDiscoveryService.instance.resolveSelectionForTag(
      cleanZh,
      preferredSourceCategory: fallbackSource,
      categoryIds: activeDetail?.categoryIds ?? const <String>[],
      allDramaTags: activeDetail?.tags ?? const <String>[],
    );
    final groups = HongguoDiscoveryService.instance.getSelectorGroups(
      selection.genreKind,
    );
    final summaryLabel = selection.buildSummaryLabel(groups);
    final targetTab = selection.genreKind == HongguoGenreKind.comicSeries
        ? _tabComic
        : _tabReal;

    setState(() {
      if (targetTab == _tabComic) {
        _comicSelectionOverride = selection;
        _comicCursor = null;
        _comicFeedItems.clear();
      } else {
        _realSelectionOverride = selection;
        _realCursor = null;
        _realFeedItems.clear();
      }
      _tabCurrentIndices[targetTab] = 0;
    });

    HongguoSimilarEngine.instance.recordInterest([cleanZh], 2.0);

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.label_rounded, color: Color(0xFFFF6A00), size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Đang lọc: $summaryLabel',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF22242A),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );

    _switchFeedTab(targetTab, forceReload: true);
  }

  /// Mở Bottom Sheet "Đề xuất tương tự (相关推荐)" chuẩn API ByteDance
  void _openSimilarDramasSheet(FeedDramaPageItem item) {
    HongguoSimilarEngine.instance.recordInterest(item.detail.tags, 3.0);
    HongguoRelatedDramaSheet.show(
      context,
      currentDetail: item.detail,
      isTranslationEnabled: _isTranslationEnabled,
      onSelectDrama: (selectedDrama) {
        Navigator.pop(context);
        final detail = _dramaItemToDetail(selectedDrama);
        _switchToDramaEpisodeMode(detail);
      },
      onPlaySimilarFeed: (similarDramas) {
        Navigator.pop(context);
        _loadSimilarDramasIntoFeed(similarDramas);
      },
    );
  }

  /// Nạp chuỗi các phim tương tự vào Feed và bắt đầu lướt
  Future<void> _loadSimilarDramasIntoFeed(
    List<HongguoDramaItem> similarDramas,
  ) async {
    HapticFeedback.mediumImpact();
    final items = <FeedDramaPageItem>[];
    for (final drama in similarDramas) {
      items.add(_createFeedDramaItem(drama));
    }
    if (items.isEmpty) return;

    _disposeStandbyPlayer();
    setState(() {
      _feedGeneration++;
      _activationRequestId++;
      _isDramaEpisodeMode = false;
      _feedItems.clear();
      _feedItems.addAll(items);
      _currentIndex = 0;
      _preloadedSources.clear();
      _preloadingMediaKeys.clear();
      _dramaEpisodeSessionKey++;
    });
    _replacePageController(0);
    _activePageIndex = -1;
    await _activatePage(0);

    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(
              Icons.auto_awesome_motion_rounded,
              color: Color(0xFF2DE1FC),
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Đang lướt chuỗi ${items.length} phim tương tự theo Zone',
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF1E2024),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  void _togglePlayPause() {
    HapticFeedback.lightImpact();
    if (_activeController == null) return;
    if (_activeController!.value.isPlaying) {
      _cancelLiveWarmupPause(finishTranslatorWarmup: false);
      _activeController!.player.pause();
      _ttsScheduler?.pause();
      _liveTranslator?.onVideoStateUpdate(
        positionMs: _currentPos.inMilliseconds,
        isPlaying: false,
        isBuffering: _isPlayerBuffering,
        isScrubbing: _isScrubbing,
        playbackSpeed: _playbackSpeed,
      );
      setState(() {
        _isManuallyPaused = true;
        _showPlayPauseAnim = true;
      });
    } else {
      _cancelLiveWarmupPause(finishTranslatorWarmup: true);
      _activeController!.player.play();
      _ttsScheduler?.resume();
      _liveTranslator?.onVideoStateUpdate(
        positionMs: _currentPos.inMilliseconds,
        isPlaying: true,
        isBuffering: _isPlayerBuffering,
        isScrubbing: _isScrubbing,
        playbackSpeed: _playbackSpeed,
      );
      setState(() {
        _isManuallyPaused = false;
        _showPlayPauseAnim = true;
      });
    }
    Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _showPlayPauseAnim = false);
    });
  }

  void _onDoubleTapAt(Offset globalPos) {
    HapticFeedback.mediumImpact();
    setState(() {
      _heartAnimPos = globalPos;
      _showHeartAnim = true;
    });
    if (_currentIndex >= 0 && _currentIndex < _feedItems.length) {
      final curItem = _feedItems[_currentIndex];
      HongguoSimilarEngine.instance.recordInterest(curItem.detail.tags, 5.0);
    }
    Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _showHeartAnim = false);
    });
  }

  static const List<double> _feedPlaybackSpeeds = <double>[
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
  ];

  String _formatPlaybackSpeed(double speed) {
    return speed == speed.truncateToDouble()
        ? '${speed.toStringAsFixed(1)}x'
        : '${speed}x';
  }

  Future<void> _applyPlaybackSpeed(double speed) async {
    HapticFeedback.lightImpact();
    setState(() {
      _playbackSpeed = speed;
    });
    _settings?.hongguoPlaybackSpeed = speed;
    await _activeController?.player.setRate(speed);
    if (_isTtsActive && _ttsScheduler != null && _activeController != null) {
      _ttsScheduler!.onVideoStateUpdate(
        positionMs: _currentPos.inMilliseconds,
        isPlaying: _activeController!.value.isPlaying && !_isManuallyPaused,
        isBuffering: _isPlayerBuffering,
        isScrubbing: _isScrubbing,
        playbackSpeed: speed,
      );
    }
    _liveTranslator?.onVideoStateUpdate(
      positionMs: _currentPos.inMilliseconds,
      isPlaying: _waitingLiveWarmupResume
          ? true
          : ((_activeController?.value.isPlaying ?? false) &&
              !_isManuallyPaused),
      isBuffering: _isPlayerBuffering,
      isScrubbing: _isScrubbing,
      playbackSpeed: speed,
    );
  }

  /// Mở bộ chọn tốc độ phát video dạng Bottom Sheet
  Future<void> _showFeedSpeedSheet() async {
    HapticFeedback.lightImpact();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF181A22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Chọn tốc độ phát',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                ..._feedPlaybackSpeeds.map((speed) {
                  final selected = (_playbackSpeed - speed).abs() < 0.01;
                  final label = _formatPlaybackSpeed(speed);
                  return ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    leading: Icon(
                      selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      color:
                          selected ? AppColors.primaryEmerald : Colors.white54,
                    ),
                    title: Text(
                      speed == 1.0 ? '$label (Mặc định)' : label,
                      style: TextStyle(
                        color: selected
                            ? AppColors.primaryEmerald
                            : Colors.white,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.normal,
                      ),
                    ),
                    onTap: () async {
                      Navigator.of(ctx).pop();
                      if (selected) return;
                      await _applyPlaybackSpeed(speed);
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _refreshMissingEpisodeCount(int index) async {
    if (index < 0 || index >= _feedItems.length) return;
    final item = _feedItems[index];
    final seriesId = item.detail.seriesId;
    if (seriesId.isEmpty) return;
    try {
      final fullDetail = await _resolver.getDramaDetail(seriesId);
      if (!mounted) return;
      final resolvedTotal = math.max(
        fullDetail.episodes.length,
        fullDetail.totalEpisodes,
      );
      if (resolvedTotal <= 1) return;
      final idx = _feedItems.indexWhere(
        (it) => it.detail.seriesId == seriesId && it.episodeIndex == item.episodeIndex,
      );
      if (idx == -1) return;
      final epIdx = item.episodeIndex.clamp(1, fullDetail.episodes.length);
      final realVid = fullDetail.episodes.isNotEmpty
          ? fullDetail.episodes[epIdx - 1].vid
          : item.vid;
      setState(() {
        _feedItems[idx] = FeedDramaPageItem(
          detail: fullDetail,
          episodeIndex: item.episodeIndex,
          vid: realVid.isNotEmpty ? realVid : item.vid,
        );
      });
    } catch (_) {}
  }

  /// Mở bảng cài đặt nhanh khi nhấn giữ vào video (Tốc độ, Chất lượng & Dịch ML Kit).
  Future<void> _showFeedQuickSettingsSheet() async {
    HapticFeedback.mediumImpact();
    final rawTiers = _activeVideoInfo?.ladder?.availableQualityTiers ??
        const <String>['1080', '720', '480', '360'];
    final ascTiers = List<String>.from(rawTiers)
      ..sort(
        (a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0),
      );
    final qualityOptions = <({String key, String label})>[
      for (final t in ascTiers) (key: t, label: '${t}P'),
      const (key: 'auto', label: 'Tự động'),
    ];

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF181A22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 38,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF21242D),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 1. Tốc độ phát
                          Row(
                            children: [
                              const Icon(
                                Icons.speed_rounded,
                                color: Colors.white,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                'Tốc độ phát',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                _formatPlaybackSpeed(_playbackSpeed),
                                style: const TextStyle(
                                  color: AppColors.primaryEmerald,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF15171E),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: _feedPlaybackSpeeds.map((speed) {
                                final selected =
                                    (_playbackSpeed - speed).abs() < 0.01;
                                return Expanded(
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () async {
                                      if (selected) return;
                                      await _applyPlaybackSpeed(speed);
                                      if (sheetCtx.mounted) {
                                        setSheetState(() {});
                                      }
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 8,
                                      ),
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: selected
                                            ? AppColors.primaryEmerald
                                                .withValues(alpha: 0.22)
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(8),
                                        border: selected
                                            ? Border.all(
                                                color: AppColors.primaryEmerald
                                                    .withValues(alpha: 0.7),
                                                width: 0.8,
                                              )
                                            : null,
                                      ),
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text(
                                          _formatPlaybackSpeed(speed),
                                          maxLines: 1,
                                          style: TextStyle(
                                            color: selected
                                                ? AppColors.primaryEmerald
                                                : Colors.white70,
                                            fontSize: 12,
                                            fontWeight: selected
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(growable: false),
                            ),
                          ),

                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 14),
                            child: Divider(height: 1, color: Colors.white10),
                          ),

                          // 2. Chất lượng phát
                          Row(
                            children: [
                              const Icon(
                                Icons.high_quality_rounded,
                                color: Colors.white,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                'Chất lượng phát',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                _preferredQuality == 'auto'
                                    ? (_activeVideoInfo
                                            ?.selectedRendition?.qualityLabel ??
                                        'Tự động')
                                    : '${_preferredQuality}P',
                                style: const TextStyle(
                                  color: AppColors.primaryEmerald,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF15171E),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: qualityOptions.map((opt) {
                                final selected = _preferredQuality == opt.key;
                                return Expanded(
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () async {
                                      Navigator.of(ctx).pop();
                                      await _selectFeedQuality(opt.key);
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 8,
                                      ),
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: selected
                                            ? AppColors.primaryEmerald
                                                .withValues(alpha: 0.22)
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(8),
                                        border: selected
                                            ? Border.all(
                                                color: AppColors.primaryEmerald
                                                    .withValues(alpha: 0.7),
                                                width: 0.8,
                                              )
                                            : null,
                                      ),
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text(
                                          opt.label,
                                          maxLines: 1,
                                          style: TextStyle(
                                            color: selected
                                                ? AppColors.primaryEmerald
                                                : Colors.white70,
                                            fontSize: 12,
                                            fontWeight: selected
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(growable: false),
                            ),
                          ),

                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 14),
                            child: Divider(height: 1, color: Colors.white10),
                          ),

                          // 3. Tự động dịch tiêu đề & mô tả (ML Kit)
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              _toggleFeedTranslation(showSnackBar: false);
                              if (sheetCtx.mounted) {
                                setSheetState(() {});
                              }
                            },
                            child: Row(
                              children: [
                                Icon(
                                  Icons.translate_rounded,
                                  color: _isTranslationEnabled
                                      ? AppColors.primaryEmerald
                                      : Colors.white70,
                                  size: 18,
                                ),
                                const SizedBox(width: 8),
                                const Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Tự động dịch tiêu đề & mô tả',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      SizedBox(height: 2),
                                      Text(
                                        'Dùng ML Kit dịch nhanh khi lướt feed',
                                        style: TextStyle(
                                          color: Colors.white54,
                                          fontSize: 11.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Switch.adaptive(
                                  value: _isTranslationEnabled,
                                  activeTrackColor: AppColors.primaryEmerald
                                      .withValues(alpha: 0.45),
                                  activeThumbColor: AppColors.primaryEmerald,
                                  onChanged: (_) {
                                    _toggleFeedTranslation(
                                      showSnackBar: false,
                                    );
                                    if (sheetCtx.mounted) {
                                      setSheetState(() {});
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Xoay toàn màn hình ngang (Landscape Fullscreen)
  void _toggleLandscapeFullscreen() {
    HapticFeedback.mediumImpact();
    setState(() {
      _isLandscapeFullscreen = !_isLandscapeFullscreen;
    });
    if (_isLandscapeFullscreen) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  /// Chuyển từ chế độ Khám phá sang Chế độ Xem trọn bộ của phim được chọn
  Future<void> _switchToDramaEpisodeMode(
    HongguoDramaDetail detail, {
    int targetEpisode = 1,
  }) async {
    HapticFeedback.mediumImpact();

    // Lưu lại danh sách khám phá nếu chưa lưu
    if (!_isDramaEpisodeMode) {
      _savedDiscoverItems = List.from(_feedItems);
      _savedDiscoverIndex = _currentIndex;
    }

    // Nếu detail chưa có danh sách tập đầy đủ, nạp chi tiết từ resolver
    HongguoDramaDetail fullDetail = detail;
    if (detail.episodes.isEmpty ||
        (detail.episodes.length <= 1 && detail.totalEpisodes > 1)) {
      try {
        final fetched = await _resolver.getDramaDetail(detail.seriesId);
        if (fetched.episodes.isNotEmpty) {
          fullDetail = fetched;
        }
      } catch (_) {}
    }

    final totalCount = fullDetail.episodes.isNotEmpty
        ? fullDetail.episodes.length
        : fullDetail.totalEpisodes;
    final maxIdx = totalCount > 0 ? totalCount - 1 : 0;
    final int targetIdx = (targetEpisode - 1).clamp(0, maxIdx).toInt();

    _replacePageController(targetIdx);
    _activePageIndex = -1;

    setState(() {
      _isDramaEpisodeMode = true;
      _currentDramaDetail = fullDetail;
      _dramaEpisodeSessionKey++;
      _populateDramaEpisodes(fullDetail, initialEpisode: targetEpisode);
    });

    await _activatePage(targetIdx);
  }

  /// Quay lại chế độ Khám phá (Discover Feed)
  void _handleBackNavigation() {
    HapticFeedback.lightImpact();
    if (_isCleanMode) {
      setState(() => _isCleanMode = false);
      return;
    }
    if (_isLandscapeFullscreen) {
      _toggleLandscapeFullscreen();
      return;
    }

    if (_isDramaEpisodeMode && _savedDiscoverItems.isNotEmpty) {
      // Quay lại Discover Feed
      _disposeStandbyPlayer();
      setState(() {
        _feedGeneration++;
        _activationRequestId++;
        _isDramaEpisodeMode = false;
        _currentDramaDetail = null;
        _feedItems.clear();
        _feedItems.addAll(_savedDiscoverItems);
        _currentIndex = _savedDiscoverIndex.clamp(0, _feedItems.length - 1);
        _preloadedSources.clear();
        _preloadingMediaKeys.clear();
        _dramaEpisodeSessionKey++;
      });
      _replacePageController(_currentIndex);
      _activePageIndex = -1;
      _activatePage(_currentIndex);
    } else {
      Navigator.pop(context);
    }
  }

  /// Mở Bottom Sheet chọn tập chuẩn ByteDance (Frame 15 Style)
  void _showEpisodePickerSheet(HongguoDramaDetail detail) {
    HapticFeedback.lightImpact();
    final currentEpisodeNum =
        (_currentIndex >= 0 && _currentIndex < _feedItems.length)
        ? _feedItems[_currentIndex].episodeIndex
        : 1;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _ByteDanceEpisodePickerSheet(
        detail: detail,
        currentEpisode: currentEpisodeNum,
        isTranslationEnabled: _isTranslationEnabled,
        onSelectEpisode: (epIndex, fullDetail) async {
          Navigator.pop(ctx);
          if (_isDramaEpisodeMode) {
            final targetPage = (epIndex - 1).clamp(0, _feedItems.length - 1);
            if (targetPage != _currentIndex) {
              _currentIndex = targetPage;
              _pageController.jumpToPage(targetPage);
            }
          } else {
            // Đang ở Discover Feed -> chuyển sang Drama Episode Mode của phim này với toàn bộ tập
            await _switchToDramaEpisodeMode(fullDetail, targetEpisode: epIndex);
          }
        },
        onSelectTag: (tag) => _filterByTag(tag, detail: detail),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isDramaEpisodeMode && !_isLandscapeFullscreen && !_isCleanMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBackNavigation();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // 1. Vertical PageView lướt video dạng TikTok/Shorts
            PageView.builder(
              key: ValueKey(
                'hongguo_page_view_${_isDramaEpisodeMode ? _currentDramaDetail?.seriesId : _currentFeedTab}_$_dramaEpisodeSessionKey',
              ),
              controller: _pageController,
              scrollDirection: Axis.vertical,
              physics: _isLandscapeFullscreen
                  ? const NeverScrollableScrollPhysics()
                  : const ClampingScrollPhysics(parent: PageScrollPhysics()),
              itemCount: _feedItems.length,
              onPageChanged: _onPageChanged,
              itemBuilder: (context, index) {
                final item = _feedItems[index];
                final isCurrent = index == _currentIndex;

                return _buildFeedPageItem(item, isCurrent);
              },
            ),

            // 2. Double Tap Heart Animation
            if (_showHeartAnim)
              Positioned(
                left: _heartAnimPos.dx - 45,
                top: _heartAnimPos.dy - 45,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.6, end: 1.3),
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.elasticOut,
                  builder: (_, scale, child) =>
                      Transform.scale(scale: scale, child: child),
                  child: const Icon(
                    Icons.favorite_rounded,
                    color: Color(0xFFFF2B54),
                    size: 90,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 16)],
                  ),
                ),
              ),

            // 3. Play / Pause Center Icon Animation
            if (_showPlayPauseAnim)
              Center(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _isManuallyPaused
                        ? Icons.play_arrow_rounded
                        : Icons.pause_rounded,
                    color: Colors.white,
                    size: 48,
                  ),
                ),
              ),

            // 4. Thanh điều hướng trên cùng (Top Bar chuẩn Frame 3 / Frame 8)
            _buildTopBar(),

            // 5. Banner tiến trình Dịch AI / Lồng tiếng trực tiếp
            if (_isTranslatingCurrent)
              Positioned(
                top: MediaQuery.of(context).padding.top + 52,
                left: 20,
                right: 20,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFFFF6A00),
                        width: 0.8,
                      ),
                      boxShadow: const [
                        BoxShadow(color: Colors.black54, blurRadius: 10),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(
                              Color(0xFFFF6A00),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _translationStatus,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${(_translationProgress * 100).toInt()}%',
                          style: const TextStyle(
                            color: Color(0xFFFF6A00),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // 5b. Phụ đề Live Translate tạm thời trên Feed
            if (_liveTranslator != null && !_isCleanMode)
              Positioned(
                left: 14,
                right: 76,
                bottom: MediaQuery.of(context).padding.bottom + 148,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: LiveTranslateCaptionBanner(
                    translator: _liveTranslator!,
                    onTap: _openLiveTranslateSheet,
                  ),
                ),
              ),

            // 6. Thanh tua tiến trình dạng Scrubber (Hongguo Style)
            if (!_isCleanMode)
              Positioned(
                left: 0,
                right: 0,
                bottom: MediaQuery.of(context).padding.bottom + 4,
                child: ValueListenableBuilder<int>(
                  valueListenable: _playbackRevision,
                  builder: (_, _, _) => _buildProgressScrubber(),
                ),
              ),

            // 7. Cử chỉ vuốt mép trái sang phải để Back (khi xem trọn bộ hoặc clean mode)
            if ((_isDramaEpisodeMode || _isCleanMode) && !_isLandscapeFullscreen)
              Positioned(
                left: 0,
                top: 0,
                bottom: 60,
                width: 36,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragStart: (_) {
                    _edgeSwipeDistance = 0.0;
                  },
                  onHorizontalDragUpdate: (details) {
                    _edgeSwipeDistance += details.primaryDelta ?? 0.0;
                  },
                  onHorizontalDragEnd: (details) {
                    final velocity = details.primaryVelocity ?? 0.0;
                    if (velocity > 200 || _edgeSwipeDistance > 60) {
                      _handleBackNavigation();
                    }
                    _edgeSwipeDistance = 0.0;
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Giao diện cho từng trang video trong PageView
  Widget _buildFeedPageItem(FeedDramaPageItem item, bool isCurrent) {
    final itemMediaKey = _mediaKey(item);
    final pageController = _activeMediaKey == itemMediaKey
        ? _activeController
        : (_standbyReady && _standbyMediaKey == itemMediaKey
              ? _standbyController
              : null);
    final videoAspect =
        (pageController != null &&
            pageController.value.isInitialized &&
            pageController.value.aspectRatio > 0)
        ? pageController.value.aspectRatio
        : (9 / 16);
    final isLandscapeVideo = videoAspect > 1.05;

    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: Colors.black),

        // Video Player
        if (pageController != null && (!isCurrent || _errorMessage == null))
          Center(
            child: AspectRatio(
              aspectRatio: videoAspect,
              child: Video(
                key: ValueKey(
                  'feed_player_${pageController.hashCode}_$itemMediaKey',
                ),
                controller: pageController.videoController,
                controls: NoVideoControls,
              ),
            ),
          ),

        // Vòng xoay nạp video chỉ hiện khi độ trễ vượt quá 400 ms.
        if (isCurrent && _showLoadingIndicator)
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      color: Color(0xFFFF6A00),
                      strokeWidth: 2.2,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Đang kết nối tập ${item.episodeIndex}...',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),

        // Báo lỗi nếu phát sinh lỗi luồng
        if (isCurrent && _errorMessage != null)
          Center(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 32),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF1E2024),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.wifi_off_rounded,
                    color: Colors.orangeAccent,
                    size: 40,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _errorMessage!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Thử lại'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF6A00),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    onPressed: () => _activatePage(_currentIndex),
                  ),
                ],
              ),
            ),
          ),

        // Vùng nhận cử chỉ Chạm dừng / Nhấp đúp thả tim (Chạm để khôi phục khi ở Clean Mode)
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              if (_isCleanMode) {
                HapticFeedback.lightImpact();
                setState(() => _isCleanMode = false);
              } else {
                _togglePlayPause();
              }
            },
            onDoubleTapDown: (details) =>
                _onDoubleTapAt(details.globalPosition),
            onLongPress: _showFeedQuickSettingsSheet,
          ),
        ),

        // Nút xoay xem toàn màn hình cho video ngang (Nằm trên Positioned.fill để nhận tap nhạy bén)
        if (isCurrent &&
            isLandscapeVideo &&
            !_isLandscapeFullscreen &&
            !_isCleanMode)
          Positioned(
            left: 0,
            right: 0,
            top: MediaQuery.of(context).size.height * 0.5 + 130,
            child: Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleLandscapeFullscreen,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white30, width: 0.8),
                    boxShadow: const [
                      BoxShadow(color: Colors.black45, blurRadius: 8),
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.fullscreen_rounded,
                        color: Colors.white,
                        size: 16,
                      ),
                      SizedBox(width: 6),
                      Text(
                        'Xem toàn màn hình',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

        // Nút phục hồi giao diện nổi nhỏ khi đang ở Chế độ ẩn nút (Clean Mode)
        if (isCurrent && _isCleanMode)
          Positioned(
            top: MediaQuery.of(context).padding.top + 10,
            right: 14,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                HapticFeedback.lightImpact();
                setState(() => _isCleanMode = false);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white24, width: 0.8),
                  boxShadow: const [
                    BoxShadow(color: Colors.black45, blurRadius: 6),
                  ],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.visibility_rounded,
                      color: Colors.white,
                      size: 14,
                    ),
                    SizedBox(width: 5),
                    Text(
                      'Hiện giao diện',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

        // Phụ đề Vietsub trực tiếp (hỗ trợ kéo vuốt tay điều chỉnh độ cao lên/xuống)
        if (isCurrent &&
            _showSubtitles &&
            _settings != null &&
            _episodeDocuments.containsKey(_getVideoDocKey(item)))
          ValueListenableBuilder<int>(
            valueListenable: _playbackRevision,
            builder: (_, _, _) => SubtitleOverlay(
              document: _episodeDocuments[_getVideoDocKey(item)]!,
              currentPositionMs: _currentPos.inMilliseconds,
              settings: _settings!,
              onDragOffset: (newOffset) {
                setState(() {
                  _settings!.subtitleOffsetY = newOffset.clamp(-80.0, 350.0);
                });
              },
            ),
          ),

        // Lớp Overlay thông tin phim và tác vụ (TikTok / Shorts Layout)
        _buildOverlayUI(item),
      ],
    );
  }

  /// Top Bar chuẩn 4 mục giống app Hồng Quả gốc: Quan tâm | Mạn kịch | Người thật | Đề xuất
  void _onTopFeedTabTap(String tabKey) {
    final alreadyActive = _currentFeedTab == tabKey;
    if (alreadyActive) {
      HapticFeedback.mediumImpact();
      if (tabKey == _tabComic && _comicSelectionOverride != null) {
        _comicSelectionOverride = null;
        _comicCursor = null;
      } else if (tabKey == _tabReal && _realSelectionOverride != null) {
        _realSelectionOverride = null;
        _realCursor = null;
      }
      final label = _feedTabLabel(tabKey);
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(
                Icons.autorenew_rounded,
                color: Color(0xFFFF6A00),
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(
                'Đang làm mới $label...',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF22242A),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 900),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
    _switchFeedTab(tabKey, forceReload: alreadyActive);
  }

  Widget _buildTopBar() {
    if (_isCleanMode) {
      return const SizedBox.shrink();
    }

    final topPadding = MediaQuery.of(context).padding.top;

    // Top Bar khi xoay ngang toàn màn hình (Landscape Fullscreen Mode)
    if (_isLandscapeFullscreen) {
      final currentEpNum =
          (_currentIndex >= 0 && _currentIndex < _feedItems.length)
          ? _feedItems[_currentIndex].episodeIndex
          : 1;
      final currentItem =
          (_currentIndex >= 0 && _currentIndex < _feedItems.length)
          ? _feedItems[_currentIndex]
          : null;
      final dramaTitle = currentItem != null
          ? _displayTitleFor(currentItem.detail)
          : '';

      return Positioned(
        top: 10,
        left: 16,
        right: 16,
        child: Row(
          children: [
            // Nút Back / Thoát toàn màn hình
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleLandscapeFullscreen,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white24, width: 0.8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.fullscreen_exit_rounded,
                      color: Colors.white,
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '$dramaTitle - Tập $currentEpNum',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            // Nút điều chỉnh tốc độ phát
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _showFeedSpeedSheet,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white24, width: 0.8),
                ),
                child: Text(
                  _formatPlaybackSpeed(_playbackSpeed),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (_isDramaEpisodeMode) {
      // Top Bar khi đang xem một phim cụ thể (Frame 8 Style)
      final currentEpNum =
          (_currentIndex >= 0 && _currentIndex < _feedItems.length)
          ? _feedItems[_currentIndex].episodeIndex
          : 1;

      return Positioned(
        top: topPadding + 6,
        left: 12,
        right: 12,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Nút Back + Tiêu đề tập: `< Tập N`
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _handleBackNavigation,
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      color: Colors.white,
                      size: 15,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      'Tập $currentEpNum',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const Spacer(),

            // Nút Tốc độ phát: `⏱ 1.0x` (Mở bảng chọn tốc độ)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _showFeedSpeedSheet,
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 11),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white24, width: 0.6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.speed_rounded,
                      color: Colors.white,
                      size: 15,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _formatPlaybackSpeed(_playbackSpeed),
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

            const SizedBox(width: 8),

            // Nút chọn Chất lượng (1080P / 720P / 480P / 360P / Tự động)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _showFeedQualitySheet,
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 11),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white24, width: 0.6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.high_quality_rounded,
                      color: AppColors.primaryEmerald,
                      size: 15,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _activeVideoInfo?.selectedRendition?.qualityLabel ??
                          (_preferredQuality == 'auto'
                              ? 'AUTO'
                              : '${_preferredQuality}P'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Top Bar khi ở chế độ Lướt Khám Phá (Frame 3 Style)
    return Positioned(
      top: topPadding + 6,
      left: 12,
      right: 12,
      child: Row(
        children: [
          // Nút Back thoát chế độ lướt
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.35),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.arrow_back_ios_new_rounded,
                color: Colors.white,
                size: 18,
              ),
            ),
          ),

          // Thanh Tab trung tâm dạng thanh trượt cuộn ngang (Scrollable Tabs)
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildTopTabItem(
                      label: 'Quan tâm',
                      isSelected: _currentFeedTab == _tabFollow,
                      onTap: () => _onTopFeedTabTap(_tabFollow),
                    ),
                    const SizedBox(width: 14),
                    _buildTopTabItem(
                      label: 'Mạn kịch',
                      isSelected: _currentFeedTab == _tabComic,
                      onTap: () => _onTopFeedTabTap(_tabComic),
                    ),
                    const SizedBox(width: 14),
                    _buildTopTabItem(
                      label: 'Người thật',
                      isSelected: _currentFeedTab == _tabReal,
                      onTap: () => _onTopFeedTabTap(_tabReal),
                    ),
                    const SizedBox(width: 14),
                    _buildTopTabItem(
                      label: 'Đề xuất',
                      isSelected: _currentFeedTab == _tabDiscover,
                      onTap: () => _onTopFeedTabTap(_tabDiscover),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Khoảng cân đối bên phải (bỏ nút tìm kiếm & làm mới kiểu TikTok)
          const SizedBox(width: 34),
        ],
      ),
    );
  }

  Widget _buildTopTabItem({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    bool showDropdownIcon = false,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: isSelected
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.65),
                  fontSize: isSelected ? 16 : 14.5,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  shadows: const [Shadow(color: Colors.black54, blurRadius: 4)],
                ),
              ),
              if (showDropdownIcon) ...[
                const SizedBox(width: 2),
                Icon(
                  Icons.arrow_drop_down_rounded,
                  color: isSelected ? const Color(0xFFFF6A00) : Colors.white60,
                  size: 18,
                ),
              ],
            ],
          ),
          const SizedBox(height: 3),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: isSelected ? 22 : 0,
            height: 2.5,
            decoration: BoxDecoration(
              color: isSelected ? const Color(0xFFFF6A00) : Colors.transparent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }

  /// Lớp Overlay chứa thông tin phim (Bottom Left) và cột tác vụ (Right Action Column)
  Widget _buildOverlayUI(FeedDramaPageItem item) {
    if (_isLandscapeFullscreen || _isCleanMode) {
      return const SizedBox.shrink();
    }

    final title = _displayTitleFor(item.detail);
    final intro = _displayIntroFor(item.detail);
    final total = math.max(
      1,
      math.max(item.detail.episodes.length, item.detail.totalEpisodes),
    );

    final bottomPadding = MediaQuery.of(context).padding.bottom + 26;

    return Positioned(
      left: 12,
      right: 12,
      bottom: bottomPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Cột thông tin phim bên trái
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Tiêu đề phim có dấu mũi tên `>` (nhấn vào mở xem trọn bộ, nhấn giữ để sao chép tiêu đề)
                    GestureDetector(
                      onTap: () => _showEpisodePickerSheet(item.detail),
                      onLongPress: () {
                        HapticFeedback.lightImpact();
                        Clipboard.setData(
                          ClipboardData(text: item.detail.title),
                        );
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Row(
                              children: [
                                const Icon(
                                  Icons.copy_rounded,
                                  color: Color(0xFFFF6A00),
                                  size: 16,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Đã sao chép tiêu đề: ${item.detail.title}',
                                  ),
                                ),
                              ],
                            ),
                            backgroundColor: const Color(0xFF22242A),
                            behavior: SnackBarBehavior.floating,
                            duration: const Duration(seconds: 2),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        );
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                shadows: [
                                  Shadow(color: Colors.black87, blurRadius: 4),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.arrow_forward_ios_rounded,
                            color: Colors.white70,
                            size: 13,
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 6),

                    // Hàng thẻ Tags được Việt hoá (chạm vào để lọc phim theo tag đó ngay)
                    if (item.detail.tags.isNotEmpty)
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: item.detail.tags.take(4).map((tag) {
                          final viLabel = HongguoSimilarEngine.getTagLabel(tag);
                          return GestureDetector(
                            onTap: () => _filterByTag(tag, detail: item.detail),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2.5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.38),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.16),
                                  width: 0.6,
                                ),
                              ),
                              child: Text(
                                '#$viLabel',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),

                    const SizedBox(height: 6),

                    // Tóm tắt tập và mô tả có nút `Xem thêm` / `Thu gọn` (Frame 3 Style)
                    GestureDetector(
                      onTap: () => setState(
                        () => _isDescriptionExpanded = !_isDescriptionExpanded,
                      ),
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: 'Tập ${item.episodeIndex} | ',
                              style: const TextStyle(
                                color: Color(0xFFFF9E40),
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                            TextSpan(
                              text: intro.isNotEmpty
                                  ? intro
                                  : 'Diễn biến gay cấn trọn bộ...',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                            TextSpan(
                              text: _isDescriptionExpanded
                                  ? '  Thu gọn'
                                  : '...  Xem thêm',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        maxLines: _isDescriptionExpanded ? 8 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          shadows: [
                            Shadow(color: Colors.black87, blurRadius: 4),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 6),

                    // Dòng bản quyền tác giả: `ⓘ Tác giả: Nội dung tạo bởi AI`
                    const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          color: Colors.white38,
                          size: 11,
                        ),
                        SizedBox(width: 4),
                        Text(
                          'Tuyên bố: Nội dung hỗ trợ dịch bởi AI',
                          style: TextStyle(color: Colors.white38, fontSize: 10),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 14),

              // Cột nút tác vụ bên phải (TikTok / Shorts Vertical Column)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 1. Nút Vietsub Trực Tiếp
                  _buildVietsubButton(item),

                  const SizedBox(height: 14),

                  // 2. Nút Lồng Tiếng AI Trực Tiếp
                  _buildDubbingButton(item),

                  const SizedBox(height: 14),

                  // 2b. Nút Nghe Dịch Trực Tiếp (Gemini 3.5 Live)
                  _buildLiveTranslateButton(item),

                  const SizedBox(height: 14),

                  // 3. Nút Tự động chuyển tập (kèm Dịch & Lồng tiếng trước trong nền)
                  _buildAutoNextEpisodeButton(item),

                  const SizedBox(height: 14),

                  // 4. Nút Lưu xem sau / Yêu thích
                  ValueListenableBuilder<List<WatchLaterItem>>(
                    valueListenable: WatchLaterRepository.watchLaterNotifier,
                    builder: (context, wlList, _) {
                      final isSaved = wlList.any(
                        (w) => w.seriesId == item.detail.seriesId,
                      );
                      return _buildRightActionButton(
                        icon: isSaved
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        iconColor: isSaved
                            ? const Color(0xFFFFB800)
                            : Colors.white,
                        label: isSaved ? 'Đã lưu' : 'Lưu lại',
                        onTap: () async {
                          HapticFeedback.lightImpact();
                          final repo = await WatchLaterRepository.getInstance();
                          if (isSaved) {
                            await repo.removeItem(item.detail.seriesId);
                          } else {
                            await repo.addItem(
                              WatchLaterItem(
                                id: item.detail.seriesId,
                                title: item.detail.title,
                                coverUrl: item.detail.cover,
                                source: 'hongguo',
                                targetUrl:
                                    'https://hongguoduanju.com/player/${item.detail.seriesId}',
                                seriesId: item.detail.seriesId,
                                totalEpisodes: item.detail.totalEpisodes,
                                addedAt: DateTime.now().millisecondsSinceEpoch,
                              ),
                            );
                            HongguoSimilarEngine.instance.recordInterest(
                              item.detail.tags,
                              4.0,
                            );
                          }
                        },
                      );
                    },
                  ),

                  const SizedBox(height: 14),

                  // 5. Nút Tìm phim tương tự (Zone-based Tag Matching)
                  _buildRightActionButton(
                    icon: Icons.auto_awesome_motion_rounded,
                    iconColor: const Color(0xFF2DE1FC),
                    label: 'Tương tự',
                    onTap: () => _openSimilarDramasSheet(item),
                  ),

                  const SizedBox(height: 14),

                  // 6. Nút Ẩn giao diện / Xem gọn không bị che (Clean View Mode)
                  _buildRightActionButton(
                    icon: Icons.visibility_off_outlined,
                    iconColor: Colors.white,
                    label: 'Ẩn nút',
                    onTap: () {
                      HapticFeedback.mediumImpact();
                      setState(() {
                        _isCleanMode = true;
                      });
                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: const Row(
                            children: [
                              Icon(
                                Icons.touch_app_rounded,
                                color: Colors.white,
                                size: 16,
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Đã ẩn giao diện. Chạm vào màn hình để hiện lại.',
                                ),
                              ),
                            ],
                          ),
                          backgroundColor: Colors.black87,
                          behavior: SnackBarBehavior.floating,
                          duration: const Duration(seconds: 2),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Thanh Pill Bar chuẩn ByteDance (Frame 3 vs Frame 8)
          GestureDetector(
            onTap: () => _showEpisodePickerSheet(item.detail),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white12, width: 0.6),
              ),
              child: Row(
                children: [
                  Icon(
                    _isDramaEpisodeMode
                        ? Icons.format_list_bulleted_rounded
                        : Icons.play_circle_fill_rounded,
                    color: const Color(0xFFFF6A00),
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isDramaEpisodeMode
                        ? 'Chọn tập · Trọn bộ $total tập · Miễn phí'
                        : 'Xem trọn bộ · Toàn bộ $total tập',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _isDramaEpisodeMode
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.arrow_forward_ios_rounded,
                    color: Colors.white70,
                    size: 14,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Nút tác vụ dạng icon tròn bên phải
  Widget _buildRightActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    Color iconColor = Colors.white,
  }) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white24, width: 0.6),
            ),
            child: Icon(icon, color: iconColor, size: 24),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w500,
              shadows: [Shadow(color: Colors.black, blurRadius: 2)],
            ),
          ),
        ],
      ),
    );
  }

  /// Thanh tua tiến trình dạng Scrubber với thanh trượt mượt mà (Hongguo Style)
  Widget _buildProgressScrubber() {
    final durMs = _currentDur.inMilliseconds;
    final posMs = _currentPos.inMilliseconds;
    final progress = (durMs > 0) ? (posMs / durMs).clamp(0.0, 1.0) : 0.0;
    final displayProgress = _isScrubbing ? _scrubValue : progress;

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (details) {
            _ttsScheduler?.pause();
            _liveTranslator?.onVideoStateUpdate(
              positionMs: _currentPos.inMilliseconds,
              isPlaying: false,
              isBuffering: _isPlayerBuffering,
              isScrubbing: true,
              playbackSpeed: _playbackSpeed,
            );
            setState(() {
              _isScrubbing = true;
              _scrubValue = (details.localPosition.dx / totalWidth).clamp(
                0.0,
                1.0,
              );
            });
          },
          onHorizontalDragUpdate: (details) {
            setState(() {
              _scrubValue = (details.localPosition.dx / totalWidth).clamp(
                0.0,
                1.0,
              );
            });
          },
          onHorizontalDragEnd: (details) {
            if (_activeController != null && durMs > 0) {
              final targetPos = Duration(
                milliseconds: (_scrubValue * durMs).toInt(),
              );
              final wasPlaying =
                  (_activeController!.value.isPlaying && !_isManuallyPaused) ||
                  _waitingLiveWarmupResume;
              _activeController!.player.seek(targetPos);
              _ttsScheduler?.onSeek(targetPos.inMilliseconds);
              if (_liveTranslator?.isEnabled == true) {
                if (wasPlaying &&
                    (_liveTranslator?.pauseVideoOnWarmup ?? false)) {
                  unawaited(_beginLiveWarmupPauseIfNeeded());
                }
                unawaited(_liveTranslator!.onSeek(targetPos.inMilliseconds));
              }
            }
            setState(() {
              _isScrubbing = false;
            });
          },
          child: Container(
            height: 18,
            alignment: Alignment.center,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                // Track nền màu xám
                Container(
                  height: 2.2,
                  width: totalWidth,
                  color: Colors.white.withValues(alpha: 0.22),
                ),

                // Track đã phát màu Cam ByteDance `#FF6A00`
                Container(
                  height: 2.5,
                  width: totalWidth * displayProgress,
                  decoration: const BoxDecoration(
                    color: Color(0xFFFF6A00),
                    boxShadow: [
                      BoxShadow(color: Color(0x66FF6A00), blurRadius: 4),
                    ],
                  ),
                ),

                // Nút tròn Thumb
                Positioned(
                  left: (totalWidth * displayProgress - 4.5).clamp(
                    0.0,
                    totalWidth - 9,
                  ),
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(color: Colors.black45, blurRadius: 3),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // =========================================================================
  // PHẦN TÍCH HỢP VIETSUB & LỒNG TIẾNG TRỰC TIẾP TRÊN SHORTS FEED
  // =========================================================================

  /// Nút Vietsub trực tiếp: Bật/tắt sub hoặc dịch siêu tốc nếu chưa có
  Widget _buildVietsubButton(FeedDramaPageItem item) {
    final docKey = _getVideoDocKey(item);
    final hasDoc = _episodeDocuments.containsKey(docKey);
    final isSubActive = hasDoc && _showSubtitles;
    final isCurrentTranslating = _isTranslatingCurrent && !_translatingWithTts;

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        if (hasDoc) {
          setState(() {
            _showSubtitles = !_showSubtitles;
          });
        } else {
          _translateCurrentEpisode(enableTts: false);
        }
      },
      onLongPress: () {
        HapticFeedback.mediumImpact();
        if (_settings != null) {
          showModalBottomSheet(
            context: context,
            backgroundColor: Colors.transparent,
            isScrollControlled: true,
            builder: (ctx) => SubtitleControlSheet(
              settings: _settings!,
              onChanged: () => setState(() {}),
            ),
          );
        }
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isSubActive
                  ? const Color(0x338B5CF6)
                  : Colors.black.withValues(alpha: 0.45),
              shape: BoxShape.circle,
              border: Border.all(
                color: isSubActive
                    ? const Color(0xFF8B5CF6)
                    : (isCurrentTranslating
                          ? const Color(0xFFFF6A00)
                          : Colors.white24),
                width: isSubActive ? 1.5 : 0.6,
              ),
              boxShadow: isSubActive
                  ? const [BoxShadow(color: Color(0x668B5CF6), blurRadius: 8)]
                  : null,
            ),
            child: isCurrentTranslating
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      valueColor: AlwaysStoppedAnimation(Color(0xFFFF6A00)),
                    ),
                  )
                : Icon(
                    Icons.subtitles_rounded,
                    color: isSubActive ? const Color(0xFF8B5CF6) : Colors.white,
                    size: 24,
                  ),
          ),
          const SizedBox(height: 4),
          Text(
            isSubActive ? 'Vietsub' : (hasDoc ? 'Tắt Sub' : 'Vietsub'),
            style: TextStyle(
              color: isSubActive ? const Color(0xFF8B5CF6) : Colors.white,
              fontSize: 10,
              fontWeight: isSubActive ? FontWeight.bold : FontWeight.w500,
              shadows: const [Shadow(color: Colors.black, blurRadius: 2)],
            ),
          ),
        ],
      ),
    );
  }

  /// Nút Lồng tiếng AI trực tiếp: Bật/tắt thuyết minh hoặc dịch + tạo giọng AI
  Widget _buildDubbingButton(FeedDramaPageItem item) {
    final docKey = _getVideoDocKey(item);
    final doc = _episodeDocuments[docKey];
    final hasTts =
        doc != null &&
        doc.items.any(
          (i) => i.audioFilePath != null && i.audioFilePath!.isNotEmpty,
        );
    final isDubbingActive = _isTtsActive && hasTts;
    final isCurrentTranslating = _isTranslatingCurrent && _translatingWithTts;

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        _toggleTts();
      },
      onLongPress: () {
        HapticFeedback.mediumImpact();
        if (_settings != null) {
          showModalBottomSheet(
            context: context,
            backgroundColor: Colors.transparent,
            isScrollControlled: true,
            builder: (ctx) => DualVolumeSheet(
              originalVolume: _settings!.originalVideoVolume,
              aiVolume: _settings!.ttsVolume,
              onOriginalVolumeChanged: (val) {
                _settings!.originalVideoVolume = val;
                if (_isTtsActive) {
                  _activeController?.setVolume(val);
                }
                setState(() {});
              },
              onAiVolumeChanged: (val) {
                _settings!.ttsVolume = val;
                _ttsScheduler?.setVolume(val);
                setState(() {});
              },
            ),
          );
        }
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isDubbingActive
                  ? const Color(0x3310B981)
                  : Colors.black.withValues(alpha: 0.45),
              shape: BoxShape.circle,
              border: Border.all(
                color: isDubbingActive
                    ? AppColors.primaryEmerald
                    : (isCurrentTranslating
                          ? const Color(0xFFFF6A00)
                          : Colors.white24),
                width: isDubbingActive ? 1.5 : 0.6,
              ),
              boxShadow: isDubbingActive
                  ? const [BoxShadow(color: Color(0x6610B981), blurRadius: 8)]
                  : null,
            ),
            child: isCurrentTranslating
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      valueColor: AlwaysStoppedAnimation(Color(0xFFFF6A00)),
                    ),
                  )
                : Icon(
                    Icons.record_voice_over_rounded,
                    color: isDubbingActive
                        ? AppColors.primaryEmerald
                        : Colors.white,
                    size: 24,
                  ),
          ),
          const SizedBox(height: 4),
          Text(
            isDubbingActive
                ? 'Lồng tiếng'
                : (hasTts ? 'Tắt tiếng' : 'Lồng tiếng'),
            style: TextStyle(
              color: isDubbingActive ? AppColors.primaryEmerald : Colors.white,
              fontSize: 10,
              fontWeight: isDubbingActive ? FontWeight.bold : FontWeight.w500,
              shadows: const [Shadow(color: Colors.black, blurRadius: 2)],
            ),
          ),
        ],
      ),
    );
  }

  LiveStreamTranslator _createLiveTranslator(SettingsRepository settings) {
    final translator = LiveStreamTranslator(settings: settings);
    translator.onFirstOutputArrived = _handleLiveTranslatorFirstOutput;
    return translator;
  }

  void _cancelLiveWarmupPause({bool finishTranslatorWarmup = false}) {
    _liveWarmupTimeoutTimer?.cancel();
    _liveWarmupTimeoutTimer = null;
    _waitingLiveWarmupResume = false;
    if (finishTranslatorWarmup) {
      _liveTranslator?.finishWarmup();
    }
  }

  void _handleLiveTranslatorFirstOutput() {
    if (!mounted) return;
    _liveWarmupTimeoutTimer?.cancel();
    _liveWarmupTimeoutTimer = null;
    if (!_waitingLiveWarmupResume) return;
    _waitingLiveWarmupResume = false;
    _liveTranslator?.finishWarmup();
    if (!_isManuallyPaused &&
        _activeController != null &&
        !_activeController!.value.isPlaying) {
      unawaited(_activeController!.player.play());
    }
    setState(() {});
  }

  Future<bool> _beginLiveWarmupPauseIfNeeded() async {
    final controller = _activeController;
    final translator = _liveTranslator;
    if (!mounted ||
        controller == null ||
        _isManuallyPaused ||
        !controller.value.isPlaying ||
        translator == null ||
        !translator.pauseVideoOnWarmup) {
      return false;
    }
    _waitingLiveWarmupResume = true;
    _liveWarmupTimeoutTimer?.cancel();
    _liveWarmupTimeoutTimer = Timer(
      const Duration(milliseconds: 2800),
      _handleLiveTranslatorFirstOutput,
    );
    await controller.player.pause();
    return true;
  }

  Future<LiveAudioSource?> _resolveLiveAudioSourceForIndex(int index) async {
    if (index < 0 || index >= _feedItems.length) return null;
    final item = _feedItems[index];
    final label = '${item.detail.title} - Tập ${item.episodeIndex}';

    try {
      final cached = await VideoCacheManager.findCachedFile(
        url: '',
        seriesId: item.detail.seriesId,
        episodeIndex: item.episodeIndex,
      );
      if (cached != null &&
          cached.existsSync() &&
          cached.lengthSync() > 1024 * 50) {
        return LiveAudioSource(mediaPath: cached.path, sourceLabel: label);
      }
    } catch (_) {}

    final mediaKey = _mediaKey(item);
    var source = _preloadedSources[mediaKey];
    if (source == null || source.url.isEmpty) {
      try {
        source = await _resolveEpisodeStreamSource(item);
        _preloadedSources[mediaKey] = source;
      } catch (e) {
        debugPrint('[HongguoFeed] Không phân giải được luồng live audio: $e');
        return null;
      }
    }

    // Video Hồng Quả có CENC DRM -> đẩy qua HongguoStreamProxyServer (giải mã sạch trên RAM + dùng chung cache)
    if (source.decryptionKey != null && source.decryptionKey!.isNotEmpty) {
      await HongguoStreamProxyServer.instance.ensureStarted();
      final resolvedVid = source.vid.isNotEmpty ? source.vid : item.vid;
      if (source.videoInfo != null) {
        HongguoStreamProxyServer.instance.registerVideoInfo(
          vid: resolvedVid,
          info: source.videoInfo!,
          seriesId: item.detail.seriesId,
          episodeIndex: item.episodeIndex,
        );
      }
      final proxyUrl = HongguoStreamProxyServer.instance.getStreamUrl(
        vid: resolvedVid,
        seriesId: item.detail.seriesId,
        episodeIndex: item.episodeIndex,
      );
      return LiveAudioSource(mediaPath: proxyUrl, sourceLabel: label);
    }

    return LiveAudioSource(
      mediaPath: source.url,
      headers: source.headers,
      sourceLabel: label,
    );
  }

  Future<void> _syncLiveTranslatorForIndex(
    int index, {
    int startPosMs = 0,
  }) async {
    final translator = _liveTranslator;
    final settings = _settings;
    if (translator == null || !translator.isEnabled || settings == null) {
      return;
    }
    _cancelLiveWarmupPause(finishTranslatorWarmup: false);
    final liveSourceFuture = _resolveLiveAudioSourceForIndex(index);
    await translator.prepareForSourceSwitch();
    final liveSource = await liveSourceFuture;
    if (!mounted ||
        index != _currentIndex ||
        !translator.isEnabled ||
        liveSource == null ||
        !liveSource.isValid) {
      return;
    }
    await translator.updateSource(
      source: liveSource,
      positionMs: startPosMs,
      apiKeys: settings.geminiApiKeys,
      playbackSpeed: _playbackSpeed,
    );
  }

  Future<void> _toggleLiveTranslate(bool enabled) async {
    final settings = _settings ?? await SettingsRepository.getInstance();
    _settings = settings;
    final translator = _liveTranslator ?? _createLiveTranslator(settings);
    _liveTranslator = translator;

    if (!enabled) {
      _cancelLiveWarmupPause(finishTranslatorWarmup: true);
      await translator.stop();
      if (!_isTtsActive) {
        await _activeController?.setVolume(1.0);
      }
      if (mounted) setState(() {});
      return;
    }

    if (settings.geminiApiKeys.isEmpty) {
      await translator.start(
        source: const LiveAudioSource(mediaPath: ''),
        apiKeys: const [],
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Chưa có Gemini API Key. Hãy thêm key trong Cài đặt để bật Nghe Dịch Live.',
            ),
            backgroundColor: Colors.orangeAccent.shade700,
          ),
        );
        setState(() {});
      }
      return;
    }

    final liveSource = await _resolveLiveAudioSourceForIndex(_currentIndex);
    if (liveSource == null || !liveSource.isValid) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Chưa sẵn sàng luồng âm thanh để nghe dịch live.'),
            backgroundColor: Colors.orangeAccent,
          ),
        );
      }
      return;
    }

    if (_isTtsActive) {
      await _stopTtsPlayback();
    }

    final wasPlaying =
        (_activeController?.value.isPlaying ?? false) && !_isManuallyPaused;
    final posMs = _currentPos.inMilliseconds;
    if (wasPlaying) {
      await _beginLiveWarmupPauseIfNeeded();
    }

    await translator.start(
      source: liveSource,
      apiKeys: settings.geminiApiKeys,
      initialPositionMs: posMs,
      playbackSpeed: _playbackSpeed,
      isPlaying: wasPlaying,
    );
    await _activeController?.setVolume(settings.originalVideoVolume);
    if (mounted) setState(() {});
  }

  Future<void> _openLiveTranslateSheet() async {
    final settings = _settings ?? await SettingsRepository.getInstance();
    _settings = settings;
    final translator = _liveTranslator ?? _createLiveTranslator(settings);
    _liveTranslator = translator;
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => LiveTranslateSheet(
        translator: translator,
        settings: settings,
        originalVideoVolume: settings.originalVideoVolume,
        hasGeminiKeys: settings.geminiApiKeys.isNotEmpty,
        onOriginalVideoVolumeChanged: (val) {
          settings.originalVideoVolume = val;
          if (_isTtsActive || translator.isEnabled) {
            _activeController?.setVolume(val);
          }
          if (mounted) setState(() {});
        },
        onToggleEnabled: _toggleLiveTranslate,
        onOpenGeminiSettings: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          );
          if (mounted) setState(() {});
        },
      ),
    );
  }

  /// Nút Nghe Dịch Trực Tiếp (Gemini 3.5 Live): chạm để chỉnh lookahead & bật/tắt, giữ lâu bật/tắt nhanh
  Widget _buildLiveTranslateButton(FeedDramaPageItem item) {
    final translator = _liveTranslator;
    Widget buildButton(bool isActive, double leadSec) {
      final accent = isActive
          ? const Color(0xFF64B5F6)
          : Colors.white;
      return GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          _openLiveTranslateSheet();
        },
        onLongPress: () {
          HapticFeedback.mediumImpact();
          _toggleLiveTranslate(!isActive);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isActive
                    ? const Color(0x3364B5F6)
                    : Colors.black.withValues(alpha: 0.45),
                shape: BoxShape.circle,
                border: Border.all(
                  color: isActive ? const Color(0xFF64B5F6) : Colors.white24,
                  width: isActive ? 1.5 : 0.6,
                ),
                boxShadow: isActive
                    ? const [BoxShadow(color: Color(0x6664B5F6), blurRadius: 8)]
                    : null,
              ),
              child: Icon(
                Icons.spatial_audio_rounded,
                color: accent,
                size: 24,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              isActive ? '+${leadSec.toStringAsFixed(1)}s' : 'Dịch Live',
              style: TextStyle(
                color: accent,
                fontSize: 10,
                fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                shadows: const [Shadow(color: Colors.black, blurRadius: 2)],
              ),
            ),
          ],
        ),
      );
    }

    if (translator == null) {
      return buildButton(false, 2.0);
    }
    return AnimatedBuilder(
      animation: translator,
      builder: (_, _) => buildButton(translator.isEnabled, translator.leadSeconds),
    );
  }

  /// Nút Tự động chuyển tập (Auto Next) & Dịch trước ngầm
  Widget _buildAutoNextEpisodeButton(FeedDramaPageItem item) {
    return GestureDetector(
      onTap: () async {
        HapticFeedback.lightImpact();
        if (!_isDramaEpisodeMode) {
          // Khi đang ở Discover Feed: Chuyển sang xem trọn bộ phim này & bật tự chuyển tập
          setState(() {
            _isAutoNextEpisode = true;
          });
          _settings?.hongguoAutoNextEpisode = true;
          await _switchToDramaEpisodeMode(
            item.detail,
            targetEpisode: item.episodeIndex,
          );
          await _activeController?.player.setPlaylistMode(PlaylistMode.none);
          _triggerPreTranslationQueue();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    const Icon(
                      Icons.playlist_play_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Đã bật Tự chuyển tập · Đang chuẩn bị trước $_preTranslateCount tập kế tiếp...',
                      ),
                    ),
                  ],
                ),
                backgroundColor: const Color(0xFFFF6A00),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 2),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            );
          }
        } else {
          // Khi đang ở chế độ Xem trọn bộ: Đảo trạng thái Bật / Tắt
          setState(() {
            _isAutoNextEpisode = !_isAutoNextEpisode;
          });
          _settings?.hongguoAutoNextEpisode = _isAutoNextEpisode;
          if (_isAutoNextEpisode) {
            await _activeController?.player.setPlaylistMode(PlaylistMode.none);
            _triggerPreTranslationQueue();
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Đã bật Tự chuyển tập (${_preTranslateMode == 'sub_and_tts' ? 'Vietsub + Lồng tiếng' : 'Chỉ Vietsub'}, dịch trước $_preTranslateCount tập)',
                  ),
                  backgroundColor: const Color(0xFFFF6A00),
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 2),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              );
            }
          } else {
            await _activeController?.player.setPlaylistMode(PlaylistMode.loop);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Đã tắt Tự chuyển tập'),
                  backgroundColor: Colors.black87,
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 2),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              );
            }
          }
        }
      },
      onLongPress: () {
        HapticFeedback.mediumImpact();
        _showAutoNextSettingsSheet();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _isAutoNextEpisode
                  ? const Color(0x33FF6A00)
                  : Colors.black.withValues(alpha: 0.45),
              shape: BoxShape.circle,
              border: Border.all(
                color: _isAutoNextEpisode
                    ? const Color(0xFFFF6A00)
                    : Colors.white24,
                width: _isAutoNextEpisode ? 1.5 : 0.6,
              ),
              boxShadow: _isAutoNextEpisode
                  ? const [BoxShadow(color: Color(0x66FF6A00), blurRadius: 8)]
                  : null,
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  _isAutoNextEpisode
                      ? Icons.playlist_play_rounded
                      : Icons.skip_next_rounded,
                  color: _isAutoNextEpisode
                      ? const Color(0xFFFF6A00)
                      : Colors.white,
                  size: 24,
                ),
                if (_isPreTranslating)
                  Positioned(
                    right: -2,
                    top: -2,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Color(0xFFFF6A00),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _isAutoNextEpisode ? 'Tự đổi tập' : 'Tự đổi tập',
            style: TextStyle(
              color: _isAutoNextEpisode
                  ? const Color(0xFFFF6A00)
                  : Colors.white,
              fontSize: 10,
              fontWeight: _isAutoNextEpisode
                  ? FontWeight.bold
                  : FontWeight.w500,
              shadows: const [Shadow(color: Colors.black, blurRadius: 2)],
            ),
          ),
        ],
      ),
    );
  }

  /// Bottom Sheet cài đặt Tự động chuyển tập & Dịch trước trong nền
  void _showAutoNextSettingsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Container(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).padding.bottom + 16,
                top: 16,
                left: 20,
                right: 20,
              ),
              decoration: const BoxDecoration(
                color: Color(0xFF1E2024),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Icon(
                        Icons.tune_rounded,
                        color: Color(0xFFFF6A00),
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'Cài đặt Tự chuyển tập & Dịch trước',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(
                          Icons.close_rounded,
                          color: Colors.white54,
                          size: 20,
                        ),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white12, height: 20),

                  // 1. Switch Tự động chuyển tập
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    activeThumbColor: const Color(0xFFFF6A00),
                    title: const Text(
                      'Tự động chuyển tập khi xem hết',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: const Text(
                      'Khi video kết thúc, tự động phát tập kế tiếp thay vì lặp lại.',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    value: _isAutoNextEpisode,
                    onChanged: (val) {
                      setSheetState(() => _isAutoNextEpisode = val);
                      setState(() => _isAutoNextEpisode = val);
                      _settings?.hongguoAutoNextEpisode = val;
                      if (val) {
                        _activeController?.player.setPlaylistMode(
                          PlaylistMode.none,
                        );
                        _triggerPreTranslationQueue();
                      } else {
                        _activeController?.player.setPlaylistMode(
                          PlaylistMode.loop,
                        );
                      }
                    },
                  ),

                  const SizedBox(height: 14),

                  // 2. Chế độ xử lý trước
                  const Text(
                    'Chế độ chuẩn bị trước cho các tập kế tiếp',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: RadioGroup<String>(
                      groupValue: _preTranslateMode,
                      onChanged: (val) {
                        if (val == null) return;
                        setSheetState(() => _preTranslateMode = val);
                        setState(() => _preTranslateMode = val);
                        _settings?.hongguoPreTranslateMode = val;
                        if (_isAutoNextEpisode) _triggerPreTranslationQueue();
                      },
                      child: const Column(
                        children: [
                          RadioListTile<String>(
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 10,
                            ),
                            activeColor: Color(0xFFFF6A00),
                            title: Text(
                              'Vietsub & Lồng tiếng AI (Khuyên dùng)',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            subtitle: Text(
                              'Tạo cả phụ đề tiếng Việt và giọng đọc AI trước để xem liền mạch.',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 11,
                              ),
                            ),
                            value: 'sub_and_tts',
                          ),
                          Divider(color: Colors.white10, height: 1),
                          RadioListTile<String>(
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 10,
                            ),
                            activeColor: Color(0xFFFF6A00),
                            title: Text(
                              'Chỉ tạo Phụ đề Vietsub',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            subtitle: Text(
                              'Chỉ dịch phụ đề trước, không tạo trước file giọng đọc.',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 11,
                              ),
                            ),
                            value: 'sub_only',
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // 3. Số tập dịch trước
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Số tập dịch trước trong nền',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '$_preTranslateCount tập',
                        style: const TextStyle(
                          color: Color(0xFFFF6A00),
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [1, 2, 3, 5].map((count) {
                      final isSelected = _preTranslateCount == count;
                      return Expanded(
                        child: GestureDetector(
                          onTap: () {
                            setSheetState(() => _preTranslateCount = count);
                            setState(() => _preTranslateCount = count);
                            _settings?.hongguoPreTranslateCount = count;
                            if (_isAutoNextEpisode) {
                              _triggerPreTranslationQueue();
                            }
                          },
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFFFF6A00)
                                  : Colors.white10,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isSelected
                                    ? const Color(0xFFFF6A00)
                                    : Colors.white12,
                              ),
                            ),
                            child: Center(
                              child: Text(
                                '$count tập',
                                style: TextStyle(
                                  color: isSelected
                                      ? Colors.white
                                      : Colors.white70,
                                  fontSize: 12,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '💡 Hệ thống tải luồng 360p siêu nhẹ (1.28MB) và xử lý ngầm, khi hết tập hiện tại thì tập sau đã có sẵn để xem ngay 0ms không phải chờ.',
                    style: TextStyle(color: Colors.white38, fontSize: 11),
                  ),

                  const SizedBox(height: 20),

                  // Nút Xong
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF6A00),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        if (_isAutoNextEpisode) _triggerPreTranslationQueue();
                      },
                      child: const Text(
                        'Xong & Áp dụng',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Tự động chuyển sang tập tiếp theo khi video hiện tại kết thúc
  Future<void> _handleAutoNextEpisode() async {
    if (!_isAutoNextEpisode || _isScrubbing || !mounted) return;

    // Nếu đang ở Discover Feed, chuyển sang chế độ Xem trọn bộ của phim này
    if (!_isDramaEpisodeMode) {
      if (_currentIndex >= 0 && _currentIndex < _feedItems.length) {
        final currentItem = _feedItems[_currentIndex];
        HongguoSimilarEngine.instance.recordInterest(
          currentItem.detail.tags,
          2.5,
        );
        await _switchToDramaEpisodeMode(
          currentItem.detail,
          targetEpisode: currentItem.episodeIndex + 1,
        );
        _triggerPreTranslationQueue();
        return;
      }
    }

    if (_currentIndex < _feedItems.length - 1) {
      if (_currentIndex >= 0 && _currentIndex < _feedItems.length) {
        final currentItem = _feedItems[_currentIndex];
        HongguoSimilarEngine.instance.recordInterest(
          currentItem.detail.tags,
          2.5,
        );
      }
      final nextIndex = _currentIndex + 1;
      HapticFeedback.mediumImpact();
      _pageController.animateToPage(
        nextIndex,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
      _triggerPreTranslationQueue();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Đã xem đến tập cuối cùng của bộ phim này!'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// Kích hoạt hàng đợi dịch trước các tập tiếp theo trong nền
  Future<void> _triggerPreTranslationQueue() async {
    if (!_isAutoNextEpisode || _isPreTranslating || !mounted) return;
    if (_feedItems.isEmpty || _currentIndex < 0) return;

    final startIdx = _currentIndex + 1;
    final endIdx = math.min(
      _feedItems.length - 1,
      _currentIndex + _preTranslateCount,
    );
    if (startIdx > endIdx) return;

    for (var i = startIdx; i <= endIdx; i++) {
      if (!_isAutoNextEpisode || !mounted) break;
      if (i >= _feedItems.length) break;

      final targetItem = _feedItems[i];
      final targetKey = _getVideoDocKey(targetItem);

      // 1. Đã có trong RAM
      if (_episodeDocuments.containsKey(targetKey)) {
        final existingDoc = _episodeDocuments[targetKey]!;
        if (_preTranslateMode == 'sub_and_tts') {
          final hasTts = existingDoc.items.any(
            (it) => it.audioFilePath != null && it.audioFilePath!.isNotEmpty,
          );
          if (!hasTts) {
            await _preGenerateTtsForDoc(existingDoc, targetItem);
          }
        }
        continue;
      }

      // 2. Đã có trong Lịch sử
      final loadedFromHistory = await _checkHistoryForDoc(targetItem);
      if (loadedFromHistory != null) {
        _episodeDocuments[targetKey] = loadedFromHistory;
        if (_preTranslateMode == 'sub_and_tts') {
          final hasTts = loadedFromHistory.items.any(
            (it) => it.audioFilePath != null && it.audioFilePath!.isNotEmpty,
          );
          if (!hasTts) {
            await _preGenerateTtsForDoc(loadedFromHistory, targetItem);
          }
        }
        continue;
      }

      // 3. Chưa có -> Dịch trước tập này
      await _preTranslateSingleEpisode(targetItem);
    }
  }

  Future<SubtitleDocument?> _checkHistoryForDoc(FeedDramaPageItem item) async {
    try {
      final historyRepo = await HistoryRepository.getInstance();
      final items = historyRepo.getHistory();
      for (final h in items) {
        if (h.seriesId == item.detail.seriesId &&
            h.episodeIndex == item.episodeIndex) {
          final doc = await historyRepo.loadSubtitleDocument(h);
          if (doc != null && doc.isNotEmpty) {
            final voiceType =
                _settings?.hongguoSelectedTtsVoice ??
                VoicePresets.defaultVoice.voiceType;
            await TtsCacheHelper.linkAudioFiles(doc, voiceType);
            await _calibratePlaybackSpeeds(doc);
            return doc;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _preGenerateTtsForDoc(
    SubtitleDocument doc,
    FeedDramaPageItem item,
  ) async {
    try {
      final settings = _settings ?? await SettingsRepository.getInstance();
      final voiceType = settings.hongguoSelectedTtsVoice;
      final voice = VoicePresets.vietnameseVoices.firstWhere(
        (v) => v.voiceType == voiceType,
        orElse: () => VoicePresets.defaultVoice,
      );
      await TtsCacheHelper.linkAudioFiles(doc, voice.voiceType);
      final unlinked = doc.items
          .where(
            (i) =>
                (i.audioFilePath == null || i.audioFilePath!.isEmpty) &&
                TtsGenerationManager.isPronounceable(i.translatedText),
          )
          .toList();

      if (unlinked.isNotEmpty) {
        await TtsGenerationManager().generateAll(
          document: doc,
          voice: voice,
          threadCount: settings.ttsThreadCount,
        );
        await TtsCacheHelper.linkAudioFiles(doc, voice.voiceType);
      }
      await _calibratePlaybackSpeeds(doc);
    } catch (_) {}
  }

  Future<void> _preTranslateSingleEpisode(FeedDramaPageItem targetItem) async {
    if (!mounted || _isPreTranslating) return;
    final targetKey = _getVideoDocKey(targetItem);
    if (_episodeDocuments.containsKey(targetKey)) return;

    _isPreTranslating = true;
    if (mounted) setState(() {});

    File? tempMp4;
    File? tempAudio;

    try {
      debugPrint(
        '[HongguoFeed] 🚀 Dịch trước ngầm: ${targetItem.detail.title} - Tập ${targetItem.episodeIndex}',
      );

      var itemToProcess = targetItem;
      if (itemToProcess.vid.isEmpty ||
          itemToProcess.vid == itemToProcess.detail.seriesId) {
        try {
          final fullDetail = await _resolver.getDramaDetail(
            itemToProcess.detail.seriesId,
          );
          if (fullDetail.episodes.isNotEmpty) {
            final epIdx = itemToProcess.episodeIndex.clamp(
              1,
              fullDetail.episodes.length,
            );
            itemToProcess = FeedDramaPageItem(
              detail: fullDetail,
              episodeIndex: epIdx,
              vid: fullDetail.episodes[epIdx - 1].vid,
            );
          }
        } catch (_) {}
      }

      if (itemToProcess.vid.isEmpty) return;

      final videoInfo = await HongguoLocalEngine.resolveVideoInfo(
        itemToProcess.vid,
        preferLowest: true,
      );
      final streamUrl = videoInfo.realMainUrl;
      if (streamUrl.isEmpty) return;

      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      tempMp4 = File(
        '${tempDir.path}/pre_${itemToProcess.detail.seriesId}_${itemToProcess.episodeIndex}_$timestamp.mp4',
      );
      tempAudio = File(
        '${tempDir.path}/pre_audio_${itemToProcess.detail.seriesId}_${itemToProcess.episodeIndex}_$timestamp.m4a',
      );

      if (videoInfo.isDrmProtected) {
        final keyBytes = Uint8List.fromList(hex.decode(videoInfo.contentKeyHex));
        final remote = HongguoRemoteVideo(url: streamUrl, contentKey: keyBytes);
        try {
          await remote.streamDecryptedToFile(tempMp4);
        } finally {
          remote.close();
        }
      } else {
        final headers = NetworkHeaderHelper.getHeadersForUrl(streamUrl);
        await MultiThreadDownloader.downloadFile(
          url: streamUrl,
          outputFile: tempMp4,
          headers: headers,
          concurrency: 4,
        );
      }

      if (!tempMp4.existsSync() || tempMp4.lengthSync() < 1024) return;

      await AudioExtractor.extractAudio(
        videoPath: tempMp4.path,
        outputPath: tempAudio.path,
      );

      final preRealDurationMs =
          await HongguoLocalEngine.resolveEffectiveDurationMs(
        localFilePath: tempAudio.path,
        vid: itemToProcess.vid,
        videoInfo: videoInfo,
      );

      try {
        if (tempMp4.existsSync()) await tempMp4.delete();
      } catch (_) {}

      if (!tempAudio.existsSync() || tempAudio.lengthSync() < 1024) return;

      final settings = _settings ?? await SettingsRepository.getInstance();
      final isCapcut = settings.hongguoTranslationMode == 'capcut';
      String engine = 'capcut';
      if (!isCapcut) {
        if (settings.geminiApiKeys.isNotEmpty) {
          engine = settings.selectedGeminiModel.isNotEmpty
              ? settings.selectedGeminiModel
              : 'gemini-3.1-flash-lite';
        } else if (settings.groqApiKeys.isNotEmpty) {
          engine = settings.selectedGroqModel.isNotEmpty
              ? settings.selectedGroqModel
              : 'openai/gpt-oss-120b';
        }
      }

      final pipeline = SubtitlingPipeline(
        apiKeys: settings.geminiApiKeys,
        groqApiKeys: settings.groqApiKeys,
        translationEngine: engine,
        stylePreset: 'Zhihu',
        customPrompt: settings.hongguoCustomPrompt,
        targetLanguage: 'vi-VN',
        geminiThreadCount: settings.geminiThreadCount,
        geminiBatchSize: settings.geminiBatchSize,
        groqThreadCount: settings.groqThreadCount,
        groqBatchSize: settings.groqBatchSize,
      );

      final doc = await pipeline.execute(
        videoPath: tempAudio.path,
        totalDurationMs: preRealDurationMs,
        sourceLanguage: 'zh-CN',
        seriesId: itemToProcess.detail.seriesId,
        episodeIndex: itemToProcess.episodeIndex,
      );

      try {
        if (tempAudio.existsSync()) await tempAudio.delete();
      } catch (_) {}

      if (doc.isEmpty) return;

      String? appliedVoice;
      if (_preTranslateMode == 'sub_and_tts') {
        final voiceType = settings.hongguoSelectedTtsVoice;
        final voice = VoicePresets.vietnameseVoices.firstWhere(
          (v) => v.voiceType == voiceType,
          orElse: () => VoicePresets.defaultVoice,
        );
        appliedVoice = voice.displayName;
        await TtsCacheHelper.linkAudioFiles(doc, voice.voiceType);

        final unlinked = doc.items
            .where(
              (i) =>
                  (i.audioFilePath == null || i.audioFilePath!.isEmpty) &&
                  TtsGenerationManager.isPronounceable(i.translatedText),
            )
            .toList();

        if (unlinked.isNotEmpty) {
          await TtsGenerationManager().generateAll(
            document: doc,
            voice: voice,
            threadCount: settings.ttsThreadCount,
          );
          await TtsCacheHelper.linkAudioFiles(doc, voice.voiceType);
        }
        await _calibratePlaybackSpeeds(doc);
      }

      _episodeDocuments[targetKey] = doc;

      try {
        final historyRepo = await HistoryRepository.getInstance();
        await historyRepo.saveHistory(
          videoPath: itemToProcess.vid,
          title:
              '${itemToProcess.detail.title} - Tập ${itemToProcess.episodeIndex}',
          document: doc,
          durationMs: preRealDurationMs,
          ttsVoice: appliedVoice,
          seriesId: itemToProcess.detail.seriesId,
          seriesCover: itemToProcess.detail.cover,
          episodeIndex: itemToProcess.episodeIndex,
          totalEpisodes: itemToProcess.detail.totalEpisodes > 0
              ? itemToProcess.detail.totalEpisodes
              : itemToProcess.detail.episodes.length,
          isOnlineStream: true,
        );
      } catch (_) {}

      debugPrint(
        '[HongguoFeed] ✅ Đã dịch trước ngầm thành công tập ${itemToProcess.episodeIndex}!',
      );
    } catch (e) {
      debugPrint(
        '[HongguoFeed] Lỗi dịch trước tập ${targetItem.episodeIndex}: $e',
      );
    } finally {
      try {
        if (tempMp4 != null && tempMp4.existsSync()) await tempMp4.delete();
        if (tempAudio != null && tempAudio.existsSync()) {
          await tempAudio.delete();
        }
      } catch (_) {}
      _isPreTranslating = false;
      if (mounted) setState(() {});
    }
  }

  /// Tự động nạp phụ đề từ Lịch sử nếu tập này đã từng được dịch trước đó
  Future<void> _checkHistoryForEpisode(int index) async {
    if (index < 0 || index >= _feedItems.length) return;
    final item = _feedItems[index];
    final epIdx = item.episodeIndex;
    final seriesId = item.detail.seriesId;
    final docKey = _getVideoDocKey(item);
    final mediaKey = _mediaKey(item);

    if (_episodeDocuments.containsKey(docKey)) {
      final doc = _episodeDocuments[docKey]!;
      final hasTts = doc.items.any(
        (i) => i.audioFilePath != null && i.audioFilePath!.isNotEmpty,
      );
      if (_isCurrentMedia(index, mediaKey)) {
        if (_isTtsActive && hasTts) {
          _ttsScheduler?.setDocument(doc);
          _activeController?.setVolume(_settings?.originalVideoVolume ?? 0.25);
          _ttsScheduler?.warmUp(_currentPos.inMilliseconds);
        } else {
          _ttsScheduler?.stop();
          _ttsScheduler?.setDocument(null);
          _activeController?.setVolume(1.0);
        }
        if (mounted) setState(() {});
      }
      return;
    }

    try {
      final historyRepo = await HistoryRepository.getInstance();
      final items = historyRepo.getHistory();
      HistoryItem? matchItem;
      for (final h in items) {
        if (h.seriesId == seriesId && h.episodeIndex == epIdx) {
          matchItem = h;
          break;
        }
      }

      if (matchItem != null) {
        final doc = await historyRepo.loadSubtitleDocument(matchItem);
        if (doc != null && doc.isNotEmpty && mounted) {
          _episodeDocuments[docKey] = doc;
          final voiceType =
              _settings?.hongguoSelectedTtsVoice ??
              VoicePresets.defaultVoice.voiceType;
          await TtsCacheHelper.linkAudioFiles(doc, voiceType);
          await _calibratePlaybackSpeeds(doc);

          if (_isCurrentMedia(index, mediaKey)) {
            final hasTts = doc.items.any(
              (i) => i.audioFilePath != null && i.audioFilePath!.isNotEmpty,
            );
            if (_isTtsActive && hasTts) {
              _ttsScheduler?.setDocument(doc);
              _activeController?.setVolume(
                _settings?.originalVideoVolume ?? 0.25,
              );
              _ttsScheduler?.warmUp(_currentPos.inMilliseconds);
            } else {
              _ttsScheduler?.stop();
              _ttsScheduler?.setDocument(null);
              _activeController?.setVolume(1.0);
            }
            if (mounted) setState(() {});
          }
        }
      } else {
        // Tập này chưa hề dịch -> Đảm bảo tắt hẳn TTS và volume 100%
        if (_isCurrentMedia(index, mediaKey)) {
          _ttsScheduler?.stop();
          _ttsScheduler?.setDocument(null);
          _activeController?.setVolume(1.0);
          if (mounted) setState(() {});
        }
      }
    } catch (e) {
      debugPrint('[HongguoFeedScreen] _checkHistoryForEpisode lỗi: $e');
    }
  }

  /// Khớp tốc độ nói của từng câu âm thanh TTS vào khoảng thời gian phụ đề
  Future<void> _calibratePlaybackSpeeds(SubtitleDocument doc) async {
    for (final item in doc.items) {
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

  /// Bắt đầu phát âm thanh lồng tiếng AI đồng bộ với video
  Future<void> _startTtsPlayback(SubtitleDocument doc) async {
    if (_liveTranslator?.isEnabled == true) {
      _cancelLiveWarmupPause(finishTranslatorWarmup: true);
      await _liveTranslator!.stop();
    }
    _ttsScheduler ??= TtsAudioScheduler(doc);
    _ttsScheduler!.setDocument(doc);
    await _ttsScheduler!.setVolume(_settings?.ttsVolume ?? 1.0);
    await _ttsScheduler!.setEnabled(true);
    _isTtsActive = true;
    // Tự động giảm âm lượng video gốc khi có giọng đọc tiếng Việt
    await _activeController?.setVolume(_settings?.originalVideoVolume ?? 0.25);
    await _ttsScheduler!.warmUp(_currentPos.inMilliseconds);
    if (mounted) setState(() {});
  }

  /// Dừng phát âm thanh lồng tiếng AI và phục hồi âm lượng video gốc
  Future<void> _stopTtsPlayback() async {
    if (_ttsScheduler != null) {
      await _ttsScheduler!.stop();
      await _ttsScheduler!.setEnabled(false);
    }
    _isTtsActive = false;
    if (!(_liveTranslator?.isEnabled ?? false)) {
      await _activeController?.setVolume(1.0);
    }
    if (mounted) setState(() {});
  }

  /// Chuyển đổi trạng thái Lồng tiếng AI
  Future<void> _toggleTts() async {
    if (_currentIndex < 0 || _currentIndex >= _feedItems.length) return;
    final currentItem = _feedItems[_currentIndex];
    final docKey = _getVideoDocKey(currentItem);
    final doc = _episodeDocuments[docKey];
    final hasTts =
        doc != null &&
        doc.items.any(
          (i) => i.audioFilePath != null && i.audioFilePath!.isNotEmpty,
        );

    if (_isTtsActive && hasTts) {
      await _stopTtsPlayback();
    } else {
      if (doc != null) {
        await _ensureTtsAndPlay(doc, currentItem);
      } else {
        await _translateCurrentEpisode(enableTts: true);
      }
    }
  }

  /// Đảm bảo tất cả câu đã được tạo giọng đọc AI trước khi phát
  Future<void> _ensureTtsAndPlay(
    SubtitleDocument doc,
    FeedDramaPageItem item,
  ) async {
    final settings = _settings ?? await SettingsRepository.getInstance();
    final voiceType = settings.hongguoSelectedTtsVoice;
    final voice = VoicePresets.vietnameseVoices.firstWhere(
      (v) => v.voiceType == voiceType,
      orElse: () => VoicePresets.defaultVoice,
    );

    await TtsCacheHelper.linkAudioFiles(doc, voice.voiceType);
    final unlinked = doc.items
        .where(
          (i) =>
              (i.audioFilePath == null || i.audioFilePath!.isEmpty) &&
              TtsGenerationManager.isPronounceable(i.translatedText),
        )
        .toList();

    if (unlinked.isNotEmpty) {
      setState(() {
        _isTranslatingCurrent = true;
        _translatingWithTts = true;
        _translationProgress = 0.85;
        _translationStatus = 'Đang lồng tiếng AI (${voice.displayName})...';
      });
      try {
        await TtsGenerationManager().generateAll(
          document: doc,
          voice: voice,
          threadCount: settings.ttsThreadCount,
        );
        await TtsCacheHelper.linkAudioFiles(doc, voice.voiceType);
        await _calibratePlaybackSpeeds(doc);
      } finally {
        if (mounted) {
          setState(() {
            _isTranslatingCurrent = false;
            _translatingWithTts = false;
          });
        }
      }
    } else {
      await _calibratePlaybackSpeeds(doc);
    }

    final docKey = _getVideoDocKey(item);
    if (_currentIndex >= 0 &&
        _currentIndex < _feedItems.length &&
        _getVideoDocKey(_feedItems[_currentIndex]) == docKey) {
      await _startTtsPlayback(doc);
      _showSubtitles = true;
      if (mounted) setState(() {});
    }
  }

  /// Thực thi toàn bộ quy trình Vietsub / Lồng tiếng siêu tốc cho tập hiện tại:
  /// - Sử dụng luồng 360p siêu nhẹ (1.28MB) tải trong 0.09s
  /// - Bóc tách audio 300KB và xóa ngay lập tức file video MP4 (tồn tại < 0.1s)
  /// - Chạy CapCut STT -> Gemini/Groq/CapCut dịch song ngữ
  /// - Tạo TTS nếu người dùng chọn Lồng tiếng
  /// - Lưu vào Lịch sử với tag `isOnlineStream: true` (chỉ lưu khi người dùng bấm dịch)
  Future<void> _translateCurrentEpisode({required bool enableTts}) async {
    if (_currentIndex < 0 || _currentIndex >= _feedItems.length) return;
    final item = _feedItems[_currentIndex];
    final epIdx = item.episodeIndex;
    final seriesId = item.detail.seriesId;
    final docKey = _getVideoDocKey(item);

    // 1. Kiểm tra trong bộ nhớ RAM
    if (_episodeDocuments.containsKey(docKey)) {
      final doc = _episodeDocuments[docKey]!;
      if (enableTts) {
        await _ensureTtsAndPlay(doc, item);
      } else {
        setState(() {
          _showSubtitles = !_showSubtitles;
        });
      }
      return;
    }

    // 2. Kiểm tra trong Lịch sử (HistoryRepository)
    try {
      final historyRepo = await HistoryRepository.getInstance();
      final items = historyRepo.getHistory();
      HistoryItem? matchItem;
      for (final h in items) {
        if (h.seriesId == seriesId && h.episodeIndex == epIdx) {
          matchItem = h;
          break;
        }
      }

      if (matchItem != null) {
        final loadedDoc = await historyRepo.loadSubtitleDocument(matchItem);
        if (loadedDoc != null && loadedDoc.isNotEmpty) {
          _episodeDocuments[docKey] = loadedDoc;
          final voiceType =
              _settings?.hongguoSelectedTtsVoice ??
              VoicePresets.defaultVoice.voiceType;
          await TtsCacheHelper.linkAudioFiles(loadedDoc, voiceType);
          await _calibratePlaybackSpeeds(loadedDoc);
          if (enableTts) {
            await _ensureTtsAndPlay(loadedDoc, item);
          } else {
            setState(() {
              _showSubtitles = true;
            });
          }
          return;
        }
      }
    } catch (e) {
      debugPrint('[HongguoFeed] Lỗi kiểm tra lịch sử: $e');
    }

    // 3. Nếu chưa có phụ đề: Tiến hành tải luồng 360p siêu nhẹ (1.28MB)
    if (_isTranslatingCurrent) return;

    setState(() {
      _isTranslatingCurrent = true;
      _translatingWithTts = enableTts;
      _translationProgress = 0.05;
      _translationStatus = 'Đang phân giải luồng 360p...';
    });

    File? tempMp4;
    File? tempAudio;

    try {
      // Bước A: Lấy URL luồng 360p
      final videoInfo = await HongguoLocalEngine.resolveVideoInfo(
        item.vid,
        preferLowest: true,
      );
      final streamUrl = videoInfo.realMainUrl;
      if (streamUrl.isEmpty) {
        throw StateError('Không thể lấy URL luồng 360p');
      }

      if (!mounted) return;
      setState(() {
        _translationProgress = 0.10;
        _translationStatus = 'Đang tải nhanh 1.28MB...';
      });

      // Bước B: Tải 1.28MB vào file tạm
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      tempMp4 = File(
        '${tempDir.path}/feed_360p_${seriesId}_${epIdx}_$timestamp.mp4',
      );
      tempAudio = File(
        '${tempDir.path}/feed_audio_${seriesId}_${epIdx}_$timestamp.m4a',
      );

      if (videoInfo.isDrmProtected) {
        final keyBytes = Uint8List.fromList(hex.decode(videoInfo.contentKeyHex));
        final remote = HongguoRemoteVideo(url: streamUrl, contentKey: keyBytes);
        try {
          await remote.streamDecryptedToFile(
            tempMp4,
            onProgress: (p) {
              if (!mounted) return;
              setState(() {
                _translationProgress = (0.10 + p * 0.15).clamp(0.10, 0.25);
                _translationStatus =
                    'Đang tải & giải mã stream: ${(p * 100).toInt()}%';
              });
            },
          );
        } finally {
          remote.close();
        }
      } else {
        final headers = NetworkHeaderHelper.getHeadersForUrl(streamUrl);
        await MultiThreadDownloader.downloadFile(
          url: streamUrl,
          outputFile: tempMp4,
          headers: headers,
          concurrency: 4,
          progressCallback: (p, msg) {
            if (!mounted) return;
            setState(() {
              _translationProgress = (0.10 + p * 0.15).clamp(0.10, 0.25);
              _translationStatus = 'Đang tải luồng: ${(p * 100).toInt()}%';
            });
          },
        );
      }

      if (!tempMp4.existsSync() || tempMp4.lengthSync() < 1024) {
        throw StateError('Tải tệp video tạm không thành công');
      }

      if (!mounted) return;
      setState(() {
        _translationProgress = 0.28;
        _translationStatus = 'Đang trích xuất audio ~0.1s...';
      });

      // Bước C: Bóc tách audio
      await AudioExtractor.extractAudio(
        videoPath: tempMp4.path,
        outputPath: tempAudio.path,
      );

      // XÓA NGAY FILE MP4 SAU KHI BÓC TÁCH ÂM THANH!
      // File chỉ tồn tại trên Flash ~0.1s rồi xóa ngay lập tức, 0% hại bộ nhớ
      try {
        if (tempMp4.existsSync()) {
          await tempMp4.delete();
          tempMp4 = null;
        }
      } catch (_) {}

      final audioPath =
          (tempAudio.existsSync() && tempAudio.lengthSync() > 1024)
          ? tempAudio.path
          : '';
      if (audioPath.isEmpty) {
        throw StateError('Bóc tách âm thanh thất bại');
      }

      if (!mounted) return;
      setState(() {
        _translationProgress = 0.32;
        _translationStatus = 'CapCut đang nhận diện giọng nói...';
      });

      // Bước D: Chạy SubtitlingPipeline
      final settings = _settings ?? await SettingsRepository.getInstance();
      final isCapcut = settings.hongguoTranslationMode == 'capcut';
      String engine = 'capcut';
      if (!isCapcut) {
        if (settings.geminiApiKeys.isNotEmpty) {
          engine = settings.selectedGeminiModel.isNotEmpty
              ? settings.selectedGeminiModel
              : 'gemini-3.1-flash-lite';
        } else if (settings.groqApiKeys.isNotEmpty) {
          engine = settings.selectedGroqModel.isNotEmpty
              ? settings.selectedGroqModel
              : 'openai/gpt-oss-120b';
        } else {
          engine = 'capcut';
        }
      }

      final pipeline = SubtitlingPipeline(
        apiKeys: settings.geminiApiKeys,
        groqApiKeys: settings.groqApiKeys,
        translationEngine: engine,
        stylePreset: 'Zhihu',
        customPrompt: settings.hongguoCustomPrompt,
        targetLanguage: 'vi-VN',
        geminiThreadCount: settings.geminiThreadCount,
        geminiBatchSize: settings.geminiBatchSize,
        groqThreadCount: settings.groqThreadCount,
        groqBatchSize: settings.groqBatchSize,
      );

      final sub = pipeline.progressStream.listen((prog) {
        if (!mounted) return;
        setState(() {
          _translationProgress = (0.32 + prog.progress * 0.50).clamp(
            0.32,
            0.82,
          );
          _translationStatus = prog.message.isNotEmpty
              ? prog.message
              : 'Đang xử lý phụ đề...';
        });
      });

      final manualRealDurationMs =
          await HongguoLocalEngine.resolveEffectiveDurationMs(
        localFilePath: audioPath,
        vid: item.vid,
        videoInfo: videoInfo,
        playerDurationMs: _currentDur.inMilliseconds,
      );

      final doc = await pipeline.execute(
        videoPath: audioPath,
        totalDurationMs: manualRealDurationMs,
        sourceLanguage: 'zh-CN',
        seriesId: seriesId,
        episodeIndex: epIdx,
      );
      await sub.cancel();

      // XÓA FILE AUDIO TẠM SAU KHI DỊCH XONG
      try {
        if (tempAudio.existsSync()) {
          await tempAudio.delete();
          tempAudio = null;
        }
      } catch (_) {}

      if (doc.isEmpty) {
        throw StateError('Không tìm thấy phụ đề');
      }

      // Bước E: Nếu người dùng yêu cầu Lồng tiếng
      String? appliedVoice;
      if (enableTts) {
        final voiceType = settings.hongguoSelectedTtsVoice;
        final voice = VoicePresets.vietnameseVoices.firstWhere(
          (v) => v.voiceType == voiceType,
          orElse: () => VoicePresets.defaultVoice,
        );
        appliedVoice = voice.displayName;

        await TtsCacheHelper.linkAudioFiles(doc, voice.voiceType);
        final unlinked = doc.items
            .where(
              (i) =>
                  (i.audioFilePath == null || i.audioFilePath!.isEmpty) &&
                  TtsGenerationManager.isPronounceable(i.translatedText),
            )
            .toList();

        if (unlinked.isNotEmpty) {
          if (mounted) {
            setState(() {
              _translationProgress = 0.85;
              _translationStatus =
                  'Đang lồng tiếng AI (${voice.displayName})...';
            });
          }
          await TtsGenerationManager().generateAll(
            document: doc,
            voice: voice,
            threadCount: settings.ttsThreadCount,
          );
          await TtsCacheHelper.linkAudioFiles(doc, voice.voiceType);
        }
        await _calibratePlaybackSpeeds(doc);
      }

      _episodeDocuments[docKey] = doc;

      // Bước F: LƯU LỊCH SỬ XEM (Có cờ isOnlineStream: true)
      // Chỉ khi bấm Vietsub / Lồng tiếng mới lưu vào lịch sử, tag rõ ràng [Lướt Online]
      try {
        final historyRepo = await HistoryRepository.getInstance();
        await historyRepo.saveHistory(
          videoPath: _preloadedSources[_mediaKey(item)]?.url ?? item.vid,
          title: '${item.detail.title} - Tập $epIdx',
          document: doc,
          durationMs: manualRealDurationMs,
          ttsVoice: appliedVoice,
          seriesId: seriesId,
          seriesCover: item.detail.cover,
          episodeIndex: epIdx,
          totalEpisodes: item.detail.totalEpisodes > 0
              ? item.detail.totalEpisodes
              : item.detail.episodes.length,
          isOnlineStream: true, // Tag rõ ràng là lướt online!
        );
      } catch (e) {
        debugPrint('[HongguoFeed] Lỗi lưu lịch sử: $e');
      }

      if (!mounted) return;

      // Chỉ kích hoạt phát nếu người dùng VẪN ĐANG Ở ĐÚNG TẬP NÀY
      if (_currentIndex >= 0 &&
          _currentIndex < _feedItems.length &&
          _getVideoDocKey(_feedItems[_currentIndex]) == docKey) {
        if (enableTts) {
          await _startTtsPlayback(doc);
          _showSubtitles = true;
        } else {
          _showSubtitles = true;
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                enableTts
                    ? 'Đã tạo lồng tiếng & Vietsub tập $epIdx!'
                    : 'Đã tạo Vietsub tập $epIdx!',
              ),
              backgroundColor: AppTheme.primaryEmerald,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[HongguoFeed] Lỗi dịch tập: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Lỗi tạo phụ đề: $e'),
            backgroundColor: Colors.redAccent,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      // Đảm bảo dọn dẹp file tạm nếu có lỗi
      try {
        if (tempMp4 != null && tempMp4.existsSync()) await tempMp4.delete();
        if (tempAudio != null && tempAudio.existsSync()) {
          await tempAudio.delete();
        }
      } catch (_) {}

      if (mounted) {
        setState(() {
          _isTranslatingCurrent = false;
          _translatingWithTts = false;
        });
      }
    }
  }
}

/// Callback khi chọn tập phim từ Bottom Sheet, kèm theo chi tiết đầy đủ của phim
typedef OnEpisodeSelectedCallback = void Function(
  int episodeIndex,
  HongguoDramaDetail fullDetail,
);
typedef OnTagSelectedCallback = void Function(String tag);

/// Bottom Sheet chọn tập chuẩn ByteDance (Frame 15 Style)
class _ByteDanceEpisodePickerSheet extends StatefulWidget {
  final HongguoDramaDetail detail;
  final int currentEpisode;
  final bool isTranslationEnabled;
  final OnEpisodeSelectedCallback onSelectEpisode;
  final OnTagSelectedCallback? onSelectTag;

  const _ByteDanceEpisodePickerSheet({
    required this.detail,
    required this.currentEpisode,
    this.isTranslationEnabled = true,
    required this.onSelectEpisode,
    this.onSelectTag,
  });

  @override
  State<_ByteDanceEpisodePickerSheet> createState() =>
      _ByteDanceEpisodePickerSheetState();
}

class _ByteDanceEpisodePickerSheetState
    extends State<_ByteDanceEpisodePickerSheet> {
  int _selectedTabIndex = 1; // 0: Giới thiệu (简介), 1: Chọn tập (选集)
  int _selectedRangeIndex =
      0; // Index của dải tập (ví dụ 0 tương ứng 1-30, 1 tương ứng 31-60)
  late HongguoDramaDetail _currentDetail;
  bool _isLoadingDetail = false;
  bool _isCopiedTitle = false;
  Timer? _copyTimer;

  static const int _episodesPerRange = 30;

  @override
  void dispose() {
    _copyTimer?.cancel();
    super.dispose();
  }

  void _copyDramaTitle(String textToCopy) {
    HapticFeedback.lightImpact();
    Clipboard.setData(ClipboardData(text: textToCopy));
    _copyTimer?.cancel();
    setState(() => _isCopiedTitle = true);
    _copyTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _isCopiedTitle = false);
    });
  }

  @override
  void initState() {
    super.initState();
    _currentDetail = widget.detail;
    _selectedRangeIndex = (widget.currentEpisode - 1) ~/ _episodesPerRange;
    _translateSheetMetadata();

    // Tự động tải toàn bộ danh sách tập nếu chi tiết chưa có danh sách tập
    if (_currentDetail.episodes.length <= 1) {
      _loadFullDetail();
    }
  }

  void _translateSheetMetadata() {
    if (!widget.isTranslationEnabled) return;
    final rawTitle = _currentDetail.title.trim();
    if (rawTitle.isNotEmpty &&
        OfflineMlKitTranslator.getCachedTitle(rawTitle) == null) {
      OfflineMlKitTranslator.translateHongguoTitle(rawTitle).then((_) {
        if (mounted) setState(() {});
      }).catchError((_) {});
    }
    final rawIntro = _currentDetail.intro.trim();
    if (rawIntro.isNotEmpty &&
        OfflineMlKitTranslator.getCachedIntro(rawIntro) == null) {
      OfflineMlKitTranslator.translateHongguoIntro(rawIntro).then((_) {
        if (mounted) setState(() {});
      }).catchError((_) {});
    }
  }

  Future<void> _loadFullDetail() async {
    setState(() => _isLoadingDetail = true);
    try {
      final full = await HongguoResolver().getDramaDetail(
        _currentDetail.seriesId,
      );
      if (mounted && full.episodes.isNotEmpty) {
        setState(() {
          _currentDetail = full;
          _isLoadingDetail = false;
          _selectedRangeIndex =
              (widget.currentEpisode - 1).clamp(0, full.episodes.length - 1) ~/
              _episodesPerRange;
        });
        _translateSheetMetadata();
      } else if (mounted) {
        setState(() => _isLoadingDetail = false);
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingDetail = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = math.max(
      1,
      math.max(_currentDetail.episodes.length, _currentDetail.totalEpisodes),
    );

    final rangeCount = (total / _episodesPerRange).ceil();
    final title = widget.isTranslationEnabled
        ? (OfflineMlKitTranslator.getCachedTitle(_currentDetail.title) ??
              _currentDetail.title)
        : _currentDetail.title;

    return Container(
      height: MediaQuery.of(context).size.height * 0.65,
      decoration: const BoxDecoration(
        color: Color(0xFF16181D),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black87,
            blurRadius: 16,
            offset: Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        children: [
          // Drag handle ở giữa
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 8),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header: Bìa phim + Tiêu đề + Trọn bộ N tập + Nút đóng (Frame 15 Style)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                // Ảnh bìa nhỏ bo góc
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.network(
                    _currentDetail.cover,
                    width: 46,
                    height: 62,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 46,
                      height: 62,
                      color: const Color(0xFF26282E),
                    ),
                  ),
                ),
                const SizedBox(width: 12),

                // Tiêu đề và tổng số tập (nhấn để sao chép tiêu đề)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _copyDramaTitle(
                          _currentDetail.title.isNotEmpty
                              ? _currentDetail.title
                              : title,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                physics: const BouncingScrollPhysics(),
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 200),
                              child: _isCopiedTitle
                                  ? Container(
                                      key: const ValueKey('copied_badge'),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 5,
                                        vertical: 1.5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFF6A00),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.check_rounded,
                                            color: Colors.white,
                                            size: 10,
                                          ),
                                          SizedBox(width: 2),
                                          Text(
                                            'Đã chép',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 9,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  : const Icon(
                                      Icons.copy_rounded,
                                      key: ValueKey('copy_icon'),
                                      color: Colors.white38,
                                      size: 13,
                                    ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _isLoadingDetail
                            ? 'Đang tải danh sách tập...'
                            : 'Trọn bộ $total tập · Miễn phí xem',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),

                // Nút Đóng
                IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    color: Colors.white70,
                    size: 20,
                  ),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),

          // Tab Bar chọn: `简介 (Giới thiệu)` | `选集 (Chọn tập)`
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _buildSheetTab('Giới thiệu', 0),
                const SizedBox(width: 24),
                _buildSheetTab('Chọn tập', 1),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),

          // Nội dung theo Tab
          Expanded(
            child: _selectedTabIndex == 0
                ? _buildSynopsisView(total)
                : _buildEpisodeGridView(total, rangeCount),
          ),
        ],
      ),
    );
  }

  Widget _buildSheetTab(String label, int index) {
    final isSelected = _selectedTabIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedTabIndex = index),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.white54,
                fontSize: 14,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          Container(
            height: 2.5,
            width: 28,
            decoration: BoxDecoration(
              color: isSelected ? const Color(0xFFFF6A00) : Colors.transparent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }

  /// Tab Giới thiệu phim
  Widget _buildSynopsisView(int total) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.detail.tags.isNotEmpty) ...[
            const Row(
              children: [
                Icon(
                  Icons.label_outline_rounded,
                  color: Color(0xFFFF6A00),
                  size: 14,
                ),
                SizedBox(width: 6),
                Text(
                  'Thể loại (chạm để xem thêm phim cùng chủ đề)',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: widget.detail.tags.map((t) {
                final viLabel = HongguoSimilarEngine.getTagLabel(t);
                return ActionChip(
                  avatar: const Icon(
                    Icons.tag_rounded,
                    size: 13,
                    color: Color(0xFFFF6A00),
                  ),
                  label: Text(
                    viLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  backgroundColor: const Color(0xFF26282E),
                  side: const BorderSide(color: Colors.white12, width: 0.8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  onPressed: () {
                    Navigator.pop(context);
                    widget.onSelectTag?.call(t);
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
          ],
          const Text(
            'Tóm tắt nội dung',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _currentDetail.intro.isNotEmpty
                ? (widget.isTranslationEnabled
                      ? (OfflineMlKitTranslator.getCachedIntro(
                              _currentDetail.intro,
                            ) ??
                            _currentDetail.intro)
                      : _currentDetail.intro)
                : 'Hiện chưa có phần giới thiệu chi tiết cho bộ phim này.',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  /// Tab Danh sách tập dạng Lưới 6 cột với dải phân trang (Frame 15 Style)
  Widget _buildEpisodeGridView(int total, int rangeCount) {
    if (_isLoadingDetail && total <= 1) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                color: Color(0xFFFF6A00),
                strokeWidth: 2.2,
              ),
            ),
            SizedBox(height: 12),
            Text(
              'Đang kết nối danh sách tập...',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      );
    }

    // Tính toán dải tập hiện tại
    final startEp = _selectedRangeIndex * _episodesPerRange + 1;
    final endEp = math.min(startEp + _episodesPerRange - 1, total);
    final countInRange = endEp - startEp + 1;

    return Column(
      children: [
        // Thanh chọn dải tập nằm ngang: `1-30` | `31-60` | `61-90`...
        if (rangeCount > 1)
          Container(
            height: 42,
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: rangeCount,
              itemBuilder: (ctx, i) {
                final rStart = i * _episodesPerRange + 1;
                final rEnd = math.min(rStart + _episodesPerRange - 1, total);
                final isSelected = i == _selectedRangeIndex;

                return GestureDetector(
                  onTap: () => setState(() => _selectedRangeIndex = i),
                  child: Container(
                    margin: const EdgeInsets.only(right: 12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0x33FF6A00)
                          : const Color(0xFF22242A),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFFFF6A00)
                            : Colors.transparent,
                        width: 1,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$rStart-$rEnd',
                      style: TextStyle(
                        color: isSelected
                            ? const Color(0xFFFF6A00)
                            : Colors.white70,
                        fontSize: 12,
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

        // Lưới 6 cột các ô tập phim (Frame 15 Style)
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 6,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.0,
            ),
            itemCount: countInRange,
            itemBuilder: (ctx, idx) {
              final epNum = startEp + idx;
              final isPlaying = epNum == widget.currentEpisode;

              return InkWell(
                onTap: () async {
                  var detailToUse = _currentDetail;
                  if (detailToUse.episodes.length <= 1) {
                    try {
                      final fetched = await HongguoResolver().getDramaDetail(
                        detailToUse.seriesId,
                      );
                      if (fetched.episodes.isNotEmpty) {
                        detailToUse = fetched;
                      }
                    } catch (_) {}
                  }
                  widget.onSelectEpisode(epNum, detailToUse);
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  decoration: BoxDecoration(
                    color: isPlaying
                        ? const Color(0x26FF6A00)
                        : const Color(0xFF22242A),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isPlaying
                          ? const Color(0xFFFF6A00)
                          : const Color(0xFF2C2F36),
                      width: isPlaying ? 1.2 : 0.8,
                    ),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Số tập
                      Text(
                        '$epNum',
                        style: TextStyle(
                          color: isPlaying
                              ? const Color(0xFFFF6A00)
                              : Colors.white,
                          fontWeight: isPlaying
                              ? FontWeight.bold
                              : FontWeight.w500,
                          fontSize: 14,
                        ),
                      ),

                      // Icon sóng nhạc 'ıll' ở góc trên bên phải khi đang phát (Frame 15 Style)
                      if (isPlaying)
                        const Positioned(
                          top: 4,
                          right: 4,
                          child: _EqualizerIcon(),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Icon sóng nhạc Equalizer 'ıll' biểu thị tập đang phát (Frame 15 Style)
class _EqualizerIcon extends StatelessWidget {
  const _EqualizerIcon();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _EqualizerBar(height: 6),
        SizedBox(width: 1.5),
        _EqualizerBar(height: 10),
        SizedBox(width: 1.5),
        _EqualizerBar(height: 7),
      ],
    );
  }
}

class _EqualizerBar extends StatelessWidget {
  final double height;
  const _EqualizerBar({required this.height});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 2,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFFFF6A00),
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }
}
