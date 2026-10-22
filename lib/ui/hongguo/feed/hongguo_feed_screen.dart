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
import '../../../domain/media/hongguo/hongguo_similar_engine.dart';
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
/// Model cho tuỳ chọn thể loại trong Feed Hồng Quả
class HongguoFeedGenreOption {
  final String slug;
  final String label;
  final String zhTag;
  final String icon;

  const HongguoFeedGenreOption({
    required this.slug,
    required this.label,
    required this.zhTag,
    required this.icon,
  });
}

/// - Thao tác vuốt dọc mượt mà, chạm dừng/phát, nhấp đúp thả tim
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

  // Danh mục thể loại chuẩn xác 100% của Hồng Quả
  static const List<HongguoFeedGenreOption> realDramaOptions = [
    HongguoFeedGenreOption(slug: '', label: 'Tất cả thể loại', zhTag: '全部', icon: '🌟'),
    HongguoFeedGenreOption(slug: 'costume', label: 'Cổ trang', zhTag: '古装', icon: '🏯'),
    HongguoFeedGenreOption(slug: 'urban', label: 'Đô thị', zhTag: '都市', icon: '🏙️'),
    HongguoFeedGenreOption(slug: 'comeback', label: 'Nghịch tập', zhTag: '逆袭', icon: '⚡'),
    HongguoFeedGenreOption(slug: 'clan', label: 'Hào môn / Gia tộc', zhTag: '家族', icon: '🏰'),
    HongguoFeedGenreOption(slug: 'romance', label: 'Tình cảm', zhTag: '爱情', icon: '❤️'),
    HongguoFeedGenreOption(slug: 'fantasy', label: 'Tu tiên / Huyền huyễn', zhTag: '玄幻', icon: '✨'),
    HongguoFeedGenreOption(slug: 'period', label: 'Niên đại', zhTag: '年代', icon: '📻'),
    HongguoFeedGenreOption(slug: 'suspense', label: 'Hồi hộp / Trinh thám', zhTag: '悬疑', icon: '🔍'),
    HongguoFeedGenreOption(slug: 'comedy', label: 'Hài hước', zhTag: '喜剧', icon: '😂'),
    HongguoFeedGenreOption(slug: 'action-adventure', label: 'Hành động phiêu lưu', zhTag: '动作冒险', icon: '💥'),
    HongguoFeedGenreOption(slug: 'cute-kids', label: 'Manh bảo / Nuôi con', zhTag: '萌宝', icon: '🍼'),
    HongguoFeedGenreOption(slug: 'growth', label: 'Trưởng thành', zhTag: '成长', icon: '🌱'),
    HongguoFeedGenreOption(slug: 'family', label: 'Gia đình', zhTag: '家庭', icon: '🏡'),
    HongguoFeedGenreOption(slug: 'legend', label: 'Truyền kỳ', zhTag: '传奇', icon: '⚔️'),
    HongguoFeedGenreOption(slug: 'supernatural', label: 'Linh dị / Yêu ma', zhTag: '志怪', icon: '👻'),
    HongguoFeedGenreOption(slug: 'sci-fi', label: 'Khoa huyễn', zhTag: '科幻', icon: '🚀'),
    HongguoFeedGenreOption(slug: 'disaster', label: 'Thảm họa', zhTag: '灾难', icon: '🌋'),
    HongguoFeedGenreOption(slug: 'war', label: 'Chiến tranh', zhTag: '战争', icon: '🛡️'),
    HongguoFeedGenreOption(slug: 'youth', label: 'Thanh xuân học đường', zhTag: '青春', icon: '🎓'),
    HongguoFeedGenreOption(slug: 'drama', label: 'Chính kịch / Tâm lý', zhTag: '剧情', icon: '🎭'),
  ];

  static const List<HongguoFeedGenreOption> comicDramaOptions = [
    HongguoFeedGenreOption(slug: '', label: 'Tất cả hoạt hình', zhTag: '全部', icon: '🌟'),
    HongguoFeedGenreOption(slug: 'creative', label: 'Hệ thống / Não động', zhTag: '脑洞', icon: '💡'),
    HongguoFeedGenreOption(slug: 'fantasy', label: 'Tu tiên / Huyền huyễn', zhTag: '玄幻', icon: '✨'),
    HongguoFeedGenreOption(slug: 'apocalypse', label: 'Mạt thế / Sinh tồn', zhTag: '末世', icon: '☣️'),
    HongguoFeedGenreOption(slug: 'wealthy-family', label: 'Hào môn / Đô thị', zhTag: '豪门', icon: '🏰'),
    HongguoFeedGenreOption(slug: 'sci-fi', label: 'Khoa huyễn', zhTag: '科幻', icon: '🚀'),
    HongguoFeedGenreOption(slug: 'adventure', label: 'Phiêu lưu / Nhiệt huyết', zhTag: '冒险', icon: '⚔️'),
    HongguoFeedGenreOption(slug: 'drama', label: 'Tâm lý / Cốt truyện', zhTag: '剧情', icon: '🎭'),
    HongguoFeedGenreOption(slug: 'wonder', label: 'Kỳ ảo / Dị giới', zhTag: '奇幻', icon: '🔮'),
  ];

  static const List<HongguoFeedGenreOption> aiDramaOptions = [
    HongguoFeedGenreOption(slug: '', label: 'Tất cả phim AI', zhTag: '全部', icon: '🌟'),
    HongguoFeedGenreOption(slug: 'creative', label: 'Não động / Sáng tạo', zhTag: '脑洞', icon: '💡'),
    HongguoFeedGenreOption(slug: 'fantasy', label: 'Tu tiên / Huyền huyễn', zhTag: '玄幻', icon: '✨'),
    HongguoFeedGenreOption(slug: 'apocalypse', label: 'Mạt thế / Sinh tồn', zhTag: '末世', icon: '☣️'),
    HongguoFeedGenreOption(slug: 'wealthy-family', label: 'Hào môn / Tổng tài', zhTag: '豪门', icon: '🏰'),
    HongguoFeedGenreOption(slug: 'sci-fi', label: 'Khoa huyễn', zhTag: '科幻', icon: '🚀'),
    HongguoFeedGenreOption(slug: 'adventure', label: 'Phiêu lưu kỳ ảo', zhTag: '冒险', icon: '⚔️'),
    HongguoFeedGenreOption(slug: 'drama', label: 'Tâm lý / Cốt truyện', zhTag: '剧情', icon: '🎭'),
    HongguoFeedGenreOption(slug: 'wonder', label: 'Kỳ ảo', zhTag: '奇幻', icon: '🔮'),
  ];

  List<HongguoFeedGenreOption> _getGenreOptionsForCategory(String category) {
    if (category == 'category/comic-drama') return comicDramaOptions;
    if (category == 'category/ai-drama') return aiDramaOptions;
    return realDramaOptions;
  }

  // Quản lý các Tab khám phá: 'trending' (Thịnh hành) | 'discover' (Đề xuất cá nhân hoá) | 'genre' (Theo thể loại)
  String _currentFeedTab = 'discover';
  String _selectedCategorySlug = 'category/real-drama';
  String _selectedGenreSlug = '';
  String _selectedGenreLabel = 'Người thật';
  String _selectedZhTag = '全部';
  int _trendingPage = 1;
  int _genrePage = 1;

  void _saveFeedPreferences() {
    if (_settings == null || _isDramaEpisodeMode) return;
    _settings!.hongguoFeedTab = _currentFeedTab;
    _settings!.hongguoFeedCategory = _selectedCategorySlug;
    _settings!.hongguoFeedGenreSlug = _selectedGenreSlug;
    _settings!.hongguoFeedGenreLabel = _selectedGenreLabel;
    _settings!.hongguoFeedZhTag = _selectedZhTag;
  }

  // Cache danh sách cho từng tab để chuyển qua lại mượt mà không phải tải lại
  final List<FeedDramaPageItem> _trendingFeedItems = [];
  final List<FeedDramaPageItem> _discoverFeedItems = [];
  final List<FeedDramaPageItem> _genreFeedItems = [];

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

    SettingsRepository.getInstance().then((s) {
      if (!mounted) return;
      setState(() {
        _settings = s;
        _isAutoNextEpisode = s.hongguoAutoNextEpisode;
        _preTranslateCount = s.hongguoPreTranslateCount;
        _preTranslateMode = s.hongguoPreTranslateMode;
        if (_settings!.subtitleOffsetY == 0.0) {
          _settings!.subtitleOffsetY = 90.0;
        }

        if (!_isDramaEpisodeMode) {
          _currentFeedTab = s.hongguoFeedTab;
          _selectedCategorySlug = s.hongguoFeedCategory;
          _selectedGenreSlug = s.hongguoFeedGenreSlug;
          _selectedGenreLabel = s.hongguoFeedGenreLabel;
          _selectedZhTag = s.hongguoFeedZhTag;
        }
      });

      if (!_isDramaEpisodeMode) {
        if (_currentFeedTab == 'genre') {
          _switchFeedTab('genre', forceReload: true);
        } else if (_currentFeedTab == 'trending') {
          _switchFeedTab('trending', forceReload: true);
        } else {
          _switchFeedTab('discover', forceReload: true);
        }
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await HongguoStreamProxyServer.instance.ensureStarted();
      if (!mounted) return;
      await _activatePage(_currentIndex);
    });
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

    return FeedDramaPageItem(
      detail: detail,
      episodeIndex: randomEp,
      vid: vid,
    );
  }

  /// Ưu tiên hiển thị các phim chưa xem lên đầu, phim đã xem gần đây đẩy xuống sau
  List<HongguoDramaItem> _prioritizeUnwatchedDramas(List<HongguoDramaItem> dramas) {
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

    return [...unwatched, ...watched];
  }

  void _initFeedData() {
    if (widget.initialDrama != null) {
      _isDramaEpisodeMode = true;
      _currentDramaDetail = widget.initialDrama;
      _populateDramaEpisodes(_currentDramaDetail!, initialEpisode: widget.initialEpisodeIndex);
    } else if (widget.discoverDramas != null && widget.discoverDramas!.isNotEmpty) {
      _isDramaEpisodeMode = false;
      final sorted = _prioritizeUnwatchedDramas(List<HongguoDramaItem>.from(widget.discoverDramas!));
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
    _completedSub?.cancel();

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

    _completedSub = _activeController?.player.stream.completed.listen((completed) {
      if (completed && _isAutoNextEpisode && !_isScrubbing && mounted) {
        _handleAutoNextEpisode();
      }
    });
  }

  @override
  void dispose() {
    _completedSub?.cancel();
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

      if (_isAutoNextEpisode) {
        await _activeController!.player.setPlaylistMode(PlaylistMode.none);
      } else {
        await _activeController!.player.setPlaylistMode(PlaylistMode.loop);
      }
      await _activeController!.player.setRate(_playbackSpeed);
      await _activeController!.player.play();

      if (_pendingInitialSeekMs != null && _pendingInitialSeekMs! > 0) {
        final seekMs = _pendingInitialSeekMs!;
        _pendingInitialSeekMs = null;
        Future.delayed(const Duration(milliseconds: 120), () async {
          if (!mounted || _activeController == null) return;
          try {
            await _activeController!.player.seek(Duration(milliseconds: seekMs));
            _ttsScheduler?.onSeek(seekMs);
          } catch (e) {
            debugPrint('[HongguoFeedScreen] initial seek error: $e');
          }
        });
      }

      // Kiểm tra tập hiện tại đã có phụ đề trong RAM hoặc Lịch sử chưa
      _checkHistoryForEpisode(index);

      // Ghi nhận phim đã xem vào bộ nhớ để các lần lướt sau luôn ưu tiên phim mới
      if (!_isDramaEpisodeMode && index >= 0 && index < _feedItems.length) {
        final curItem = _feedItems[index];
        _settings?.addHongguoSeenSeriesId(curItem.detail.seriesId);
      }

      if (mounted && _activePageIndex == index) {
        setState(() {
          _isLoadingVideo = false;
        });
      }

      // 4. Nạp trước 4 tập tiếp theo (N+1, N+2, N+3, N+4) và duy trì 7 tập trong Proxy Cache
      _preloadAheadEpisodes(index);
      _maintainProxyMemory(index);

      // Kích hoạt dịch trước ngầm nếu bật tự chuyển tập
      if (_isAutoNextEpisode) {
        _triggerPreTranslationQueue();
      }
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

  /// Nạp trước tối đa 4 tập tiếp theo (N+1, N+2, N+3, N+4) trong nền
  Future<void> _preloadAheadEpisodes(int currentIndex) async {
    for (var i = 1; i <= 4; i++) {
      final targetIndex = currentIndex + i;
      if (!mounted || _activePageIndex != currentIndex) break;
      if (targetIndex >= _feedItems.length) break;
      await _preloadNextPage(targetIndex);
    }
  }

  /// Duy trì tối đa 7 tập trong Proxy Cache: 3 tập trước, 1 tập đang xem, 4 tập phía sau
  void _maintainProxyMemory(int currentIndex) {
    if (currentIndex < 0 || currentIndex >= _feedItems.length) return;
    final activeVids = <String>[
      // 1 tập đang xem
      _feedItems[currentIndex].vid,
      // 3 tập trước đó
      for (var i = 1; i <= 3; i++)
        if (currentIndex - i >= 0) _feedItems[currentIndex - i].vid,
      // 4 tập kế tiếp
      for (var i = 1; i <= 4; i++)
        if (currentIndex + i < _feedItems.length) _feedItems[currentIndex + i].vid,
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
    if (_isLoadingMore) return;
    _isLoadingMore = true;
    try {
      List<HongguoDramaItem> dramas = [];
      if (_currentFeedTab == 'trending') {
        _trendingPage++;
        final res = await _resolver.browseList(
          category: 'rank/hot-drama',
          page: _trendingPage,
        );
        dramas = res.items;
      } else if (_currentFeedTab == 'genre') {
        _genrePage++;
        final res = await _resolver.browseList(
          category: _selectedCategorySlug,
          genre: _selectedGenreSlug,
          page: _genrePage,
        );
        dramas = res.items;
      } else {
        dramas = await HongguoSimilarEngine.instance.getPersonalizedDiscoverList();
      }

      if (!mounted) return;
      final newItems = <FeedDramaPageItem>[];
      final existingSids = _feedItems.map((e) => e.detail.seriesId).toSet();
      for (final drama in dramas) {
        if (!existingSids.contains(drama.seriesId)) {
          newItems.add(_createFeedDramaItem(drama));
        }
      }
      if (mounted) {
        setState(() {
          _feedItems.addAll(newItems);
          _isLoadingMore = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  /// Chuyển đổi giữa 3 tab trên Top Bar: 'trending' | 'discover' | 'genre'
  Future<void> _switchFeedTab(String tabKey, {bool forceReload = false}) async {
    if (_currentFeedTab == tabKey && !forceReload && _feedItems.isNotEmpty) return;

    // Lưu lại danh sách của tab hiện tại trước khi chuyển
    if (_currentFeedTab == 'discover') {
      _discoverFeedItems.clear();
      _discoverFeedItems.addAll(_feedItems);
    } else if (_currentFeedTab == 'trending') {
      _trendingFeedItems.clear();
      _trendingFeedItems.addAll(_feedItems);
    } else if (_currentFeedTab == 'genre') {
      _genreFeedItems.clear();
      _genreFeedItems.addAll(_feedItems);
    }

    setState(() {
      _currentFeedTab = tabKey;
      _isLoadingVideo = true;
    });
    _saveFeedPreferences();

    List<FeedDramaPageItem> targetItems = [];

    if (tabKey == 'trending') {
      if (_trendingFeedItems.isNotEmpty && !forceReload) {
        targetItems = _trendingFeedItems;
      } else {
        final lastPage = _settings?.hongguoFeedTrendingPage ?? 0;
        _trendingPage = forceReload ? ((lastPage % 3) + 1) : 1;
        _settings?.hongguoFeedTrendingPage = _trendingPage;

        try {
          final hotRes = await _resolver.browseList(category: 'rank/hot-drama', page: _trendingPage);
          final sorted = _prioritizeUnwatchedDramas(hotRes.items);
          final items = <FeedDramaPageItem>[];
          for (final drama in sorted) {
            items.add(_createFeedDramaItem(drama));
          }
          targetItems = items;
          _trendingFeedItems.clear();
          _trendingFeedItems.addAll(items);
        } catch (e) {
          debugPrint('[HongguoFeedScreen] Lỗi nạp Trending: $e');
        }
      }
    } else if (tabKey == 'discover') {
      if (_discoverFeedItems.isNotEmpty && !forceReload) {
        targetItems = _discoverFeedItems;
      } else {
        try {
          final list = await HongguoSimilarEngine.instance.getPersonalizedDiscoverList();
          final sorted = _prioritizeUnwatchedDramas(list);
          final items = <FeedDramaPageItem>[];
          for (final drama in sorted) {
            items.add(_createFeedDramaItem(drama));
          }
          targetItems = items;
          _discoverFeedItems.clear();
          _discoverFeedItems.addAll(items);
        } catch (e) {
          debugPrint('[HongguoFeedScreen] Lỗi nạp Discover: $e');
        }
      }
    } else if (tabKey == 'genre') {
      if (_genreFeedItems.isNotEmpty && !forceReload) {
        targetItems = _genreFeedItems;
      } else {
        final lastPage = _settings?.hongguoFeedGenrePage ?? 0;
        _genrePage = forceReload ? ((lastPage % 12) + 1) : 1;
        _settings?.hongguoFeedGenrePage = _genrePage;

        try {
          var res = await _resolver.browseList(
            category: _selectedCategorySlug,
            genre: _selectedGenreSlug,
            page: _genrePage,
          );
          if (res.items.isEmpty && _genrePage > 1) {
            _genrePage = 1;
            res = await _resolver.browseList(
              category: _selectedCategorySlug,
              genre: _selectedGenreSlug,
              page: 1,
            );
          }
          final sorted = _prioritizeUnwatchedDramas(res.items);
          final items = <FeedDramaPageItem>[];
          for (final drama in sorted) {
            items.add(_createFeedDramaItem(drama));
          }
          targetItems = items;
          _genreFeedItems.clear();
          _genreFeedItems.addAll(items);
        } catch (e) {
          debugPrint('[HongguoFeedScreen] Lỗi nạp Genre: $e');
        }
      }
    }

    if (!mounted) return;

    if (targetItems.isNotEmpty) {
      _feedItems.clear();
      _feedItems.addAll(targetItems);
      _currentIndex = 0;
      _preloadedStreamUrls.clear();
      _preloadingIndices.clear();
      _dramaEpisodeSessionKey++;
      _pageController.dispose();
      _pageController = PageController(initialPage: 0);
      _activePageIndex = -1;
      await _activatePage(0);
    } else {
      setState(() => _isLoadingVideo = false);
    }
  }

  /// Mở bảng chọn thể loại & dạng phim (Người thật / Hoạt hình / Phim AI)
  void _openGenrePickerSheet() {
    HapticFeedback.mediumImpact();
    var tempCategory = _selectedCategorySlug;
    var tempGenre = _selectedGenreSlug;
    var tempZhTag = _selectedZhTag;
    var tempLabel = _selectedGenreLabel;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final isReal = tempCategory == 'category/real-drama';
          final isComic = tempCategory == 'category/comic-drama';
          final isAi = tempCategory == 'category/ai-drama';

          final currentOptions = _getGenreOptionsForCategory(tempCategory);
          final categoryName = isComic ? 'Hoạt hình' : (isAi ? 'Phim AI' : 'Người thật');

          String buttonLabel;
          if (tempGenre.isEmpty) {
            buttonLabel = 'Tất cả $categoryName';
          } else {
            buttonLabel = tempLabel;
          }

          return Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.82,
            ),
            decoration: const BoxDecoration(
              color: Color(0xFF181A20),
              borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
              boxShadow: [BoxShadow(color: Colors.black87, blurRadius: 20)],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 8),
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.tune_rounded, color: Color(0xFFFF6A00), size: 19),
                          SizedBox(width: 8),
                          Text(
                            'Bộ lọc Thể loại & Dạng phim',
                            style: TextStyle(color: Colors.white, fontSize: 16.5, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, color: Colors.white54, size: 20),
                        onPressed: () => Navigator.pop(sheetCtx),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12, height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 1. CHỌN DẠNG PHIM
                        Row(
                          children: [
                            const Text(
                              '1. Dạng phim',
                              style: TextStyle(color: Colors.white70, fontSize: 13.5, fontWeight: FontWeight.bold),
                            ),
                            const Spacer(),
                            Text(
                              'Hồng Quả phân loại chuẩn',
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.35), fontSize: 11),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            _buildFilterChip(
                              label: '🎬 Người thật',
                              isSelected: isReal,
                              onSelected: () {
                                setSheetState(() {
                                  tempCategory = 'category/real-drama';
                                  final exists = realDramaOptions.any((o) => o.slug.isNotEmpty && o.slug == tempGenre);
                                  if (!exists) {
                                    tempGenre = '';
                                    tempZhTag = '全部';
                                    tempLabel = 'Người thật';
                                  }
                                });
                              },
                            ),
                            _buildFilterChip(
                              label: '🎨 Hoạt hình',
                              isSelected: isComic,
                              onSelected: () {
                                setSheetState(() {
                                  tempCategory = 'category/comic-drama';
                                  final exists = comicDramaOptions.any((o) => o.slug.isNotEmpty && o.slug == tempGenre);
                                  if (!exists) {
                                    tempGenre = '';
                                    tempZhTag = '全部';
                                    tempLabel = 'Hoạt hình';
                                  }
                                });
                              },
                            ),
                            _buildFilterChip(
                              label: '🤖 Phim AI',
                              isSelected: isAi,
                              onSelected: () {
                                setSheetState(() {
                                  tempCategory = 'category/ai-drama';
                                  final exists = aiDramaOptions.any((o) => o.slug.isNotEmpty && o.slug == tempGenre);
                                  if (!exists) {
                                    tempGenre = '';
                                    tempZhTag = '全部';
                                    tempLabel = 'Phim AI';
                                  }
                                });
                              },
                            ),
                          ],
                        ),

                        const SizedBox(height: 22),

                        // 2. CHỌN THỂ LOẠI
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '2. Thể loại ($categoryName)',
                              style: const TextStyle(color: Colors.white70, fontSize: 13.5, fontWeight: FontWeight.bold),
                            ),
                            Text(
                              tempGenre.isEmpty ? 'Xem toàn bộ thể loại' : 'Đã chọn 1 thể loại',
                              style: const TextStyle(color: Color(0xFFFF9E40), fontSize: 11.5, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          tempGenre.isEmpty
                              ? '💡 Bạn đang chọn xem tất cả $categoryName (không giới hạn thể loại).'
                              : '💡 Chạm vào "Tất cả $categoryName" nếu chỉ muốn lướt dạng phim mà không lọc thể loại.',
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11.5),
                        ),
                        const SizedBox(height: 12),

                        // DANH SÁCH THỂ LOẠI CHUẨN XÁC CỦA HỒNG QUẢ CHO DẠNG PHIM NÀY
                        Wrap(
                          spacing: 8,
                          runSpacing: 10,
                          children: currentOptions.map((opt) {
                            final isSel = tempGenre == opt.slug;
                            final displayLabel = '${opt.icon} ${opt.label}';

                            return _buildFilterChip(
                              label: displayLabel,
                              isSelected: isSel,
                              onSelected: () {
                                setSheetState(() {
                                  tempGenre = opt.slug;
                                  tempZhTag = opt.zhTag;
                                  if (opt.slug.isEmpty) {
                                    tempLabel = categoryName;
                                  } else {
                                    if (isComic) {
                                      tempLabel = 'Hoạt hình · ${opt.label}';
                                    } else if (isAi) {
                                      tempLabel = 'AI · ${opt.label}';
                                    } else {
                                      tempLabel = opt.label;
                                    }
                                  }
                                });
                              },
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                ),

                // NÚT XÁC NHẬN BỘ LỌC
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.of(context).padding.bottom + 12),
                  child: SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.check_rounded, size: 19),
                      label: Text(
                        'Xem phim: $buttonLabel',
                        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF6A00),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                        elevation: 4,
                      ),
                      onPressed: () {
                        Navigator.pop(sheetCtx);
                        setState(() {
                          _selectedCategorySlug = tempCategory;
                          _selectedGenreSlug = tempGenre;
                          _selectedZhTag = tempZhTag;
                          _selectedGenreLabel = tempLabel;
                          _genreFeedItems.clear();
                          _genrePage = 1;
                        });
                        _saveFeedPreferences();
                        _switchFeedTab('genre', forceReload: true);
                      },
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildFilterChip({
    required String label,
    required bool isSelected,
    required VoidCallback onSelected,
  }) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onSelected();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFF6A00).withValues(alpha: 0.18) : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? const Color(0xFFFF6A00) : Colors.white12,
            width: isSelected ? 1.4 : 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? const Color(0xFFFF6A00) : Colors.white70,
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  /// Lọc nhanh theo thể loại khi người dùng chạm vào bất kỳ thẻ tag nào trên video hoặc bảng chi tiết
  void _filterByTag(String tag) {
    HapticFeedback.mediumImpact();
    final cleanZh = tag.replaceAll(RegExp(r'[\[\]#\s]'), '').trim();
    final viLabel = HongguoSimilarEngine.getTagLabel(cleanZh);

    // Tìm trong các danh mục chuẩn
    HongguoFeedGenreOption? matched;
    String matchedCategory = 'category/real-drama';

    for (final opt in realDramaOptions) {
      if (opt.slug.isNotEmpty && (opt.zhTag == cleanZh || opt.slug == cleanZh.toLowerCase())) {
        matched = opt;
        matchedCategory = 'category/real-drama';
        break;
      }
    }
    if (matched == null) {
      for (final opt in comicDramaOptions) {
        if (opt.slug.isNotEmpty && (opt.zhTag == cleanZh || opt.slug == cleanZh.toLowerCase())) {
          matched = opt;
          matchedCategory = 'category/comic-drama';
          break;
        }
      }
    }
    if (matched == null) {
      for (final opt in aiDramaOptions) {
        if (opt.slug.isNotEmpty && (opt.zhTag == cleanZh || opt.slug == cleanZh.toLowerCase())) {
          matched = opt;
          matchedCategory = 'category/ai-drama';
          break;
        }
      }
    }

    final targetSlug = matched?.slug ?? '';
    final targetLabel = matched != null ? matched.label : viLabel;

    setState(() {
      _selectedZhTag = cleanZh;
      _selectedCategorySlug = matchedCategory;
      _selectedGenreSlug = targetSlug;
      _selectedGenreLabel = targetLabel;
      _genreFeedItems.clear();
      _genrePage = 1;
    });

    _saveFeedPreferences();
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
                'Đang lọc theo thể loại: $targetLabel',
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

    _switchFeedTab('genre', forceReload: true);
  }

  /// Mở Bottom Sheet tìm phim tương tự theo Zone
  void _openSimilarDramasSheet(FeedDramaPageItem item) {
    HapticFeedback.mediumImpact();
    HongguoSimilarEngine.instance.recordInterest(item.detail.tags, 3.0);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => _SimilarDramasBottomSheet(
        currentItem: item,
        onSelectDrama: (selectedDrama) {
          Navigator.pop(sheetCtx);
          final detail = _dramaItemToDetail(selectedDrama);
          _switchToDramaEpisodeMode(detail);
        },
        onPlaySimilarFeed: (similarDramas) {
          Navigator.pop(sheetCtx);
          _loadSimilarDramasIntoFeed(similarDramas);
        },
      ),
    );
  }

  /// Nạp chuỗi các phim tương tự vào Feed và bắt đầu lướt
  Future<void> _loadSimilarDramasIntoFeed(List<HongguoDramaItem> similarDramas) async {
    HapticFeedback.mediumImpact();
    final items = <FeedDramaPageItem>[];
    for (final drama in similarDramas) {
      items.add(_createFeedDramaItem(drama));
    }
    if (items.isEmpty) return;

    setState(() {
      _isDramaEpisodeMode = false;
      _feedItems.clear();
      _feedItems.addAll(items);
      _currentIndex = 0;
      _preloadedStreamUrls.clear();
      _preloadingIndices.clear();
      _dramaEpisodeSessionKey++;
    });
    _pageController.dispose();
    _pageController = PageController(initialPage: 0);
    _activePageIndex = -1;
    await _activatePage(0);

    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.auto_awesome_motion_rounded, color: Color(0xFF2DE1FC), size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Đang lướt chuỗi ${items.length} phim tương tự theo Zone'),
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
    if (_currentIndex >= 0 && _currentIndex < _feedItems.length) {
      final curItem = _feedItems[_currentIndex];
      HongguoSimilarEngine.instance.recordInterest(curItem.detail.tags, 5.0);
    }
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
        onSelectTag: _filterByTag,
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
                      label: 'Thịnh hành',
                      isSelected: _currentFeedTab == 'trending',
                      onTap: () => _switchFeedTab('trending', forceReload: _currentFeedTab == 'trending'),
                    ),
                    const SizedBox(width: 18),
                    _buildTopTabItem(
                      label: 'Đề xuất',
                      isSelected: _currentFeedTab == 'discover',
                      onTap: () => _switchFeedTab('discover', forceReload: _currentFeedTab == 'discover'),
                    ),
                    const SizedBox(width: 18),
                    _buildTopTabItem(
                      label: _selectedGenreLabel.isNotEmpty ? _selectedGenreLabel : 'Thể loại',
                      isSelected: _currentFeedTab == 'genre',
                      showDropdownIcon: true,
                      onTap: () {
                        if (_currentFeedTab != 'genre') {
                          _switchFeedTab('genre');
                        } else {
                          _openGenrePickerSheet();
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Nút Làm mới luồng phim (Tải loạt phim mới)
          GestureDetector(
            onTap: () {
              HapticFeedback.mediumImpact();
              _switchFeedTab(_currentFeedTab, forceReload: true);
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Row(
                    children: [
                      Icon(Icons.autorenew_rounded, color: Color(0xFFFF6A00), size: 16),
                      SizedBox(width: 8),
                      Text('Đang nạp loạt trích đoạn phim mới...', style: TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                  backgroundColor: const Color(0xFF22242A),
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 1),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.all(8),
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.35),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.refresh_rounded, color: Colors.white, size: 20),
            ),
          ),

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
                  color: isSelected ? Colors.white : Colors.white.withValues(alpha: 0.65),
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
                    // Tiêu đề phim có dấu mũi tên `>` (nhấn vào mở xem trọn bộ, nhấn giữ để sao chép tiêu đề)
                    GestureDetector(
                      onTap: () => _showEpisodePickerSheet(item.detail),
                      onLongPress: () {
                        HapticFeedback.lightImpact();
                        Clipboard.setData(ClipboardData(text: item.detail.title));
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Row(
                              children: [
                                const Icon(Icons.copy_rounded, color: Color(0xFFFF6A00), size: 16),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text('Đã sao chép tiêu đề: ${item.detail.title}'),
                                ),
                              ],
                            ),
                            backgroundColor: const Color(0xFF22242A),
                            behavior: SnackBarBehavior.floating,
                            duration: const Duration(seconds: 2),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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

                    // Hàng thẻ Tags được Việt hoá (chạm vào để lọc phim theo tag đó ngay)
                    if (item.detail.tags.isNotEmpty)
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: item.detail.tags.take(4).map((tag) {
                          final viLabel = HongguoSimilarEngine.getTagLabel(tag);
                          return GestureDetector(
                            onTap: () => _filterByTag(tag),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
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

                  // 3. Nút Tự động chuyển tập (kèm Dịch & Lồng tiếng trước trong nền)
                  _buildAutoNextEpisodeButton(item),

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
                            HongguoSimilarEngine.instance.recordInterest(item.detail.tags, 4.0);
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
          await _switchToDramaEpisodeMode(item.detail, targetEpisode: item.episodeIndex);
          await _activeController?.player.setPlaylistMode(PlaylistMode.none);
          _triggerPreTranslationQueue();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    const Icon(Icons.playlist_play_rounded, color: Colors.white, size: 20),
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
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
                  content: Text('Đã bật Tự chuyển tập (${_preTranslateMode == 'sub_and_tts' ? 'Vietsub + Lồng tiếng' : 'Chỉ Vietsub'}, dịch trước $_preTranslateCount tập)'),
                  backgroundColor: const Color(0xFFFF6A00),
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 2),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
                  _isAutoNextEpisode ? Icons.playlist_play_rounded : Icons.skip_next_rounded,
                  color: _isAutoNextEpisode ? const Color(0xFFFF6A00) : Colors.white,
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
              color: _isAutoNextEpisode ? const Color(0xFFFF6A00) : Colors.white,
              fontSize: 10,
              fontWeight: _isAutoNextEpisode ? FontWeight.bold : FontWeight.w500,
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
                      const Icon(Icons.tune_rounded, color: Color(0xFFFF6A00), size: 22),
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
                        icon: const Icon(Icons.close_rounded, color: Colors.white54, size: 20),
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
                      style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
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
                        _activeController?.player.setPlaylistMode(PlaylistMode.none);
                        _triggerPreTranslationQueue();
                      } else {
                        _activeController?.player.setPlaylistMode(PlaylistMode.loop);
                      }
                    },
                  ),

                  const SizedBox(height: 14),

                  // 2. Chế độ xử lý trước
                  const Text(
                    'Chế độ chuẩn bị trước cho các tập kế tiếp',
                    style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
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
                            contentPadding: EdgeInsets.symmetric(horizontal: 10),
                            activeColor: Color(0xFFFF6A00),
                            title: Text('Vietsub & Lồng tiếng AI (Khuyên dùng)', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                            subtitle: Text('Tạo cả phụ đề tiếng Việt và giọng đọc AI trước để xem liền mạch.', style: TextStyle(color: Colors.white54, fontSize: 11)),
                            value: 'sub_and_tts',
                          ),
                          Divider(color: Colors.white10, height: 1),
                          RadioListTile<String>(
                            contentPadding: EdgeInsets.symmetric(horizontal: 10),
                            activeColor: Color(0xFFFF6A00),
                            title: Text('Chỉ tạo Phụ đề Vietsub', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                            subtitle: Text('Chỉ dịch phụ đề trước, không tạo trước file giọng đọc.', style: TextStyle(color: Colors.white54, fontSize: 11)),
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
                        style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '$_preTranslateCount tập',
                        style: const TextStyle(color: Color(0xFFFF6A00), fontSize: 13, fontWeight: FontWeight.bold),
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
                            if (_isAutoNextEpisode) _triggerPreTranslationQueue();
                          },
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: isSelected ? const Color(0xFFFF6A00) : Colors.white10,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isSelected ? const Color(0xFFFF6A00) : Colors.white12,
                              ),
                            ),
                            child: Center(
                              child: Text(
                                '$count tập',
                                style: TextStyle(
                                  color: isSelected ? Colors.white : Colors.white70,
                                  fontSize: 12,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
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
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        if (_isAutoNextEpisode) _triggerPreTranslationQueue();
                      },
                      child: const Text('Xong & Áp dụng', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
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
        HongguoSimilarEngine.instance.recordInterest(currentItem.detail.tags, 2.5);
        await _switchToDramaEpisodeMode(currentItem.detail, targetEpisode: currentItem.episodeIndex + 1);
        _triggerPreTranslationQueue();
        return;
      }
    }

    if (_currentIndex < _feedItems.length - 1) {
      if (_currentIndex >= 0 && _currentIndex < _feedItems.length) {
        final currentItem = _feedItems[_currentIndex];
        HongguoSimilarEngine.instance.recordInterest(currentItem.detail.tags, 2.5);
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
    final endIdx = math.min(_feedItems.length - 1, _currentIndex + _preTranslateCount);
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
          final hasTts = existingDoc.items.any((it) => it.audioFilePath != null && it.audioFilePath!.isNotEmpty);
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
          final hasTts = loadedFromHistory.items.any((it) => it.audioFilePath != null && it.audioFilePath!.isNotEmpty);
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
        if (h.seriesId == item.detail.seriesId && h.episodeIndex == item.episodeIndex) {
          final doc = await historyRepo.loadSubtitleDocument(h);
          if (doc != null && doc.isNotEmpty) {
            final voiceType = _settings?.hongguoSelectedTtsVoice ?? VoicePresets.defaultVoice.voiceType;
            await TtsCacheHelper.linkAudioFiles(doc, voiceType);
            await _calibratePlaybackSpeeds(doc);
            return doc;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _preGenerateTtsForDoc(SubtitleDocument doc, FeedDramaPageItem item) async {
    try {
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
      debugPrint('[HongguoFeed] 🚀 Dịch trước ngầm: ${targetItem.detail.title} - Tập ${targetItem.episodeIndex}');

      var itemToProcess = targetItem;
      if (itemToProcess.vid.isEmpty || itemToProcess.vid == itemToProcess.detail.seriesId) {
        try {
          final fullDetail = await _resolver.getDramaDetail(itemToProcess.detail.seriesId);
          if (fullDetail.episodes.isNotEmpty) {
            final epIdx = itemToProcess.episodeIndex.clamp(1, fullDetail.episodes.length);
            itemToProcess = FeedDramaPageItem(
              detail: fullDetail,
              episodeIndex: epIdx,
              vid: fullDetail.episodes[epIdx - 1].vid,
            );
          }
        } catch (_) {}
      }

      if (itemToProcess.vid.isEmpty) return;

      final videoInfo = await HongguoLocalEngine.resolveVideoInfo(itemToProcess.vid, preferLowest: true);
      final streamUrl = videoInfo.realMainUrl;
      if (streamUrl.isEmpty) return;

      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      tempMp4 = File('${tempDir.path}/pre_${itemToProcess.detail.seriesId}_${itemToProcess.episodeIndex}_$timestamp.mp4');
      tempAudio = File('${tempDir.path}/pre_audio_${itemToProcess.detail.seriesId}_${itemToProcess.episodeIndex}_$timestamp.m4a');

      final headers = NetworkHeaderHelper.getHeadersForUrl(streamUrl);
      await MultiThreadDownloader.downloadFile(
        url: streamUrl,
        outputFile: tempMp4,
        headers: headers,
        concurrency: 4,
      );

      if (!tempMp4.existsSync() || tempMp4.lengthSync() < 1024) return;

      if (videoInfo.isDrmProtected) {
        final encryptedBytes = await tempMp4.readAsBytes();
        final keyBytes = Uint8List.fromList(hex.decode(videoInfo.contentKeyHex));
        final decryptedBytes = HongguoCencDecryptor.decryptMp4Cenc(encryptedBytes, keyBytes);
        await tempMp4.writeAsBytes(decryptedBytes, flush: true);
      }

      await AudioExtractor.extractAudio(
        videoPath: tempMp4.path,
        outputPath: tempAudio.path,
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
          engine = settings.selectedGeminiModel.isNotEmpty ? settings.selectedGeminiModel : 'gemini-3.1-flash-lite';
        } else if (settings.groqApiKeys.isNotEmpty) {
          engine = settings.selectedGroqModel.isNotEmpty ? settings.selectedGroqModel : 'openai/gpt-oss-120b';
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
        totalDurationMs: 120000,
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

        final unlinked = doc.items.where(
          (i) => (i.audioFilePath == null || i.audioFilePath!.isEmpty) &&
                 TtsGenerationManager.isPronounceable(i.translatedText),
        ).toList();

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
          title: '${itemToProcess.detail.title} - Tập ${itemToProcess.episodeIndex}',
          document: doc,
          durationMs: 120000,
          ttsVoice: appliedVoice,
          seriesId: itemToProcess.detail.seriesId,
          seriesCover: itemToProcess.detail.cover,
          episodeIndex: itemToProcess.episodeIndex,
          totalEpisodes: itemToProcess.detail.totalEpisodes > 0 ? itemToProcess.detail.totalEpisodes : itemToProcess.detail.episodes.length,
          isOnlineStream: true,
        );
      } catch (_) {}

      debugPrint('[HongguoFeed] ✅ Đã dịch trước ngầm thành công tập ${itemToProcess.episodeIndex}!');
    } catch (e) {
      debugPrint('[HongguoFeed] Lỗi dịch trước tập ${targetItem.episodeIndex}: $e');
    } finally {
      try {
        if (tempMp4 != null && tempMp4.existsSync()) await tempMp4.delete();
        if (tempAudio != null && tempAudio.existsSync()) await tempAudio.delete();
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
typedef OnTagSelectedCallback = void Function(String tag);

/// Bottom Sheet chọn tập chuẩn ByteDance (Frame 15 Style)
class _ByteDanceEpisodePickerSheet extends StatefulWidget {
  final HongguoDramaDetail detail;
  final int currentEpisode;
  final OnEpisodeSelectedCallback onSelectEpisode;
  final OnTagSelectedCallback? onSelectTag;

  const _ByteDanceEpisodePickerSheet({
    required this.detail,
    required this.currentEpisode,
    required this.onSelectEpisode,
    this.onSelectTag,
  });

  @override
  State<_ByteDanceEpisodePickerSheet> createState() => _ByteDanceEpisodePickerSheetState();
}

class _ByteDanceEpisodePickerSheetState extends State<_ByteDanceEpisodePickerSheet> {
  int _selectedTabIndex = 1; // 0: Giới thiệu (简介), 1: Chọn tập (选集)
  int _selectedRangeIndex = 0; // Index của dải tập (ví dụ 0 tương ứng 1-30, 1 tương ứng 31-60)
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

                // Tiêu đề và tổng số tập (nhấn để sao chép tiêu đề)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _copyDramaTitle(_currentDetail.title.isNotEmpty ? _currentDetail.title : title),
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
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 200),
                              child: _isCopiedTitle
                                  ? Container(
                                      key: const ValueKey('copied_badge'),
                                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFF6A00),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.check_rounded, color: Colors.white, size: 10),
                                          SizedBox(width: 2),
                                          Text('Đã chép', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
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
            const Row(
              children: [
                Icon(Icons.label_outline_rounded, color: Color(0xFFFF6A00), size: 14),
                SizedBox(width: 6),
                Text('Thể loại (chạm để xem thêm phim cùng chủ đề)', style: TextStyle(color: Colors.white70, fontSize: 12.5, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: widget.detail.tags.map((t) {
                final viLabel = HongguoSimilarEngine.getTagLabel(t);
                return ActionChip(
                  avatar: const Icon(Icons.tag_rounded, size: 13, color: Color(0xFFFF6A00)),
                  label: Text(viLabel, style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w500)),
                  backgroundColor: const Color(0xFF26282E),
                  side: const BorderSide(color: Colors.white12, width: 0.8),
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  onPressed: () {
                    Navigator.pop(context);
                    widget.onSelectTag?.call(t);
                  },
                );
              }).toList(),
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

/// Bottom Sheet hiển thị danh sách phim tương tự theo Zone (Zone 1: Cực kỳ giống, Zone 2: Cùng chủ đề, Zone 3: Mở rộng)
class _SimilarDramasBottomSheet extends StatefulWidget {
  final FeedDramaPageItem currentItem;
  final ValueChanged<HongguoDramaItem> onSelectDrama;
  final ValueChanged<List<HongguoDramaItem>> onPlaySimilarFeed;

  const _SimilarDramasBottomSheet({
    required this.currentItem,
    required this.onSelectDrama,
    required this.onPlaySimilarFeed,
  });

  @override
  State<_SimilarDramasBottomSheet> createState() => _SimilarDramasBottomSheetState();
}

class _SimilarDramasBottomSheetState extends State<_SimilarDramasBottomSheet> {
  bool _isLoading = true;
  List<SimilarDramaResult> _results = [];

  @override
  void initState() {
    super.initState();
    _loadSimilarDramas();
  }

  Future<void> _loadSimilarDramas() async {
    try {
      final list = await HongguoSimilarEngine.instance.findSimilarDramas(
        detail: widget.currentItem.detail,
      );
      if (mounted) {
        setState(() {
          _results = list;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final curTitle = OfflineMlKitTranslator.getCachedTitle(widget.currentItem.detail.title) ??
        widget.currentItem.detail.title;
    final curTags = HongguoSimilarEngine.instance.extractTagsFromDrama(
      tags: widget.currentItem.detail.tags,
      title: widget.currentItem.detail.title,
      intro: widget.currentItem.detail.intro,
    );

    final zone1 = _results.where((r) => r.zone == 1).toList();
    final zone2 = _results.where((r) => r.zone == 2).toList();
    final zone3 = _results.where((r) => r.zone == 3).toList();

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.78,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF16181D),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [BoxShadow(color: Colors.black87, blurRadius: 18, offset: Offset(0, -4))],
      ),
      child: Column(
        children: [
          // Drag handle
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2DE1FC).withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.auto_awesome_motion_rounded, color: Color(0xFF2DE1FC), size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Phim tương tự theo Zone',
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Gợi ý dựa trên thể loại của: $curTitle',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),

          // Hàng tag của phim hiện tại
          if (curTags.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: Colors.black12,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    const Text('Tags gốc: ', style: TextStyle(color: Colors.white38, fontSize: 11)),
                    for (final tag in curTags.take(5))
                      Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.white12, width: 0.6),
                        ),
                        child: Text(
                          HongguoSimilarEngine.getTagLabel(tag),
                          style: const TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ),
                  ],
                ),
              ),
            ),

          const Divider(color: Colors.white12, height: 1),

          // Nội dung
          Expanded(
            child: _isLoading
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(color: Color(0xFF2DE1FC), strokeWidth: 2.2),
                        ),
                        SizedBox(height: 12),
                        Text(
                          'Đang tổ hợp thể loại & phân nhóm Zone...',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ],
                    ),
                  )
                : _results.isEmpty
                    ? const Center(
                        child: Text(
                          'Chưa tìm thấy phim tương tự cho thể loại này.',
                          style: TextStyle(color: Colors.white54, fontSize: 13),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        children: [
                          // Nút Lướt ngay toàn bộ danh sách tương tự
                          Container(
                            margin: const EdgeInsets.only(bottom: 14),
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.play_arrow_rounded, size: 20),
                              label: Text(
                                '⚡ Lướt chuỗi ${_results.length} phim tương tự theo Zone',
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF2DE1FC),
                                foregroundColor: Colors.black,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                elevation: 4,
                              ),
                              onPressed: () => widget.onPlaySimilarFeed(_results.map((r) => r.drama).toList()),
                            ),
                          ),

                          // Zone 1
                          if (zone1.isNotEmpty) ...[
                            _buildZoneHeader(
                              icon: Icons.stars_rounded,
                              color: const Color(0xFFFF6A00),
                              title: 'Zone 1: Cực kỳ giống',
                              subtitle: 'Trùng nhiều thể loại & phong cách nhất',
                              count: zone1.length,
                            ),
                            const SizedBox(height: 8),
                            for (final item in zone1) _buildDramaCard(item),
                            const SizedBox(height: 16),
                          ],

                          // Zone 2
                          if (zone2.isNotEmpty) ...[
                            _buildZoneHeader(
                              icon: Icons.track_changes_rounded,
                              color: const Color(0xFF2DE1FC),
                              title: 'Zone 2: Cùng chủ đề',
                              subtitle: 'Trùng thể loại chính của phim',
                              count: zone2.length,
                            ),
                            const SizedBox(height: 8),
                            for (final item in zone2) _buildDramaCard(item),
                            const SizedBox(height: 16),
                          ],

                          // Zone 3
                          if (zone3.isNotEmpty) ...[
                            _buildZoneHeader(
                              icon: Icons.explore_rounded,
                              color: const Color(0xFFB388FF),
                              title: 'Zone 3: Mở rộng liên quan',
                              subtitle: 'Đa dạng hoá, có thể bạn sẽ thích',
                              count: zone3.length,
                            ),
                            const SizedBox(height: 8),
                            for (final item in zone3) _buildDramaCard(item),
                          ],
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildZoneHeader({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required int count,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 0.8),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$title ($count phim)',
                  style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold),
                ),
                Text(
                  subtitle,
                  style: TextStyle(color: color.withValues(alpha: 0.8), fontSize: 10.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDramaCard(SimilarDramaResult item) {
    final drama = item.drama;
    final title = OfflineMlKitTranslator.getCachedTitle(drama.title) ?? drama.title;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12, width: 0.6),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => widget.onSelectDrama(drama),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              // Ảnh bìa
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(
                  drama.cover,
                  width: 52,
                  height: 72,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    width: 52,
                    height: 72,
                    color: const Color(0xFF26282E),
                    child: const Icon(Icons.movie_rounded, color: Colors.white30, size: 24),
                  ),
                ),
              ),
              const SizedBox(width: 12),

              // Thông tin phim
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      drama.episodeCount > 0 ? 'Trọn bộ ${drama.episodeCount} tập' : 'Phim ngắn hot',
                      style: const TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                    const SizedBox(height: 6),
                    // Matched Tags
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final tag in item.matchedTags.take(3))
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFF6A00).withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: const Color(0xFFFF6A00).withValues(alpha: 0.5), width: 0.6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.check_rounded, color: Color(0xFFFF6A00), size: 10),
                                const SizedBox(width: 2),
                                Text(
                                  HongguoSimilarEngine.getTagLabel(tag),
                                  style: const TextStyle(color: Color(0xFFFF9E40), fontSize: 10, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),

              // Nút Xem
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF6A00),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.play_arrow_rounded, color: Colors.white, size: 14),
                    SizedBox(width: 2),
                    Text('Xem', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
