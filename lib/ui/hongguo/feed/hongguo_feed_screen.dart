import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
import '../../../domain/ai/offline_mlkit_translator.dart';
import '../../../domain/media/audio_extractor.dart';
import '../../../domain/media/hongguo/hongguo_local_engine.dart';
import '../../../domain/media/hongguo/hongguo_stream_proxy_server.dart';
import '../../../domain/media/hongguo_cenc_decryptor.dart';
import '../../../domain/media/hongguo_resolver.dart';
import '../../../domain/media/multi_thread_downloader.dart';
import '../../../domain/media/network_header_helper.dart';
import '../../../domain/media/video_cache_manager.dart';
import '../../../domain/pipeline/subtitling_pipeline.dart';
import '../../../domain/tts/audio_file_validator.dart';
import '../../../domain/tts/tts_cache_helper.dart';
import '../../../domain/tts/tts_generation_manager.dart';
import '../../../player/app_player_controller.dart';
import '../../../player/global_player_manager.dart';
import '../../../player/tts_audio_scheduler.dart';
import '../../player/dual_volume_sheet.dart';
import '../../player/subtitle_control_sheet.dart';
import '../../player/subtitle_overlay.dart';
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

/// Màn hình lướt video ngắn Hồng Quả dạng Shorts / TikTok Feed
/// Thiết kế chuẩn 90% giao diện gốc ByteDance / Douyin Short Drama:
/// - Hai chế độ liền mạch: Lướt khám phá (Discover Feed) và Xem trọn bộ (Drama Episode Mode)
/// - Bottom Sheet chọn tập chuẩn ByteDance với phân trang dải tập (1-30, 31-60...), lưới 6 cột và icon sóng nhạc 'ıll'
/// - Thanh tua Scrubber cảm ứng mượt mà với bong bóng thời gian thực
/// - Bộ điều tốc độ phát (1.0x, 1.25x, 1.5x, 2.0x) và nút xoay toàn màn hình
/// - Thao tác vuốt dọc mượt mà, chạm dừng/phát, nhấp đúp thả tim
class HongguoFeedScreen extends StatefulWidget {
  final HongguoDramaDetail? initialDrama;
  final int initialEpisodeIndex;
  final List<HongguoDramaItem>? discoverDramas;

  const HongguoFeedScreen({
    super.key,
    this.initialDrama,
    this.initialEpisodeIndex = 1,
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

  // Single Player Controller duy nhất cho hiệu năng tối đa
  AppPlayerController? _activeController;
  int? _activePageIndex;
  int _dramaEpisodeSessionKey = 0;

  // Cache URL đã phân giải
  final Map<int, String> _preloadedStreamUrls = {};
  final Set<int> _preloadingIndices = {};

  // Watchdog giám sát chống đứng hình 1s
  Timer? _stallWatchdog;
  Duration _lastObservedPos = Duration.zero;
  int _stallTickCount = 0;

  bool _isLoadingVideo = false;
  String? _errorMessage;
  bool _isManuallyPaused = false;
  bool _showPlayPauseAnim = false;

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

  // Quản lý mở rộng mô tả phim
  bool _isDescriptionExpanded = false;

  // Subscriptions của Player
  StreamSubscription<Duration>? _posSub;
  Duration _currentPos = Duration.zero;
  Duration _currentDur = Duration.zero;

  // Cấu hình ứng dụng và phụ đề
  SettingsRepository? _settings;

  // Quản lý Phụ đề & Lồng tiếng trực tiếp trên Feed (Key là duy nhất: {seriesId}_ep{episodeIndex})
  final Map<String, SubtitleDocument> _episodeDocuments = {};

  /// Định danh duy nhất cho tài liệu phụ đề của từng video
  String _getVideoDocKey(FeedDramaPageItem item) {
    return '${item.detail.seriesId}_ep${item.episodeIndex}';
  }
  bool _showSubtitles = true;
  bool _isTtsActive = false;
  TtsAudioScheduler? _ttsScheduler;

  // Trạng thái dịch trực tiếp của tập hiện tại
  bool _isTranslatingCurrent = false;
  bool _translatingWithTts = false;
  double _translationProgress = 0.0;
  String _translationStatus = '';

  @override
  void initState() {
    super.initState();
    _initFeedData();
    _pageController = PageController(initialPage: _currentIndex);
    _activeController = AppPlayerController(bufferSizeMb: 32);

    _listenToPlayerStreams();
    _startStallWatchdog();

    SettingsRepository.getInstance().then((s) {
      if (!mounted) return;
      setState(() {
        _settings = s;
        if (_settings!.subtitleOffsetY == 0.0) {
          _settings!.subtitleOffsetY = 90.0;
        }
      });
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await HongguoStreamProxyServer.instance.ensureStarted();
      if (!mounted) return;
      await _activatePage(_currentIndex);
    });
  }

  void _initFeedData() {
    if (widget.initialDrama != null) {
      _isDramaEpisodeMode = true;
      _currentDramaDetail = widget.initialDrama;
      _populateDramaEpisodes(_currentDramaDetail!, initialEpisode: widget.initialEpisodeIndex);
    } else if (widget.discoverDramas != null && widget.discoverDramas!.isNotEmpty) {
      _isDramaEpisodeMode = false;
      for (final drama in widget.discoverDramas!) {
        final detail = _dramaItemToDetail(drama);
        _feedItems.add(
          FeedDramaPageItem(
            detail: detail,
            episodeIndex: 1,
            vid: drama.vidList.isNotEmpty ? drama.vidList.first : '',
          ),
        );
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

  void _populateDramaEpisodes(HongguoDramaDetail detail, {int initialEpisode = 1}) {
    _feedItems.clear();
    _preloadedStreamUrls.clear();
    _preloadingIndices.clear();

    final episodes = detail.episodes;
    final total = episodes.isNotEmpty
        ? episodes.length
        : (detail.totalEpisodes > 0 ? detail.totalEpisodes : 1);

    for (var i = 1; i <= total; i++) {
      final vid = (episodes.isNotEmpty && i <= episodes.length)
          ? episodes[i - 1].vid
          : '';
      _feedItems.add(
        FeedDramaPageItem(
          detail: detail,
          episodeIndex: i,
          vid: vid,
        ),
      );
    }

    _currentIndex = (initialEpisode - 1).clamp(0, math.max(0, _feedItems.length - 1));
  }

  void _listenToPlayerStreams() {
    _posSub?.cancel();
    _posSub = _activeController?.player.stream.position.listen((pos) {
      if (!mounted) return;
      final dur = _activeController?.player.state.duration ?? Duration.zero;
      if (!_isScrubbing) {
        setState(() {
          _currentPos = pos;
          _currentDur = dur;
        });

        if (_isTtsActive && _ttsScheduler != null && _activeController != null) {
          _ttsScheduler!.onVideoStateUpdate(
            positionMs: pos.inMilliseconds,
            isPlaying: _activeController!.value.isPlaying && !_isManuallyPaused,
            isBuffering: false,
            isScrubbing: _isScrubbing,
            playbackSpeed: _playbackSpeed,
          );
        }
      }
    });
  }

  @override
  void dispose() {
    _stallWatchdog?.cancel();
    _posSub?.cancel();
    _pageController.dispose();
    _ttsScheduler?.dispose();
    _ttsScheduler = null;
    _activeController?.dispose();
    _activeController = null;
    _preloadedStreamUrls.clear();
    _preloadingIndices.clear();
    HongguoStreamProxyServer.instance.maintainSessions([]);
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
      if (!mounted || _activeController == null || _isManuallyPaused || _isLoadingVideo) return;
      final player = _activeController!.player;
      final isPlaying = _activeController!.value.isPlaying;
      final currentPos = player.state.position;

      if (isPlaying && currentPos > Duration.zero && currentPos == _lastObservedPos) {
        _stallTickCount++;
        if (_stallTickCount >= 2) {
          debugPrint('[HongguoFeedScreen] ⚡ Phục hồi phát video tại $currentPos');
          player.play();
          _stallTickCount = 0;
        }
      } else {
        _stallTickCount = 0;
        _lastObservedPos = currentPos;
      }
    });
  }

  /// Kích hoạt và phát video cho trang được chọn
  Future<void> _activatePage(int index) async {
    if (!mounted || index < 0 || index >= _feedItems.length) return;

    if (_activePageIndex == index &&
        _activeController != null &&
        _activeController!.value.isPlaying) {
      return;
    }

    _activePageIndex = index;
    setState(() {
      _isLoadingVideo = true;
      _errorMessage = null;
      _isManuallyPaused = false;
      _isDescriptionExpanded = false;
    });

    var item = _feedItems[index];

    try {
      // 1. Đảm bảo item có đầy đủ danh sách tập và vid thật của ByteDance trước khi nạp
      if (item.vid.isEmpty || item.vid == item.detail.seriesId || item.detail.episodes.isEmpty) {
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
            if (index < _feedItems.length && _feedItems[index].detail.seriesId == fullDetail.seriesId) {
              _feedItems[index] = item;
            }
            if (mounted && _activePageIndex == index) {
              setState(() {});
            }
          }
        } catch (e) {
          debugPrint('[HongguoFeedScreen] Phân giải chi tiết phim thất bại: $e');
        }
      }

      if (!mounted || _activePageIndex != index) return;

      // 2. Lấy URL stream (ưu tiên từ URL đã nạp sẵn trong RAM)
      String streamUrl = _preloadedStreamUrls[index] ?? '';
      if (streamUrl.isEmpty) {
        streamUrl = await _resolveEpisodeStreamUrl(item);
        _preloadedStreamUrls[index] = streamUrl;
      }

      if (!mounted || _activePageIndex != index) return;

      if (_activeController == null || _activeController!.isDisposed) {
        _activeController = AppPlayerController(bufferSizeMb: 32);
        _listenToPlayerStreams();
      }

      // 3. Chuyển đổi media trên controller duy nhất
      if (streamUrl.startsWith('http://') || streamUrl.startsWith('https://')) {
        await _activeController!.switchMedia(
          networkUrl: streamUrl,
          headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0',
          },
          play: true,
        );
      } else {
        await _activeController!.switchMedia(
          file: File(streamUrl),
          play: true,
        );
      }

      await _activeController!.player.setPlaylistMode(PlaylistMode.loop);
      await _activeController!.player.setRate(_playbackSpeed);
      await _activeController!.player.play();

      // Kiểm tra tập hiện tại đã có phụ đề trong RAM hoặc Lịch sử chưa
      _checkHistoryForEpisode(index);

      if (mounted && _activePageIndex == index) {
        setState(() {
          _isLoadingVideo = false;
        });
      }

      // 4. Nạp trước tập tiếp theo (N+1) trong nền
      _preloadNextPage(index + 1);
      _maintainProxyMemory(index);
    } catch (e) {
      debugPrint('[HongguoFeedScreen] Lỗi kích hoạt tập $index: $e');
      if (mounted && _activePageIndex == index) {
        setState(() {
          _isLoadingVideo = false;
          _errorMessage = 'Lỗi phát video: $e';
        });
      }
    }
  }

  /// Phân giải nguồn phát tối ưu nhất cho tập phim:
  /// ƯU TIÊN SỐ 1 TUYỆT ĐỐI: Local Streaming Proxy (Chất lượng gốc 720p/1080p từ ByteDance CDN, giải mã in-place 0ms).
  /// Tuyệt đối KHÔNG ưu tiên link web công khai 360p vì vừa mờ, vừa chậm vừa giật.
  Future<String> _resolveEpisodeStreamUrl(FeedDramaPageItem item) async {
    // 0. Đảm bảo item có vid thật trước khi gọi proxy
    if (item.vid.isEmpty || item.vid == item.detail.seriesId || item.detail.episodes.isEmpty) {
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
          final idx = _feedItems.indexWhere((it) => it.detail.seriesId == fullDetail.seriesId && it.episodeIndex == epIdx);
          if (idx != -1) {
            _feedItems[idx] = item;
          }
        }
      } catch (e) {
        debugPrint('[HongguoFeedScreen] _resolveEpisodeStreamUrl getDramaDetail failed: $e');
      }
    }

    // 1. Kiểm tra cache hoàn chỉnh trên máy
    try {
      final cached = await VideoCacheManager.findCachedFile(
        url: '',
        seriesId: item.detail.seriesId,
        episodeIndex: item.episodeIndex,
      );
      if (cached != null && cached.existsSync() && cached.lengthSync() > 1024 * 50) {
        return cached.path;
      }
    } catch (_) {}

    // 2. ƯU TIÊN SỐ 1: Chạy trực tiếp qua Local Streaming Proxy (720p/1080p gốc, phát 0ms)
    try {
      await HongguoStreamProxyServer.instance.ensureStarted();
      return HongguoStreamProxyServer.instance.getStreamUrl(
        vid: item.vid,
        seriesId: item.detail.seriesId,
        episodeIndex: item.episodeIndex,
      );
    } catch (e) {
      debugPrint('[HongguoFeedScreen] Khởi tạo proxy lỗi: $e -> Chuyển sang fallback web');
    }

    // 3. DỰ PHÒNG HY HỮU (Fallback): Chỉ khi proxy gặp lỗi mới thử lấy link web công khai
    if (item.episodeIndex == 1) {
      try {
        final publicUrl = await _resolver.getPublicWebPlayUrl(
          item.detail.seriesId,
          item.vid,
          episodeIndex: item.episodeIndex,
        );
        if (publicUrl != null && publicUrl.isNotEmpty) {
          return publicUrl;
        }
      } catch (_) {}
    }

    // Mặc định luôn trả về URL Streaming Proxy
    await HongguoStreamProxyServer.instance.ensureStarted();
    return HongguoStreamProxyServer.instance.getStreamUrl(
      vid: item.vid,
      seriesId: item.detail.seriesId,
      episodeIndex: item.episodeIndex,
    );
  }

  /// Nạp trước dữ liệu và chunk 0 cho tập kế tiếp
  Future<void> _preloadNextPage(int nextIndex) async {
    if (!mounted || nextIndex < 0 || nextIndex >= _feedItems.length) return;
    if (_preloadedStreamUrls.containsKey(nextIndex) || _preloadingIndices.contains(nextIndex)) {
      return;
    }

    _preloadingIndices.add(nextIndex);
    var nextItem = _feedItems[nextIndex];

    try {
      if (nextItem.vid.isEmpty || nextItem.vid == nextItem.detail.seriesId || nextItem.detail.episodes.isEmpty) {
        try {
          final fullDetail = await _resolver.getDramaDetail(nextItem.detail.seriesId);
          if (fullDetail.episodes.isNotEmpty) {
            final epIdx = nextItem.episodeIndex.clamp(1, fullDetail.episodes.length);
            nextItem = FeedDramaPageItem(
              detail: fullDetail,
              episodeIndex: epIdx,
              vid: fullDetail.episodes[epIdx - 1].vid,
            );
            if (nextIndex < _feedItems.length && _feedItems[nextIndex].detail.seriesId == fullDetail.seriesId) {
              _feedItems[nextIndex] = nextItem;
            }
          }
        } catch (_) {}
      }

      final streamUrl = await _resolveEpisodeStreamUrl(nextItem);
      if (!mounted) return;
      _preloadedStreamUrls[nextIndex] = streamUrl;

      if (streamUrl.contains('127.0.0.1') && nextItem.vid.isNotEmpty && nextItem.vid != nextItem.detail.seriesId) {
        await HongguoStreamProxyServer.instance.preloadStream(
          vid: nextItem.vid,
          seriesId: nextItem.detail.seriesId,
          episodeIndex: nextItem.episodeIndex,
        );
      }
    } catch (_) {
    } finally {
      _preloadingIndices.remove(nextIndex);
    }
  }

  void _maintainProxyMemory(int currentIndex) {
    if (currentIndex < 0 || currentIndex >= _feedItems.length) return;
    final activeVids = <String>[
      _feedItems[currentIndex].vid,
      if (currentIndex > 0) _feedItems[currentIndex - 1].vid,
      if (currentIndex + 1 < _feedItems.length) _feedItems[currentIndex + 1].vid,
    ];
    HongguoStreamProxyServer.instance.maintainSessions(activeVids);
  }

  void _onPageChanged(int index) {
    HapticFeedback.selectionClick();
    _currentIndex = index;

    // Dừng ngay lập tức âm thanh lồng tiếng của tập cũ và reset volume video gốc về 100%
    _ttsScheduler?.stop();
    _ttsScheduler?.setDocument(null);
    _activeController?.setVolume(1.0);

    _activatePage(index);

    // Tự động nạp thêm khi ở chế độ khám phá
    if (!_isDramaEpisodeMode && index >= _feedItems.length - 3 && !_isLoadingMore) {
      _loadMoreDiscoverDramas();
    }
  }

  Future<void> _loadMoreDiscoverDramas() async {
    _isLoadingMore = true;
    try {
      final res = await _resolver.getRandomRecommendations();
      if (!mounted) return;
      final newItems = <FeedDramaPageItem>[];
      for (final drama in res.items) {
        final detail = _dramaItemToDetail(drama);
        newItems.add(
          FeedDramaPageItem(
            detail: detail,
            episodeIndex: 1,
            vid: drama.vidList.isNotEmpty ? drama.vidList.first : '',
          ),
        );
      }
      setState(() {
        _feedItems.addAll(newItems);
        _isLoadingMore = false;
      });
    } catch (_) {
      _isLoadingMore = false;
    }
  }

  void _togglePlayPause() {
    HapticFeedback.lightImpact();
    if (_activeController == null) return;
    if (_activeController!.value.isPlaying) {
      _activeController!.player.pause();
      _ttsScheduler?.pause();
      setState(() {
        _isManuallyPaused = true;
        _showPlayPauseAnim = true;
      });
    } else {
      _activeController!.player.play();
      _ttsScheduler?.resume();
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
    Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _showHeartAnim = false);
    });
  }

  /// Chuyển đổi tốc độ phát video
  void _cyclePlaybackSpeed() {
    HapticFeedback.lightImpact();
    final speeds = [1.0, 1.25, 1.5, 2.0, 0.75];
    final currentIdx = speeds.indexOf(_playbackSpeed);
    final nextSpeed = speeds[(currentIdx + 1) % speeds.length];
    setState(() {
      _playbackSpeed = nextSpeed;
    });
    _activeController?.player.setRate(nextSpeed);
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

  /// Mở màn hình dịch chính thức có phụ đề & lồng tiếng AI
  void _openTranslationPlayer(FeedDramaPageItem item) {
    HapticFeedback.mediumImpact();
    _activeController?.player.pause();

    final dramaTitle = OfflineMlKitTranslator.getCachedTitle(item.detail.title) ?? item.detail.title;

    GlobalPlayerManager.instance.openPlayer(
      videoPath: item.vid,
      title: '$dramaTitle - Tập ${item.episodeIndex}',
      document: SubtitleDocument(),
      dramaDetail: item.detail,
      currentEpisodeIndex: item.episodeIndex,
      initialTtsEnabled: true,
    );
  }

  /// Chuyển từ chế độ Khám phá sang Chế độ Xem trọn bộ của phim được chọn
  Future<void> _switchToDramaEpisodeMode(HongguoDramaDetail detail, {int targetEpisode = 1}) async {
    HapticFeedback.mediumImpact();

    // Lưu lại danh sách khám phá nếu chưa lưu
    if (!_isDramaEpisodeMode) {
      _savedDiscoverItems = List.from(_feedItems);
      _savedDiscoverIndex = _currentIndex;
    }

    // Nếu detail chưa có danh sách tập đầy đủ, nạp chi tiết từ resolver
    HongguoDramaDetail fullDetail = detail;
    if (detail.episodes.isEmpty || (detail.episodes.length <= 1 && detail.totalEpisodes > 1)) {
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

    _pageController.dispose();
    _pageController = PageController(initialPage: targetIdx);
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
      setState(() {
        _isDramaEpisodeMode = false;
        _currentDramaDetail = null;
        _feedItems.clear();
        _feedItems.addAll(_savedDiscoverItems);
        _currentIndex = _savedDiscoverIndex.clamp(0, _feedItems.length - 1);
        _dramaEpisodeSessionKey++;
      });
      _pageController.dispose();
      _pageController = PageController(initialPage: _currentIndex);
      _activePageIndex = -1;
      _activatePage(_currentIndex);
    } else {
      Navigator.pop(context);
    }
  }

  /// Mở Bottom Sheet chọn tập chuẩn ByteDance (Frame 15 Style)
  void _showEpisodePickerSheet(HongguoDramaDetail detail) {
    HapticFeedback.lightImpact();
    final currentEpisodeNum = (_currentIndex >= 0 && _currentIndex < _feedItems.length)
        ? _feedItems[_currentIndex].episodeIndex
        : 1;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _ByteDanceEpisodePickerSheet(
        detail: detail,
        currentEpisode: currentEpisodeNum,
        onSelectEpisode: (epIndex, fullDetail) async {
          Navigator.pop(ctx);
          if (_isDramaEpisodeMode) {
            final targetPage = (epIndex - 1).clamp(0, _feedItems.length - 1);
            if (targetPage != _currentIndex) {
              _currentIndex = targetPage;
              _pageController.jumpToPage(targetPage);
              await _activatePage(targetPage);
            }
          } else {
            // Đang ở Discover Feed -> chuyển sang Drama Episode Mode của phim này với toàn bộ tập
            await _switchToDramaEpisodeMode(fullDetail, targetEpisode: epIndex);
          }
        },
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
              key: ValueKey('hongguo_page_view_${_isDramaEpisodeMode ? _currentDramaDetail?.seriesId : "discover"}_$_dramaEpisodeSessionKey'),
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
                  builder: (_, scale, child) => Transform.scale(
                    scale: scale,
                    child: child,
                  ),
                  child: const Icon(
                    Icons.favorite_rounded,
                    color: Color(0xFFFF2B54),
                    size: 90,
                    shadows: [
                      Shadow(color: Colors.black54, blurRadius: 16),
                    ],
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
                    _isManuallyPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
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
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFFFF6A00), width: 0.8),
                      boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10)],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(Color(0xFFFF6A00)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _translationStatus,
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${(_translationProgress * 100).toInt()}%',
                          style: const TextStyle(color: Color(0xFFFF6A00), fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // 6. Thanh tua tiến trình dạng Scrubber (Hongguo Style)
            if (!_isCleanMode)
              Positioned(
                left: 0,
                right: 0,
                bottom: MediaQuery.of(context).padding.bottom + 4,
                child: _buildProgressScrubber(),
              ),
          ],
        ),
      ),
    );
  }

  /// Giao diện cho từng trang video trong PageView
  Widget _buildFeedPageItem(FeedDramaPageItem item, bool isCurrent) {
    final videoAspect = (_activeController != null && _activeController!.value.aspectRatio > 0)
        ? _activeController!.value.aspectRatio
        : (9 / 16);
    final isLandscapeVideo = videoAspect > 1.05;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Nền đen tuyền tiêu chuẩn TikTok / Shorts ByteDance (không chèn ảnh bìa làm rối nền)
        Container(color: Colors.black),

        // Video Player
        if (isCurrent && _activeController != null && _errorMessage == null)
          Center(
            child: AspectRatio(
              aspectRatio: videoAspect,
              child: Video(
                key: ValueKey('feed_active_player_${_activeController.hashCode}'),
                controller: _activeController!.videoController,
                controls: NoVideoControls,
              ),
            ),
          ),



        // Vòng xoay nạp video (chỉ hiện khi độ trễ mạng quá 500ms)
        if (isCurrent && _isLoadingVideo)
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
                  const Icon(Icons.wifi_off_rounded, color: Colors.orangeAccent, size: 40),
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
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
            onDoubleTapDown: (details) => _onDoubleTapAt(details.globalPosition),
          ),
        ),

        // Nút xoay xem toàn màn hình cho video ngang (Nằm trên Positioned.fill để nhận tap nhạy bén)
        if (isCurrent && isLandscapeVideo && !_isLandscapeFullscreen && !_isCleanMode)
          Positioned(
            left: 0,
            right: 0,
            top: MediaQuery.of(context).size.height * 0.5 + 130,
            child: Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleLandscapeFullscreen,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
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
                      Icon(Icons.fullscreen_rounded, color: Colors.white, size: 16),
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
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white24, width: 0.8),
                  boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 6)],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.visibility_rounded, color: Colors.white, size: 14),
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
        if (isCurrent && _showSubtitles && _settings != null && _episodeDocuments.containsKey(_getVideoDocKey(item)))
          SubtitleOverlay(
            document: _episodeDocuments[_getVideoDocKey(item)]!,
            currentPositionMs: _currentPos.inMilliseconds,
            settings: _settings!,
            onDragOffset: (newOffset) {
              setState(() {
                _settings!.subtitleOffsetY = newOffset.clamp(-80.0, 350.0);
              });
            },
          ),

        // Lớp Overlay thông tin phim và tác vụ (TikTok / Shorts Layout)
        _buildOverlayUI(item),
      ],
    );
  }

  /// Top Bar chuẩn giao diện ByteDance
  Widget _buildTopBar() {
    if (_isCleanMode) {
      return const SizedBox.shrink();
    }

    final topPadding = MediaQuery.of(context).padding.top;

    // Top Bar khi xoay ngang toàn màn hình (Landscape Fullscreen Mode)
    if (_isLandscapeFullscreen) {
      final currentEpNum = (_currentIndex >= 0 && _currentIndex < _feedItems.length)
          ? _feedItems[_currentIndex].episodeIndex
          : 1;
      final currentItem = (_currentIndex >= 0 && _currentIndex < _feedItems.length)
          ? _feedItems[_currentIndex]
          : null;
      final dramaTitle = currentItem != null
          ? (OfflineMlKitTranslator.getCachedTitle(currentItem.detail.title) ?? currentItem.detail.title)
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
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white24, width: 0.8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.fullscreen_exit_rounded, color: Colors.white, size: 18),
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
              onTap: _cyclePlaybackSpeed,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white24, width: 0.8),
                ),
                child: Text(
                  '${_playbackSpeed}x',
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
      final currentEpNum = (_currentIndex >= 0 && _currentIndex < _feedItems.length)
          ? _feedItems[_currentIndex].episodeIndex
          : 1;

      return Positioned(
        top: topPadding + 6,
        left: 12,
        right: 12,
        child: Row(
          children: [
            // Nút Back + Tiêu đề tập: `< 第N集`
            GestureDetector(
              onTap: _handleBackNavigation,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      'Tập $currentEpNum',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const Spacer(),

            // Nút Tốc độ phát: `⏱ 1.0x`
            GestureDetector(
              onTap: _cyclePlaybackSpeed,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white24, width: 0.6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.speed_rounded, color: Colors.white, size: 15),
                    const SizedBox(width: 4),
                    Text(
                      '${_playbackSpeed}x',
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

            // Nút More Options: `⋮`
            PopupMenuButton<String>(
              icon: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white24, width: 0.6),
                ),
                child: const Icon(Icons.more_vert_rounded, color: Colors.white, size: 18),
              ),
              color: const Color(0xFF22242A),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              onSelected: (val) {
                if (val == 'translate') {
                  if (_currentIndex >= 0 && _currentIndex < _feedItems.length) {
                    _openTranslationPlayer(_feedItems[_currentIndex]);
                  }
                } else if (val == 'speed') {
                  _cyclePlaybackSpeed();
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(
                  value: 'translate',
                  child: Row(
                    children: [
                      Icon(Icons.translate_rounded, color: AppColors.primaryEmerald, size: 18),
                      SizedBox(width: 10),
                      Text('Dịch & Lồng tiếng AI', style: TextStyle(color: Colors.white, fontSize: 13)),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'speed',
                  child: Row(
                    children: [
                      const Icon(Icons.speed_rounded, color: Colors.white70, size: 18),
                      const SizedBox(width: 10),
                      Text('Đổi tốc độ: ${_playbackSpeed}x', style: const TextStyle(color: Colors.white, fontSize: 13)),
                    ],
                  ),
                ),
              ],
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
              child: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 18),
            ),
          ),

          const Spacer(),

          // Thanh Tab trung tâm: `Theo dõi` | `Khám phá` | `Đề xuất`
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Thịnh hành',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.65),
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 20),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Đề xuất',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Container(
                    width: 22,
                    height: 2.5,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ],
              ),
            ],
          ),

          const Spacer(),

          // Icon Search 🔍
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.35),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.search_rounded, color: Colors.white, size: 20),
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

    final title = OfflineMlKitTranslator.getCachedTitle(item.detail.title) ?? item.detail.title;
    final total = item.detail.episodes.isNotEmpty
        ? item.detail.episodes.length
        : (item.detail.totalEpisodes > 0 ? item.detail.totalEpisodes : 1);

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
                    // Tiêu đề phim có dấu mũi tên `>` (nhấn vào mở xem trọn bộ)
                    GestureDetector(
                      onTap: () => _showEpisodePickerSheet(item.detail),
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
                                shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white70, size: 13),
                        ],
                      ),
                    ),

                    const SizedBox(height: 6),

                    // Hàng thẻ Tags (Frame 3 Style: `Cổ trang`, `Tình cảm`...)
                    if (item.detail.tags.isNotEmpty)
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: item.detail.tags.take(4).map((tag) {
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              tag,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          );
                        }).toList(),
                      ),

                    const SizedBox(height: 6),

                    // Tóm tắt tập và mô tả có nút `Xem thêm` / `Thu gọn` (Frame 3 Style)
                    GestureDetector(
                      onTap: () => setState(() => _isDescriptionExpanded = !_isDescriptionExpanded),
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
                              text: item.detail.intro.isNotEmpty
                                  ? item.detail.intro
                                  : 'Diễn biến gay cấn trọn bộ...',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                            TextSpan(
                              text: _isDescriptionExpanded ? '  Thu gọn' : '...  Xem thêm',
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
                          shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
                        ),
                      ),
                    ),

                    const SizedBox(height: 6),

                    // Dòng bản quyền tác giả: `ⓘ Tác giả: Nội dung tạo bởi AI`
                    const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.info_outline_rounded, color: Colors.white38, size: 11),
                        SizedBox(width: 4),
                        Text(
                          'Tuyên bố: Nội dung hỗ trợ dịch bởi AI',
                          style: TextStyle(
                            color: Colors.white38,
                            fontSize: 10,
                          ),
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

                  // 3. Nút Tải Xem Offline (Luồng Player cũ đầy đủ)
                  _buildRightActionButton(
                    icon: Icons.download_for_offline_rounded,
                    iconColor: Colors.white,
                    label: 'Tải Offline',
                    onTap: () => _openTranslationPlayer(item),
                  ),

                  const SizedBox(height: 14),

                  // 4. Nút Lưu xem sau / Yêu thích
                  ValueListenableBuilder<List<WatchLaterItem>>(
                    valueListenable: WatchLaterRepository.watchLaterNotifier,
                    builder: (context, wlList, _) {
                      final isSaved = wlList.any((w) => w.seriesId == item.detail.seriesId);
                      return _buildRightActionButton(
                        icon: isSaved ? Icons.star_rounded : Icons.star_outline_rounded,
                        iconColor: isSaved ? const Color(0xFFFFB800) : Colors.white,
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
                                targetUrl: 'https://hongguoduanju.com/player/${item.detail.seriesId}',
                                seriesId: item.detail.seriesId,
                                totalEpisodes: item.detail.totalEpisodes,
                                addedAt: DateTime.now().millisecondsSinceEpoch,
                              ),
                            );
                          }
                        },
                      );
                    },
                  ),

                  const SizedBox(height: 14),

                  // 5. Nút Chia sẻ
                  _buildRightActionButton(
                    icon: Icons.share_rounded,
                    iconColor: Colors.white,
                    label: 'Chia sẻ',
                    onTap: () {
                      HapticFeedback.lightImpact();
                      Clipboard.setData(ClipboardData(
                        text: 'https://hongguoduanju.com/player/${item.detail.seriesId}',
                      ));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Đã sao chép liên kết phim!'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
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
                              Icon(Icons.touch_app_rounded, color: Colors.white, size: 16),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text('Đã ẩn giao diện. Chạm vào màn hình để hiện lại.'),
                              ),
                            ],
                          ),
                          backgroundColor: Colors.black87,
                          behavior: SnackBarBehavior.floating,
                          duration: const Duration(seconds: 2),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
            setState(() {
              _isScrubbing = true;
              _scrubValue = (details.localPosition.dx / totalWidth).clamp(0.0, 1.0);
            });
          },
          onHorizontalDragUpdate: (details) {
            setState(() {
              _scrubValue = (details.localPosition.dx / totalWidth).clamp(0.0, 1.0);
            });
          },
          onHorizontalDragEnd: (details) {
            if (_activeController != null && durMs > 0) {
              final targetPos = Duration(milliseconds: (_scrubValue * durMs).toInt());
              _activeController!.player.seek(targetPos);
              _ttsScheduler?.onSeek(targetPos.inMilliseconds);
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
                  left: (totalWidth * displayProgress - 4.5).clamp(0.0, totalWidth - 9),
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
                    : (isCurrentTranslating ? const Color(0xFFFF6A00) : Colors.white24),
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
    final hasTts = doc != null && doc.items.any((i) => i.audioFilePath != null && i.audioFilePath!.isNotEmpty);
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
                    : (isCurrentTranslating ? const Color(0xFFFF6A00) : Colors.white24),
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
                    color: isDubbingActive ? AppColors.primaryEmerald : Colors.white,
                    size: 24,
                  ),
          ),
          const SizedBox(height: 4),
          Text(
            isDubbingActive ? 'Lồng tiếng' : (hasTts ? 'Tắt tiếng' : 'Lồng tiếng'),
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

  /// Tự động nạp phụ đề từ Lịch sử nếu tập này đã từng được dịch trước đó
  Future<void> _checkHistoryForEpisode(int index) async {
    if (index < 0 || index >= _feedItems.length) return;
    final item = _feedItems[index];
    final epIdx = item.episodeIndex;
    final seriesId = item.detail.seriesId;
    final docKey = _getVideoDocKey(item);

    if (_episodeDocuments.containsKey(docKey)) {
      final doc = _episodeDocuments[docKey]!;
      final hasTts = doc.items.any((i) => i.audioFilePath != null && i.audioFilePath!.isNotEmpty);
      if (_currentIndex == index) {
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
          final voiceType = _settings?.hongguoSelectedTtsVoice ?? VoicePresets.defaultVoice.voiceType;
          await TtsCacheHelper.linkAudioFiles(doc, voiceType);
          await _calibratePlaybackSpeeds(doc);

          if (_currentIndex == index) {
            final hasTts = doc.items.any((i) => i.audioFilePath != null && i.audioFilePath!.isNotEmpty);
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
        }
      } else {
        // Tập này chưa hề dịch -> Đảm bảo tắt hẳn TTS và volume 100%
        if (_currentIndex == index) {
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
    await _activeController?.setVolume(1.0);
    if (mounted) setState(() {});
  }

  /// Chuyển đổi trạng thái Lồng tiếng AI
  Future<void> _toggleTts() async {
    if (_currentIndex < 0 || _currentIndex >= _feedItems.length) return;
    final currentItem = _feedItems[_currentIndex];
    final docKey = _getVideoDocKey(currentItem);
    final doc = _episodeDocuments[docKey];
    final hasTts = doc != null && doc.items.any((i) => i.audioFilePath != null && i.audioFilePath!.isNotEmpty);

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
  Future<void> _ensureTtsAndPlay(SubtitleDocument doc, FeedDramaPageItem item) async {
    final settings = _settings ?? await SettingsRepository.getInstance();
    final voiceType = settings.hongguoSelectedTtsVoice;
    final voice = VoicePresets.vietnameseVoices.firstWhere(
      (v) => v.voiceType == voiceType,
      orElse: () => VoicePresets.defaultVoice,
    );

    await TtsCacheHelper.linkAudioFiles(doc, voice.voiceType);
    final unlinked = doc.items.where(
      (i) => (i.audioFilePath == null || i.audioFilePath!.isEmpty) &&
             TtsGenerationManager.isPronounceable(i.translatedText),
    ).toList();

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
    if (_currentIndex >= 0 && _currentIndex < _feedItems.length && _getVideoDocKey(_feedItems[_currentIndex]) == docKey) {
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
          final voiceType = _settings?.hongguoSelectedTtsVoice ?? VoicePresets.defaultVoice.voiceType;
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
      final videoInfo = await HongguoLocalEngine.resolveVideoInfo(item.vid, preferLowest: true);
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
      tempMp4 = File('${tempDir.path}/feed_360p_${seriesId}_${epIdx}_$timestamp.mp4');
      tempAudio = File('${tempDir.path}/feed_audio_${seriesId}_${epIdx}_$timestamp.m4a');

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
            _translationStatus = 'Đang tải 1.28MB: ${(p * 100).toInt()}%';
          });
        },
      );

      if (!tempMp4.existsSync() || tempMp4.lengthSync() < 1024) {
        throw StateError('Tải tệp video tạm không thành công');
      }

      // Nếu video bị mã hóa DRM CENC, giải mã tại chỗ siêu nhanh (1.28MB chỉ mất ~4ms)
      if (videoInfo.isDrmProtected) {
        final encryptedBytes = await tempMp4.readAsBytes();
        final keyBytes = Uint8List.fromList(hex.decode(videoInfo.contentKeyHex));
        final decryptedBytes = HongguoCencDecryptor.decryptMp4Cenc(
          encryptedBytes,
          keyBytes,
        );
        await tempMp4.writeAsBytes(decryptedBytes, flush: true);
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

      final audioPath = (tempAudio.existsSync() && tempAudio.lengthSync() > 1024)
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
          _translationProgress = (0.32 + prog.progress * 0.50).clamp(0.32, 0.82);
          _translationStatus = prog.message.isNotEmpty ? prog.message : 'Đang xử lý phụ đề...';
        });
      });

      final doc = await pipeline.execute(
        videoPath: audioPath,
        totalDurationMs: _currentDur.inMilliseconds > 0 ? _currentDur.inMilliseconds : 120000,
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
        final unlinked = doc.items.where(
          (i) => (i.audioFilePath == null || i.audioFilePath!.isEmpty) &&
                 TtsGenerationManager.isPronounceable(i.translatedText),
        ).toList();

        if (unlinked.isNotEmpty) {
          if (mounted) {
            setState(() {
              _translationProgress = 0.85;
              _translationStatus = 'Đang lồng tiếng AI (${voice.displayName})...';
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
          videoPath: _preloadedStreamUrls[_currentIndex] ?? item.vid,
          title: '${item.detail.title} - Tập $epIdx',
          document: doc,
          durationMs: _currentDur.inMilliseconds > 0 ? _currentDur.inMilliseconds : 120000,
          ttsVoice: appliedVoice,
          seriesId: seriesId,
          seriesCover: item.detail.cover,
          episodeIndex: epIdx,
          totalEpisodes: item.detail.totalEpisodes > 0 ? item.detail.totalEpisodes : item.detail.episodes.length,
          isOnlineStream: true, // Tag rõ ràng là lướt online!
        );
      } catch (e) {
        debugPrint('[HongguoFeed] Lỗi lưu lịch sử: $e');
      }

      if (!mounted) return;

      // Chỉ kích hoạt phát nếu người dùng VẪN ĐANG Ở ĐÚNG TẬP NÀY
      if (_currentIndex >= 0 && _currentIndex < _feedItems.length && _getVideoDocKey(_feedItems[_currentIndex]) == docKey) {
        if (enableTts) {
          await _startTtsPlayback(doc);
          _showSubtitles = true;
        } else {
          _showSubtitles = true;
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(enableTts ? 'Đã tạo lồng tiếng & Vietsub tập $epIdx!' : 'Đã tạo Vietsub tập $epIdx!'),
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
        if (tempAudio != null && tempAudio.existsSync()) await tempAudio.delete();
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
typedef OnEpisodeSelectedCallback = void Function(int episodeIndex, HongguoDramaDetail fullDetail);

/// Bottom Sheet chọn tập chuẩn ByteDance (Frame 15 Style)
class _ByteDanceEpisodePickerSheet extends StatefulWidget {
  final HongguoDramaDetail detail;
  final int currentEpisode;
  final OnEpisodeSelectedCallback onSelectEpisode;

  const _ByteDanceEpisodePickerSheet({
    required this.detail,
    required this.currentEpisode,
    required this.onSelectEpisode,
  });

  @override
  State<_ByteDanceEpisodePickerSheet> createState() => _ByteDanceEpisodePickerSheetState();
}

class _ByteDanceEpisodePickerSheetState extends State<_ByteDanceEpisodePickerSheet> {
  int _selectedTabIndex = 1; // 0: Giới thiệu (简介), 1: Chọn tập (选集)
  int _selectedRangeIndex = 0; // Index của dải tập (ví dụ 0 tương ứng 1-30, 1 tương ứng 31-60)
  late HongguoDramaDetail _currentDetail;
  bool _isLoadingDetail = false;

  static const int _episodesPerRange = 30;

  @override
  void initState() {
    super.initState();
    _currentDetail = widget.detail;
    _selectedRangeIndex = (widget.currentEpisode - 1) ~/ _episodesPerRange;

    // Tự động tải toàn bộ danh sách tập nếu chi tiết chưa có danh sách tập
    if (_currentDetail.episodes.length <= 1) {
      _loadFullDetail();
    }
  }

  Future<void> _loadFullDetail() async {
    setState(() => _isLoadingDetail = true);
    try {
      final full = await HongguoResolver().getDramaDetail(_currentDetail.seriesId);
      if (mounted && full.episodes.isNotEmpty) {
        setState(() {
          _currentDetail = full;
          _isLoadingDetail = false;
          _selectedRangeIndex = (widget.currentEpisode - 1).clamp(0, full.episodes.length - 1) ~/ _episodesPerRange;
        });
      } else if (mounted) {
        setState(() => _isLoadingDetail = false);
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingDetail = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _currentDetail.episodes.isNotEmpty
        ? _currentDetail.episodes.length
        : (_currentDetail.totalEpisodes > 0 ? _currentDetail.totalEpisodes : 1);

    final rangeCount = (total / _episodesPerRange).ceil();
    final title = OfflineMlKitTranslator.getCachedTitle(_currentDetail.title) ?? _currentDetail.title;

    return Container(
      height: MediaQuery.of(context).size.height * 0.65,
      decoration: const BoxDecoration(
        color: Color(0xFF16181D),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(color: Colors.black87, blurRadius: 16, offset: Offset(0, -4)),
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

                // Tiêu đề và tổng số tập
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
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
                  icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 20),
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
            const Text('Thể loại', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: widget.detail.tags.map((t) => Chip(
                label: Text(t, style: const TextStyle(color: Colors.white, fontSize: 11)),
                backgroundColor: const Color(0xFF26282E),
                side: BorderSide.none,
                padding: EdgeInsets.zero,
              )).toList(),
            ),
            const SizedBox(height: 16),
          ],
          const Text('Tóm tắt nội dung', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            widget.detail.intro.isNotEmpty
                ? widget.detail.intro
                : 'Hiện chưa có phần giới thiệu chi tiết cho bộ phim này.',
            style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.5),
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
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected ? const Color(0x33FF6A00) : const Color(0xFF22242A),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected ? const Color(0xFFFF6A00) : Colors.transparent,
                        width: 1,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$rStart-$rEnd',
                      style: TextStyle(
                        color: isSelected ? const Color(0xFFFF6A00) : Colors.white70,
                        fontSize: 12,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
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
                      final fetched = await HongguoResolver().getDramaDetail(detailToUse.seriesId);
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
                    color: isPlaying ? const Color(0x26FF6A00) : const Color(0xFF22242A),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isPlaying ? const Color(0xFFFF6A00) : const Color(0xFF2C2F36),
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
                          color: isPlaying ? const Color(0xFFFF6A00) : Colors.white,
                          fontWeight: isPlaying ? FontWeight.bold : FontWeight.w500,
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
