import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../data/model/subtitle_document.dart';
import '../../data/repository/history_repository.dart';
import '../../data/repository/settings_repository.dart';
import '../../domain/ai/offline_mlkit_translator.dart';
import '../../domain/ai/title_translator.dart';
import '../../domain/media/bilibili_resolver.dart';
import '../../domain/media/hongguo_prefetch_manager.dart';
import '../../domain/media/hongguo_resolver.dart';
import '../../domain/media/video_cache_manager.dart';
import '../../domain/media/media_storage.dart';
import '../../domain/media/multi_thread_downloader.dart';
import '../../domain/media/network_header_helper.dart';
import '../../domain/service/foreground_service_manager.dart';
import '../../domain/tts/audio_file_validator.dart';
import '../../player/global_player_manager.dart';
import '../../player/pip_manager.dart';
import '../../player/tts_audio_scheduler.dart';
import '../../data/model/voice_model.dart';
import '../../domain/pipeline/subtitling_pipeline.dart';
import '../../domain/tts/tts_cache_helper.dart';
import '../../domain/tts/tts_generation_manager.dart';
import '../bilibili/bilibili_settings_sheet.dart';
import '../bilibili/bilibili_uploader_sheet.dart';
import '../bilibili/bilibili_season_sheet.dart';
import '../theme/app_theme.dart';
import 'dual_volume_sheet.dart';
import 'subtitle_control_sheet.dart';
import 'subtitle_overlay.dart';
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
  final String? coverUrl;
  final String? author;
  final BilibiliAnimeItem? bilibiliItem;
  final bool isGlobalPlayer;

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
    this.coverUrl,
    this.author,
    this.bilibiliItem,
    this.isGlobalPlayer = false,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen>
    with WidgetsBindingObserver {
  static const _playbackSpeeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
  static const _stallThreshold = Duration(milliseconds: 1200);
  static const _positionSaveInterval = Duration(seconds: 3);
  static const _videoInitializeTimeout = Duration(seconds: 45);

  bool _isSwitchingQuality = false;
  String _currentQualityKey = '64';
  bool _isPlayerFullScreen = false;
  List<BilibiliAnimeItem> _rawDirectRelated = [];
  List<BilibiliAnimeItem> _rawRecommendFeed = [];
  List<BilibiliAnimeItem> _rawPopularVideos = [];
  List<BilibiliAnimeItem> _blendedRelatedVideos = [];
  String _selectedRelatedTab = 'blended';
  int _recommendFreshIdx = 1;
  bool _isLoadingRelated = false;
  bool _isRefreshingRelated = false;
  bool _isLoadingMoreRelated = false;
  String? _lastLoadedRelatedBvid;
  String? _coverUrl;
  String? _authorName;
  String? _upFaceUrl;
  BilibiliAnimeItem? _bilibiliItem;

  String get _currentQualityLabel {
    switch (_currentQualityKey) {
      case '80':
        return '1080P';
      case '64':
        return '720P';
      case '32':
        return '480P';
      case '16':
        return '360P';
      default:
        return 'HD';
    }
  }

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
  bool _isInBackground = false;

  // Trạng thái điều khiển PiP (Picture-in-Picture)
  bool _pipShowControls = true;
  Timer? _pipControlsTimer;
  double _pipZoomScale = 1.0;
  double _pipBaseScale = 1.0;
  int _pipSizeRatioIndex = 0; // 0: Gốc, 1: 16:9, 2: 4:3, 3: Fill
  bool _pipDoubleTapLeft = false;
  bool _pipDoubleTapRight = false;
  Timer? _pipFeedbackTimer;

  // Quản lý trạng thái phim bộ Hồng Quả
  late int _currentEpisodeIndex;
  late String _sourceVideoUrl;
  late String _currentVideoPath;
  late String _currentTitle;
  late SubtitleDocument _currentDocument;
  BilibiliVideoDetails? _bilibiliDetails;
  HongguoPrefetchManager? _prefetchManager;
  bool _autoPlayNextEpisode = true;
  bool _isSwitchingEpisode = false;
  bool _isDownloadingVideo = false;
  double _downloadProgress = 0.0;
  String _downloadMessage = '';
  bool _showDownloadBanner = true;
  bool _userChosePlayRaw = false;

  String? _originalTitle;
  String? _translatedTitle;
  bool _showTranslatedTitle = false;
  bool _isTranslatingTitle = false;

  // Bilibili Tab & Interactive State (Giới thiệu / Bình luận)
  int _bilibiliTabIndex = 0; // 0: Giới thiệu, 1: Bình luận
  BilibiliUploaderProfile? _bilibiliUploaderProfile;
  bool _isFollowingBilibiliUploader = false;
  bool _isTogglingBilibiliFollow = false;
  BilibiliCommentResult? _bilibiliCommentResult;
  List<BilibiliCommentItem> _bilibiliComments = [];
  bool _isLoadingBilibiliComments = false;
  bool _isLoadingMoreComments = false;
  bool _hasMoreComments = true;
  int _bilibiliCommentPage = 1;
  int _bilibiliCommentSort = 2; // 2: Mới nhất, 0: Nổi bật
  final Map<int, String> _bilibiliCommentTranslations = {};
  final Set<int> _bilibiliTranslatingCommentIds = {};
  String _commentTranslationEngine = 'local';

  // On-demand subtitling and progressive AI dubbing (Bilibili / External links)
  bool _isTranslatingOnDemand = false;
  String _onDemandProgressMessage = '';
  double _onDemandProgressPct = 0.0;

  Future<void> _startOnDemandPipeline({required bool enableTts}) async {
    if (_isTranslatingOnDemand) return;

    final bool isBilibili = _bilibiliDetails != null || BilibiliResolver.isBilibiliUrl(_sourceVideoUrl);
    final bool isHongguo = widget.dramaDetail != null;

    final String selectedVoiceType;
    if (isHongguo) {
      selectedVoiceType = _settings.hongguoSelectedTtsVoice;
    } else if (isBilibili) {
      selectedVoiceType = _settings.bilibiliSelectedTtsVoice;
    } else {
      selectedVoiceType = _settings.selectedTtsVoice;
    }

    final voice = VoicePresets.vietnameseVoices.firstWhere(
      (v) => v.voiceType == selectedVoiceType,
      orElse: () => VoicePresets.vietnameseVoices.first,
    );

    // TRƯỜNG HỢP 1: Nếu chưa có phụ đề trên màn hình, thử tìm trong Lịch sử trước
    if (_currentDocument.isEmpty) {
      try {
        final history = await HistoryRepository.getInstance();
        final bvid = RegExp(r'BV[a-zA-Z0-9]+', caseSensitive: false).firstMatch(_sourceVideoUrl)?.group(0);
        final item = history.getHistory().where((h) {
          if (h.videoPath == _sourceVideoUrl || h.videoPath == _currentVideoPath) return true;
          if (bvid != null && h.videoPath.contains(bvid)) return true;
          return false;
        }).firstOrNull;

        if (item != null) {
          final loadedDoc = await history.loadSubtitleDocument(item);
          if (loadedDoc != null && loadedDoc.isNotEmpty) {
            setState(() {
              _currentDocument = loadedDoc;
              _ttsScheduler.dispose();
              _ttsScheduler = TtsAudioScheduler(loadedDoc);
            });
          }
        }
      } catch (_) {}
    }

    // TRƯỜNG HỢP 2: Nếu ĐÃ CÓ phụ đề (từ trước hoặc vừa xem Vietsub xong):
    // KHÔNG BAO GIỜ DỊCH LẠI! Trực tiếp tái sử dụng file phụ đề đã có!
    if (_currentDocument.isNotEmpty) {
      if (!enableTts) {
        // Người dùng chọn chế độ chỉ xem Vietsub (tắt lồng tiếng)
        setState(() {
          _settings.isTtsPlaybackEnabled = false;
        });
        _syncTtsWithVideo();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('🎉 Phụ đề Vietsub đã sẵn sàng (đã tắt lồng tiếng)!'),
              backgroundColor: Color(0xFF00AEEC),
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }

      // Người dùng chuyển sang Lồng tiếng AI -> Tạo giọng đọc trực tiếp từ sub đã có!
      await _generateTtsForCurrentDocument(voice);
      return;
    }

    // TRƯỜNG HỢP 3: Chưa có bất kỳ phụ đề nào -> Chạy quy trình bóc tách & dịch từ đầu
    final controller = _controller;
    final durationMs = (controller != null && controller.value.isInitialized)
        ? controller.value.duration.inMilliseconds
        : 60000;

    setState(() {
      _isTranslatingOnDemand = true;
      _onDemandProgressMessage = 'Đang bóc tách & dịch phụ đề...';
      _onDemandProgressPct = 0.05;
    });

    String translationEngine = _settings.selectedModel;
    String customPrompt = _settings.geminiCustomPrompt;

    if (isBilibili) {
      if (_settings.bilibiliTranslationMode == 'capcut') {
        translationEngine = 'capcut';
      } else {
        if (_settings.geminiApiKeys.isNotEmpty) {
          translationEngine = _settings.selectedGeminiModel.isNotEmpty
              ? _settings.selectedGeminiModel
              : 'gemini-3.1-flash-lite';
        } else if (_settings.groqApiKeys.isNotEmpty) {
          translationEngine = _settings.selectedGroqModel.isNotEmpty
              ? _settings.selectedGroqModel
              : 'openai/gpt-oss-120b';
        } else {
          translationEngine = 'capcut';
        }
      }
    } else if (isHongguo) {
      customPrompt = _settings.hongguoCustomPrompt;
      if (_settings.hongguoTranslationMode == 'capcut') {
        translationEngine = 'capcut';
      } else {
        if (_settings.geminiApiKeys.isNotEmpty) {
          translationEngine = _settings.selectedGeminiModel.isNotEmpty
              ? _settings.selectedGeminiModel
              : 'gemini-3.1-flash-lite';
        } else if (_settings.groqApiKeys.isNotEmpty) {
          translationEngine = _settings.selectedGroqModel.isNotEmpty
              ? _settings.selectedGroqModel
              : 'openai/gpt-oss-120b';
        } else {
          translationEngine = 'capcut';
        }
      }
    }

    try {
      final pipeline = SubtitlingPipeline(
        apiKeys: _settings.geminiApiKeys,
        groqApiKeys: _settings.groqApiKeys,
        translationEngine: translationEngine,
        stylePreset: _settings.selectedStyle,
        customPrompt: customPrompt,
        targetLanguage: _settings.targetLanguage,
        geminiThreadCount: _settings.geminiThreadCount,
        geminiBatchSize: _settings.geminiBatchSize,
        groqThreadCount: _settings.groqThreadCount,
        groqBatchSize: _settings.groqBatchSize,
      );

      final sub = pipeline.progressStream.listen((prog) {
        if (!mounted) return;
        setState(() {
          _onDemandProgressPct = prog.progress;
          _onDemandProgressMessage = prog.message.isNotEmpty
              ? prog.message
              : 'Đang dịch (${(prog.progress * 100).toInt()}%)...';
        });
      });

      final doc = await pipeline.execute(
        videoPath: _sourceVideoUrl,
        totalDurationMs: durationMs,
        sourceLanguage: _settings.defaultSourceLanguage,
      );
      await sub.cancel();

      if (!mounted) return;

      if (doc.isEmpty) {
        setState(() {
          _isTranslatingOnDemand = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Không tìm thấy phụ đề hoặc không trích xuất được âm thanh.'),
            duration: Duration(seconds: 3),
          ),
        );
        return;
      }

      // BƯỚC 1: Hiển thị ngay phụ đề đã dịch trên màn hình
      setState(() {
        _currentDocument = doc;
        _ttsScheduler.dispose();
        _ttsScheduler = TtsAudioScheduler(doc);
      });

      // Lưu lại vào Lịch sử
      try {
        final history = await HistoryRepository.getInstance();
        final saved = await history.saveHistory(
          videoPath: _sourceVideoUrl,
          document: doc,
          title: _originalTitle ?? _currentTitle,
        );
        if (_translatedTitle != null && _translatedTitle!.isNotEmpty) {
          await history.updateTranslatedTitle(saved.id, _translatedTitle!);
        }
      } catch (_) {}

      // BƯỚC 2: Nếu chỉ cần Vietsub (không bật lồng tiếng) -> Hoàn tất ngay
      if (!enableTts) {
        setState(() {
          _isTranslatingOnDemand = false;
          _settings.isTtsPlaybackEnabled = false;
        });
        _syncTtsWithVideo();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('🎉 Đã tạo Vietsub AI thành công!'),
              backgroundColor: Color(0xFF00AEEC),
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }

      // BƯỚC 3: Nếu chọn Lồng tiếng AI -> Tạo giọng đọc trực tiếp từ doc vừa dịch
      await _generateTtsForCurrentDocument(voice);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isTranslatingOnDemand = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Lỗi xử lý: $e'),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _generateTtsForCurrentDocument(VoiceItem voice) async {
    // 1. Liên kết các file âm thanh đã có trong cache
    await TtsCacheHelper.linkAudioFiles(_currentDocument, voice.voiceType);

    final unlinked = _currentDocument.items.where(
      (item) =>
          (item.audioFilePath == null || item.audioFilePath!.isEmpty) &&
          TtsGenerationManager.isPronounceable(item.translatedText),
    ).toList();

    if (unlinked.isEmpty) {
      // Toàn bộ các câu đã có sẵn file âm thanh
      setState(() {
        _settings.isTtsPlaybackEnabled = true;
        _ttsScheduler.dispose();
        _ttsScheduler = TtsAudioScheduler(_currentDocument);
      });
      final pos = _controller?.value.position.inMilliseconds ?? 0;
      await _ttsScheduler.onSeek(pos);
      _syncTtsWithVideo();
      await _applyAudioVolumes();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🎉 Đã bật Lồng tiếng AI (${voice.displayName})!'),
            backgroundColor: AppTheme.primaryEmerald,
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    // 2. Cần tạo file âm thanh TTS cho các câu chưa có
    setState(() {
      _isTranslatingOnDemand = true;
      _settings.isTtsPlaybackEnabled = true;
      _onDemandProgressMessage = 'Phụ đề đã có sẵn! Đang lồng tiếng AI (${voice.displayName})...';
      _onDemandProgressPct = 0.1;
    });

    final ttsManager = TtsGenerationManager();
    void onTtsProgress() {
      if (!mounted) return;
      final p = ttsManager.progress.value;
      if (p.totalCount > 0) {
        final ratio = p.completedCount / p.totalCount;
        setState(() {
          _onDemandProgressPct = ratio;
          _onDemandProgressMessage =
              'Đang lồng tiếng AI: ${p.completedCount}/${p.totalCount} câu (${(ratio * 100).toInt()}%)...';
        });
      }
    }
    ttsManager.progress.addListener(onTtsProgress);

    try {
      await ttsManager.generateAll(
        document: _currentDocument,
        voice: voice,
        threadCount: _settings.ttsThreadCount,
      );
      await TtsCacheHelper.linkAudioFiles(_currentDocument, voice.voiceType);
      if (mounted) {
        setState(() {
          _ttsScheduler.dispose();
          _ttsScheduler = TtsAudioScheduler(_currentDocument);
        });
        final pos = _controller?.value.position.inMilliseconds ?? 0;
        await _ttsScheduler.onSeek(pos);
        _syncTtsWithVideo();
        await _applyAudioVolumes();
      }

      try {
        final history = await HistoryRepository.getInstance();
        await history.saveHistory(
          videoPath: _sourceVideoUrl,
          document: _currentDocument,
          title: _originalTitle ?? _currentTitle,
          ttsVoice: voice.displayName,
        );
      } catch (_) {}

      if (mounted) {
        setState(() {
          _isTranslatingOnDemand = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🎉 Đã hoàn tất Lồng tiếng AI (${voice.displayName})!'),
            backgroundColor: AppTheme.primaryEmerald,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isTranslatingOnDemand = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Lỗi tạo giọng đọc: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      ttsManager.progress.removeListener(onTtsProgress);
    }
  }

  bool _isGenericTitle(String? t) {
    if (t == null || t.trim().isEmpty) return true;
    final clean = t.trim().toLowerCase();
    return clean == 'video' ||
        clean == 'video.mp4' ||
        clean == 'video import' ||
        clean.startsWith('video online') ||
        (clean.startsWith('bili_') && clean.endsWith('.mp4')) ||
        (clean.startsWith('video_') && clean.endsWith('.mp4')) ||
        (clean.startsWith('hg_') && clean.endsWith('.mp4'));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PipManager.initialize();
    PipManager.isInPipMode.addListener(_onPipModeChanged);
    PipManager.lastPipAction.addListener(_onPipActionReceived);
    _currentEpisodeIndex = widget.currentEpisodeIndex ?? 1;
    _sourceVideoUrl = widget.videoPath;
    _currentVideoPath = widget.videoPath;
    _currentTitle = widget.title ?? widget.bilibiliItem?.title ?? '';
    _originalTitle = _currentTitle;
    _currentDocument = widget.document ?? SubtitleDocument();

    _coverUrl = widget.coverUrl ?? widget.bilibiliItem?.cover;
    _authorName = widget.author ?? widget.bilibiliItem?.author;
    _upFaceUrl = widget.bilibiliItem?.upFace;
    _bilibiliItem = widget.bilibiliItem;

    if (_bilibiliItem != null) {
      _bilibiliDetails = BilibiliVideoDetails(
        bvid: _bilibiliItem!.bvid ?? '',
        aid: 0,
        cid: 0,
        title: _bilibiliItem!.title,
        rawTitle: _bilibiliItem!.title,
        coverUrl: _bilibiliItem!.cover.isNotEmpty ? _bilibiliItem!.cover : null,
        durationSeconds: _bilibiliItem!.durationSeconds,
        author: _bilibiliItem!.author,
        upFace: _bilibiliItem!.upFace.isNotEmpty ? _bilibiliItem!.upFace : null,
        viewCountText: _bilibiliItem!.viewCountText,
        danmakuText: _bilibiliItem!.danmakuText,
      );
    }

    final initialBvid = widget.bilibiliItem?.bvid ??
        RegExp(r'BV[a-zA-Z0-9]+', caseSensitive: false).firstMatch(widget.videoPath)?.group(0);
    if (initialBvid != null && initialBvid.isNotEmpty) {
      _loadRelatedVideos(initialBvid);
    }

    if (widget.dramaDetail != null) {
      _prefetchManager = HongguoPrefetchManager(widget.dramaDetail!);
      _prefetchManager!.registerVideoUrl(_currentEpisodeIndex, widget.videoPath);
      if (_currentDocument.isNotEmpty) {
        _prefetchManager!.registerDocument(_currentEpisodeIndex, _currentDocument);
      }
    }

    _ttsScheduler = TtsAudioScheduler(_currentDocument);

    _initSettingsAndPlayer();
  }

  void _onPipModeChanged() {
    if (mounted) {
      if (PipManager.isInPipMode.value) {
        _pipShowControls = true;
        _startPipControlsTimer();
      }
      setState(() {});
    }
  }

  void _onPipActionReceived() {
    final action = PipManager.lastPipAction.value;
    final controller = _controller;
    if (action == null || controller == null || !controller.value.isInitialized) return;
    if (action == 'playPause') {
      if (controller.value.isPlaying) {
        controller.pause();
        _ttsScheduler.onSeek(_currentPosMs);
      } else {
        controller.play();
        _syncTtsWithVideo();
      }
      unawaited(PipManager.updatePipActions(isPlaying: controller.value.isPlaying));
      _startPipControlsTimer();
      if (mounted) setState(() {});
    } else if (action == 'rewind') {
      _skipBy(-10000);
      _triggerDoubleTapFeedback(isLeft: true);
      _startPipControlsTimer();
    } else if (action == 'forward') {
      _skipBy(10000);
      _triggerDoubleTapFeedback(isLeft: false);
      _startPipControlsTimer();
    }
  }

  void _startPipControlsTimer() {
    _pipControlsTimer?.cancel();
    _pipControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _pipShowControls) {
        setState(() {
          _pipShowControls = false;
        });
      }
    });
  }

  void _togglePipControls() {
    setState(() {
      _pipShowControls = !_pipShowControls;
      if (_pipShowControls) {
        _startPipControlsTimer();
      } else {
        _pipControlsTimer?.cancel();
      }
    });
  }

  String get _pipRatioLabel {
    switch (_pipSizeRatioIndex) {
      case 1:
        return '16:9';
      case 2:
        return '4:3';
      case 3:
        return 'Fill';
      default:
        return 'Gốc';
    }
  }

  Future<void> _cyclePipAspectRatio() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    _pipSizeRatioIndex = (_pipSizeRatioIndex + 1) % 4;
    int w = 16;
    int h = 9;
    if (_pipSizeRatioIndex == 0) {
      w = controller.value.size.width.toInt();
      h = controller.value.size.height.toInt();
      _pipZoomScale = 1.0;
    } else if (_pipSizeRatioIndex == 1) {
      w = 16;
      h = 9;
      _pipZoomScale = 1.0;
    } else if (_pipSizeRatioIndex == 2) {
      w = 4;
      h = 3;
      _pipZoomScale = 1.0;
    } else if (_pipSizeRatioIndex == 3) {
      w = 21;
      h = 9;
      _pipZoomScale = 1.25;
    }
    await PipManager.updatePipAspectRatio(
      width: w > 0 ? w : 16,
      height: h > 0 ? h : 9,
    );
    _startPipControlsTimer();
    if (mounted) setState(() {});
  }

  void _triggerDoubleTapFeedback({required bool isLeft}) {
    _pipFeedbackTimer?.cancel();
    setState(() {
      if (isLeft) {
        _pipDoubleTapLeft = true;
        _pipDoubleTapRight = false;
      } else {
        _pipDoubleTapLeft = false;
        _pipDoubleTapRight = true;
      }
    });
    _pipFeedbackTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) {
        setState(() {
          _pipDoubleTapLeft = false;
          _pipDoubleTapRight = false;
        });
      }
    });
  }

  Future<void> _enterPipMode() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (Platform.isIOS) {
      if (widget.isGlobalPlayer) {
        GlobalPlayerManager.instance.minimize();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Đã thu nhỏ video (Mini-Player) trong ứng dụng.'),
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Hệ điều hành iOS chỉ hỗ trợ thu nhỏ trình phát bên trong ứng dụng.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    final w = controller.value.size.width.toInt();
    final h = controller.value.size.height.toInt();
    final isPlaying = controller.value.isPlaying;
    final ok = await PipManager.enterPip(
      width: w > 0 ? w : 16,
      height: h > 0 ? h : 9,
      isPlaying: isPlaying,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Thiết bị không hỗ trợ hoặc chưa cấp quyền Picture-in-Picture (PiP).'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }


  Future<void> _initSettingsAndPlayer() async {
    _settings = await SettingsRepository.getInstance();
    _settings.backgroundPlayEnabled = true; // Luôn tự động bật phát âm thanh nền
    if (widget.initialTtsEnabled != null) {
      _settings.isTtsPlaybackEnabled = widget.initialTtsEnabled!;
    }
    if (mounted) {
      setState(() {
        _autoPlayNextEpisode = _settings.autoPlayNextEpisode;
        _commentTranslationEngine = _settings.commentTranslationEngine;
        if (widget.dramaDetail != null) {
          _playbackSpeed = _settings.hongguoPlaybackSpeed;
        }
      });
    }

    try {
      final history = await HistoryRepository.getInstance();
      final bvid = RegExp(r'BV[a-zA-Z0-9]+', caseSensitive: false).firstMatch(_sourceVideoUrl)?.group(0);
      final item = history.getHistory().where((h) {
        if (h.videoPath == _sourceVideoUrl || h.videoPath == _currentVideoPath) return true;
        if (bvid != null && h.videoPath.contains(bvid)) return true;
        return false;
      }).firstOrNull;

      if (item != null) {
        _originalTitle = item.displayOriginalTitle;
        _translatedTitle = item.displayTranslatedTitle;
      } else {
        _originalTitle = _currentTitle;
      }
    } catch (_) {}

    // Khởi tạo HongguoPrefetchManager nếu có thông tin phim bộ
    if (widget.dramaDetail != null) {
      if (_prefetchManager == null) {
        _prefetchManager = HongguoPrefetchManager(widget.dramaDetail!);
        _prefetchManager!.registerVideoUrl(_currentEpisodeIndex, widget.videoPath);
        if (_currentDocument.isNotEmpty) {
          _prefetchManager!.registerDocument(_currentEpisodeIndex, _currentDocument);
        }
      }
      unawaited(_prefetchManager!.preloadFromHistory());

      // Kích hoạt dịch ngay tập hiện tại (nếu trống) và gối đầu tập tiếp theo
      _prefetchManager!.onEpisodePlaying(
        _currentEpisodeIndex,
        translateCurrentIfEmpty: _currentDocument.isEmpty,
        onCurrentSubtitleReady: (newDoc) async {
          if (!mounted || _currentEpisodeIndex != (widget.currentEpisodeIndex ?? 1)) {
            return;
          }
          final isPlaying = _controller?.value.isPlaying ?? false;
          setState(() {
            _currentDocument = newDoc;
            _ttsScheduler.dispose();
            _ttsScheduler = TtsAudioScheduler(newDoc);
          });
          await _applyAudioVolumes();
          if (isPlaying) {
            if (_settings.isTtsPlaybackEnabled) {
              final pos = _controller?.value.position.inMilliseconds ?? 0;
              await _ttsScheduler.onSeek(pos);
              _syncTtsWithVideo();
            }
          } else {
            await _controller?.play();
            if (_playbackSpeed != 1.0) {
              try {
                await _controller?.setPlaybackSpeed(_playbackSpeed);
              } catch (_) {}
            }
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
    bool refreshHongguoUrl = true,
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
        _bilibiliDetails = details;
        if (_originalTitle == null || _originalTitle!.isEmpty || _isGenericTitle(_originalTitle)) {
          _originalTitle = details.title;
        }
        if (_currentTitle.isEmpty || _isGenericTitle(_currentTitle)) {
          _currentTitle = _showTranslatedTitle && _translatedTitle != null
              ? _translatedTitle!
              : details.title;
          if (mounted) setState(() {});
        }
        try {
          final history = await HistoryRepository.getInstance();
          await history.updateTitleForVideo(_sourceVideoUrl, details.title);
          await history.updateTitleForVideo(targetPath, details.title);
          if (details.coverUrl != null && details.coverUrl!.isNotEmpty) {
            await history.updateCoverForVideo(_sourceVideoUrl, details.coverUrl!);
            await history.updateCoverForVideo(targetPath, details.coverUrl!);
          }
        } catch (_) {}

        // Ưu tiên nạp video từ cache nếu đã tải về trước đó
        final cached = await VideoCacheManager.findCachedFile(
          url: targetPath,
          bvid: details.bvid,
          bilibiliPage: details.selectedPageIndex,
        );
        if (cached != null && await cached.exists() && await cached.length() > 1024 * 100) {
          targetPath = cached.path;
          playableUrls = [cached.path];
          _loadRelatedVideos(details.bvid);
          _loadBilibiliUploaderInfo(details);
          _loadBilibiliComments(details.aid, reset: true);
        } else {
          playableUrls = await resolver.getMuxedVideoUrls(
            details,
            _settings.bilibiliSessData,
            _settings.preferredVideoQuality,
          );
          targetPath = playableUrls.first;
          httpHeaders = BilibiliResolver.streamHeaders(
            _settings.bilibiliSessData,
          );
          _currentQualityKey = _settings.preferredVideoQuality;
          _loadRelatedVideos(details.bvid);
          _loadBilibiliUploaderInfo(details);
          _loadBilibiliComments(details.aid, reset: true);
        }
      } else if (widget.dramaDetail != null) {
        _bilibiliDetails = null;
        // Ưu tiên nạp video từ cache nếu đã tải về máy trước đó
        final cached = await VideoCacheManager.findCachedFile(
          url: targetPath,
          seriesId: widget.dramaDetail?.seriesId,
          episodeIndex: _currentEpisodeIndex,
        );
        if (cached != null && await cached.exists() && await cached.length() > 1024 * 50) {
          debugPrint('[Player] Tìm thấy video Hồng Quả offline trong cache: ${cached.path}');
          targetPath = cached.path;
          playableUrls = [cached.path];
        } else if (refreshHongguoUrl &&
            !targetPath.contains('hf.space') &&
            (targetPath.startsWith('http://') || targetPath.startsWith('https://'))) {
          // Nếu không có trong cache và URL là online:
          // Đề phòng URL online bị hết hạn từ hôm qua, tự động lấy link mới còn hạn
          try {
            final resolver = HongguoResolver();
            final detail = widget.dramaDetail!;
            var vid = '';
            if (detail.episodes.isNotEmpty && _currentEpisodeIndex <= detail.episodes.length) {
              vid = detail.episodes[_currentEpisodeIndex - 1].vid;
            }
            final freshUrl = await resolver.getEpisodePlayUrl(
              detail.seriesId,
              vid.isNotEmpty ? vid : detail.seriesId,
              episodeIndex: _currentEpisodeIndex,
            );
            if (freshUrl.isNotEmpty && freshUrl.startsWith('http')) {
              targetPath = freshUrl;
              playableUrls = [freshUrl];
              try {
                final history = await HistoryRepository.getInstance();
                await history.updateVideoPath(_sourceVideoUrl, freshUrl);
              } catch (_) {}
            }
          } catch (e) {
            debugPrint('[Player] Không thể re-resolve URL mới cho tập $_currentEpisodeIndex: $e');
          }
        }
      } else {
        _bilibiliDetails = null;
        if (targetPath.startsWith('http://') || targetPath.startsWith('https://')) {
          final cached = await VideoCacheManager.findCachedFile(url: targetPath);
          if (cached != null && await cached.exists() && await cached.length() > 1024 * 100) {
            targetPath = cached.path;
            playableUrls = [cached.path];
          }
        }
      }

      _currentVideoPath = targetPath;

      final isRemote =
          targetPath.startsWith('http://') || targetPath.startsWith('https://');
      final videoOptions = VideoPlayerOptions(
        mixWithOthers: true,
        allowBackgroundPlayback: true,
      );
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
        await _controller!.initialize().timeout(_videoInitializeTimeout);
      } else {
        _controller = VideoPlayerController.file(
          File(targetPath),
          videoPlayerOptions: videoOptions,
        );
        await _controller!.initialize().timeout(_videoInitializeTimeout);
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
      setState(() {
        _isInitialized = true;
      });
      final detail = widget.dramaDetail;
      if (detail != null && detail.seriesId.isNotEmpty) {
        unawaited(
          HistoryRepository.getInstance().then(
            (history) => history.markSeriesEpisodeWatched(
              seriesId: detail.seriesId,
              episodeIndex: _currentEpisodeIndex,
              seriesTitle: detail.title,
            ),
          ).catchError((_) => false),
        );
      }
      final isLocalVideo = !targetPath.startsWith('http://') && !targetPath.startsWith('https://');
      // Nếu video là file cục bộ (đã tải về máy) -> phát ngay, không chờ dịch
      final bool shouldWaitHongguoTranslation = widget.dramaDetail != null &&
          _currentDocument.isEmpty &&
          !_userChosePlayRaw &&
          !isLocalVideo;

      // Thiết lập tốc độ phát đã chọn cho controller mới (kể cả khi chuyển tập)
      if (_playbackSpeed != 1.0) {
        try {
          await _controller!.setPlaybackSpeed(_playbackSpeed);
        } catch (e) {
          debugPrint('Không thể thiết lập tốc độ phát $_playbackSpeed cho controller mới: $e');
        }
      }

      if (!shouldWaitHongguoTranslation) {
        await _controller!.play();
      } else {
        await _controller!.pause();
      }

      // Củng cố lại tốc độ phát sau khi phát video
      if (_playbackSpeed != 1.0) {
        try {
          await _controller!.setPlaybackSpeed(_playbackSpeed);
        } catch (_) {}
      }

      // Khởi động các tác vụ phụ chạy ngầm bất đồng bộ song song
      unawaited(_calibratePlaybackSpeeds());
      unawaited(_applyAudioVolumes());
      unawaited(_ttsScheduler.warmUp(resumePositionMs));
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
      } else {
        _syncTtsWithVideo();
      }
    } catch (e) {
      if (!mounted) return;
      final failedController = _controller;
      _controller = null;
      if (failedController != null) {
        try {
          await failedController.dispose();
        } catch (_) {}
      }
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
        await controller.initialize().timeout(_videoInitializeTimeout);
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

    final previousIndex = _currentEpisodeIndex;

    try {
      await _persistPlaybackPosition(force: true);
      final playUrl = await _prefetchManager?.getOrResolveUrl(targetIndex);
      if (playUrl == null) {
        if (mounted) {
          setState(() => _isSwitchingEpisode = false);
          final maxAcc = widget.dramaDetail?.accessibleEpisodes ?? 3;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Tập $targetIndex chưa có sẵn trên web Hồng Quả (web chỉ mở xem trước $maxAcc tập đầu, các tập sau xem trên app chính thức).',
              ),
              backgroundColor: Colors.orangeAccent.shade700,
            ),
          );
        }
        return;
      }
      if (!mounted) return;

      var doc = _prefetchManager?.getCachedDocument(targetIndex);
      if (doc == null || doc.isEmpty) {
        doc = await _prefetchManager?.findDocumentInHistory(targetIndex);
      }
      final epTitle = '${widget.dramaDetail!.title} - Tập $targetIndex';

      _currentEpisodeIndex = targetIndex;
      await _switchVideo(
        newVideoPath: playUrl,
        newDocument: doc ?? SubtitleDocument(),
        newTitle: epTitle,
      );

      // Tự động xóa tập cũ cách 3 tập nếu người dùng xem tuần tự (+1)
      // Ví dụ: Xem đến tập 4 xóa tập 1, tập 5 xóa tập 2... Nếu nhảy cóc thì không xóa
      if (_settings.hongguoAutoDeleteWatched && widget.dramaDetail != null) {
        if (targetIndex == previousIndex + 1) {
          final epToDelete = targetIndex - 3;
          if (epToDelete >= 1) {
            unawaited(
              VideoCacheManager.deleteHongguoEpisodeCache(
                seriesId: widget.dramaDetail!.seriesId,
                episodeIndex: epToDelete,
              ),
            );
          }
        }
      }

      // Kích hoạt dịch gối đầu tập tiếp theo
      _prefetchManager?.onEpisodePlaying(
        targetIndex,
        translateCurrentIfEmpty: doc == null,
        onCurrentSubtitleReady: (newDoc) async {
          if (!mounted || _currentEpisodeIndex != targetIndex) return;
          final isPlaying = _controller?.value.isPlaying ?? false;
          setState(() {
            _currentDocument = newDoc;
            _ttsScheduler.dispose();
            _ttsScheduler = TtsAudioScheduler(newDoc);
          });
          await _applyAudioVolumes();
          if (isPlaying) {
            if (_settings.isTtsPlaybackEnabled) {
              final pos = _controller?.value.position.inMilliseconds ?? 0;
              await _ttsScheduler.onSeek(pos);
              _syncTtsWithVideo();
            }
          } else {
            await _controller?.play();
            if (_playbackSpeed != 1.0) {
              try {
                await _controller?.setPlaybackSpeed(_playbackSpeed);
              } catch (_) {}
            }
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
                    final isAccessible = ep <= detail.accessibleEpisodes;

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
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '$ep',
                                  style: TextStyle(
                                    color: isPlaying
                                        ? AppTheme.primaryEmerald
                                        : (isAccessible ? Colors.white : Colors.white38),
                                    fontWeight: isPlaying ? FontWeight.bold : FontWeight.w500,
                                    fontSize: 13,
                                  ),
                                ),
                                if (!isAccessible) ...[
                                  const SizedBox(width: 2),
                                  const Icon(
                                    Icons.lock_outline_rounded,
                                    size: 10,
                                    color: Colors.white38,
                                  ),
                                ],
                              ],
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

  void _copyTitleToClipboard(String title) {
    if (title.trim().isEmpty) return;
    Clipboard.setData(ClipboardData(text: title.trim()));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(
              Icons.check_circle,
              color: AppTheme.primaryEmerald,
              size: 16,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Đã sao chép: "${title.trim()}"',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _togglePlayerTitleTranslation() async {
    if (_showTranslatedTitle) {
      setState(() {
        _showTranslatedTitle = false;
        _currentTitle = (_originalTitle != null && _originalTitle!.isNotEmpty)
            ? _originalTitle!
            : _currentTitle;
      });
      return;
    }

    if (_translatedTitle != null && _translatedTitle!.isNotEmpty) {
      setState(() {
        _showTranslatedTitle = true;
        _currentTitle = _translatedTitle!;
      });
      return;
    }

    setState(() {
      _isTranslatingTitle = true;
    });

    try {
      final toTranslate = (_originalTitle != null && _originalTitle!.isNotEmpty)
          ? _originalTitle!
          : _currentTitle;
      final translated = await TitleTranslator.translateTitle(toTranslate);
      if (translated != null && translated.isNotEmpty) {
        if (_originalTitle == null || _originalTitle!.isEmpty) {
          _originalTitle = _currentTitle;
        }
        _translatedTitle = translated;
        _currentTitle = translated;
        _showTranslatedTitle = true;
        try {
          final history = await HistoryRepository.getInstance();
          await history.updateTranslatedTitle(_sourceVideoUrl, translated);
          await history.updateTranslatedTitle(_currentVideoPath, translated);
        } catch (_) {}
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Không thể dịch tiêu đề lúc này. Vui lòng thử lại!'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isTranslatingTitle = false;
        });
      }
    }
  }

  List<BilibiliAnimeItem> get _displayedRelatedVideos {
    final currentAuthor = _authorName ?? _bilibiliDetails?.author ?? _bilibiliItem?.author ?? '';
    switch (_selectedRelatedTab) {
      case 'same_author':
        if (currentAuthor.isEmpty) return _blendedRelatedVideos;
        final list = _blendedRelatedVideos
            .where((it) => it.author.trim() == currentAuthor.trim())
            .toList();
        if (list.isNotEmpty) return list;
        final fromRelated = _rawDirectRelated
            .where((it) => it.author.trim() == currentAuthor.trim())
            .toList();
        return fromRelated.isNotEmpty ? fromRelated : _blendedRelatedVideos;
      case 'related':
        return _rawDirectRelated.isNotEmpty ? _rawDirectRelated : _blendedRelatedVideos;
      case 'explore':
        final explore = <BilibiliAnimeItem>[];
        final seen = <String>{};
        final curBvid = _bilibiliDetails?.bvid ?? _bilibiliItem?.bvid ?? _lastLoadedRelatedBvid ?? '';
        if (curBvid.isNotEmpty) seen.add(curBvid);
        for (final it in [..._rawRecommendFeed, ..._rawPopularVideos]) {
          if (it.bvid != null && it.bvid!.isNotEmpty && seen.add(it.bvid!)) {
            explore.add(it);
          }
        }
        return explore.isNotEmpty ? explore : _blendedRelatedVideos;
      case 'blended':
      default:
        return _blendedRelatedVideos;
    }
  }

  Future<void> _loadRelatedVideos(String bvid) async {
    if (bvid.isEmpty) return;
    if (_lastLoadedRelatedBvid == bvid && _blendedRelatedVideos.isNotEmpty) return;
    _lastLoadedRelatedBvid = bvid;
    if (mounted) {
      setState(() {
        _isLoadingRelated = true;
        _rawDirectRelated = [];
        _rawRecommendFeed = [];
        _rawPopularVideos = [];
        _blendedRelatedVideos = [];
        _selectedRelatedTab = 'blended';
      });
    }
    try {
      final settings = await SettingsRepository.getInstance();
      final resolver = BilibiliResolver();
      final cookie = settings.bilibiliSessData;

      // Nạp song song: Liên quan trực tiếp, Đề xuất AI/Feed cá nhân hóa, và Thịnh hành
      final results = await Future.wait([
        resolver.getRelatedVideos(bvid, cookie: cookie).catchError((_) => <BilibiliAnimeItem>[]),
        resolver.getRecommendFeed(pageSize: 15, freshIdx: _recommendFreshIdx, cookie: cookie).catchError((_) => <BilibiliAnimeItem>[]),
        resolver.getPopularVideos(page: 1, pageSize: 12, cookie: cookie).catchError((_) => <BilibiliAnimeItem>[]),
      ]);

      final related = results[0];
      final feed = results[1];
      final popular = results[2];

      final currentAuthor = _authorName ?? _bilibiliDetails?.author ?? _bilibiliItem?.author ?? '';
      final blended = _blendRecommendations(
        currentBvid: bvid,
        currentAuthor: currentAuthor,
        related: related,
        feed: feed,
        popular: popular,
      );

      if (mounted) {
        setState(() {
          _rawDirectRelated = related;
          _rawRecommendFeed = feed;
          _rawPopularVideos = popular;
          _blendedRelatedVideos = blended;
          _isLoadingRelated = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoadingRelated = false;
        });
      }
    }
  }

  Future<void> _refreshRecommendations() async {
    final bvid = _bilibiliDetails?.bvid ??
        _bilibiliItem?.bvid ??
        _lastLoadedRelatedBvid ??
        '';
    if (bvid.isEmpty || _isRefreshingRelated) return;
    if (mounted) {
      setState(() {
        _isRefreshingRelated = true;
      });
    }
    try {
      _recommendFreshIdx++;
      final settings = await SettingsRepository.getInstance();
      final resolver = BilibiliResolver();
      final cookie = settings.bilibiliSessData;

      final popularPage = (_recommendFreshIdx % 5) + 1;
      final results = await Future.wait([
        resolver.getRecommendFeed(pageSize: 16, freshIdx: _recommendFreshIdx, cookie: cookie).catchError((_) => <BilibiliAnimeItem>[]),
        resolver.getPopularVideos(page: popularPage, pageSize: 12, cookie: cookie).catchError((_) => <BilibiliAnimeItem>[]),
      ]);

      final feed = results[0];
      final popular = results[1];

      final currentAuthor = _authorName ?? _bilibiliDetails?.author ?? _bilibiliItem?.author ?? '';
      final blended = _blendRecommendations(
        currentBvid: bvid,
        currentAuthor: currentAuthor,
        related: _rawDirectRelated,
        feed: feed,
        popular: popular,
      );

      if (mounted) {
        setState(() {
          _rawRecommendFeed = feed;
          _rawPopularVideos = popular;
          _blendedRelatedVideos = blended;
          _isRefreshingRelated = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isRefreshingRelated = false;
        });
      }
    }
  }

  Future<void> _loadMoreRecommendations() async {
    final bvid = _bilibiliDetails?.bvid ??
        _bilibiliItem?.bvid ??
        _lastLoadedRelatedBvid ??
        '';
    if (bvid.isEmpty || _isLoadingMoreRelated) return;
    if (mounted) {
      setState(() {
        _isLoadingMoreRelated = true;
      });
    }
    try {
      _recommendFreshIdx++;
      final settings = await SettingsRepository.getInstance();
      final resolver = BilibiliResolver();
      final cookie = settings.bilibiliSessData;

      final moreFeed = await resolver.getRecommendFeed(
        pageSize: 15,
        freshIdx: _recommendFreshIdx,
        cookie: cookie,
      ).catchError((_) => <BilibiliAnimeItem>[]);

      if (mounted && moreFeed.isNotEmpty) {
        final existingBvids = _blendedRelatedVideos.map((e) => e.bvid).whereType<String>().toSet();
        existingBvids.add(bvid);

        final newItems = moreFeed.where((it) => it.bvid != null && it.bvid!.isNotEmpty && !existingBvids.contains(it.bvid!)).toList();

        setState(() {
          _rawRecommendFeed.addAll(newItems);
          _blendedRelatedVideos.addAll(newItems);
          _isLoadingMoreRelated = false;
        });
      } else if (mounted) {
        setState(() {
          _isLoadingMoreRelated = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoadingMoreRelated = false;
        });
      }
    }
  }

  List<BilibiliAnimeItem> _blendRecommendations({
    required String currentBvid,
    required String currentAuthor,
    required List<BilibiliAnimeItem> related,
    required List<BilibiliAnimeItem> feed,
    required List<BilibiliAnimeItem> popular,
  }) {
    final result = <BilibiliAnimeItem>[];
    final seenBvids = <String>{currentBvid};

    // 1. Phân nhóm video liên quan
    final sameAuthorList = <BilibiliAnimeItem>[];
    final directRelatedList = <BilibiliAnimeItem>[];

    for (final item in related) {
      final b = item.bvid;
      if (b == null || b.isEmpty || seenBvids.contains(b)) continue;
      if (currentAuthor.isNotEmpty && item.author.trim() == currentAuthor.trim()) {
        sameAuthorList.add(item);
      } else {
        directRelatedList.add(item);
      }
    }

    // 2. Gom video khám phá / xu hướng
    final exploreList = <BilibiliAnimeItem>[];
    for (final item in [...feed, ...popular]) {
      final b = item.bvid;
      if (b == null || b.isEmpty || seenBvids.contains(b)) continue;
      exploreList.add(item);
    }

    // 3. Trộn thông minh (YouTube / Bilibili interleave ratio):
    // 2 video liên quan (hoặc 1 cùng kênh + 1 liên quan) -> 1 video khám phá -> 2 liên quan -> 1 khám phá...
    var rIdx = 0;
    var sIdx = 0;
    var eIdx = 0;

    while (rIdx < directRelatedList.length || sIdx < sameAuthorList.length || eIdx < exploreList.length) {
      var addedRelated = 0;
      if (sIdx < sameAuthorList.length && (result.isEmpty || sIdx < 2)) {
        final it = sameAuthorList[sIdx++];
        if (seenBvids.add(it.bvid!)) {
          result.add(it);
          addedRelated++;
        }
      }
      while (rIdx < directRelatedList.length && addedRelated < 2) {
        final it = directRelatedList[rIdx++];
        if (seenBvids.add(it.bvid!)) {
          result.add(it);
          addedRelated++;
        }
      }

      // Xen 1 video khám phá / đề xuất rộng
      if (eIdx < exploreList.length) {
        final it = exploreList[eIdx++];
        if (seenBvids.add(it.bvid!)) {
          result.add(it);
        }
      }

      // Xử lý nốt nếu 1 trong các nguồn cạn
      if (rIdx >= directRelatedList.length && sIdx >= sameAuthorList.length) {
        while (eIdx < exploreList.length) {
          final it = exploreList[eIdx++];
          if (seenBvids.add(it.bvid!)) result.add(it);
        }
        break;
      }
      if (eIdx >= exploreList.length) {
        while (sIdx < sameAuthorList.length) {
          final it = sameAuthorList[sIdx++];
          if (seenBvids.add(it.bvid!)) result.add(it);
        }
        while (rIdx < directRelatedList.length) {
          final it = directRelatedList[rIdx++];
          if (seenBvids.add(it.bvid!)) result.add(it);
        }
        break;
      }
    }

    return result;
  }

  Future<void> _showQualitySelectionSheet() async {
    final details = _bilibiliDetails;
    if (details == null) return;

    final qualities = [
      {
        'key': '80',
        'title': '1080p (Full HD)',
        'subtitle': 'Độ nét cao nhất, xem đã mắt',
        'badge': 'VIP / SESSDATA',
      },
      {
        'key': '64',
        'title': '720p (HD - Chuẩn)',
        'subtitle': 'Cân bằng tối ưu giữa độ nét và mượt mà',
        'badge': 'Chuẩn',
      },
      {
        'key': '32',
        'title': '480p (Tiết kiệm)',
        'subtitle': 'Dung lượng nhẹ, phù hợp mạng yếu / 4G',
        'badge': null,
      },
      {
        'key': '16',
        'title': '360p (Siêu nhẹ)',
        'subtitle': 'Tải siêu tốc, tốn rất ít dữ liệu mạng',
        'badge': null,
      },
    ];

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF1E202A),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(left: 4, bottom: 12),
                child: Row(
                  children: [
                    Icon(Icons.high_quality_rounded, color: Color(0xFF00AEEC), size: 22),
                    SizedBox(width: 8),
                    Text(
                      'Chọn chất lượng video Bilibili',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              ...qualities.map((q) {
                final isSelected = q['key'] == _currentQualityKey;
                return ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  tileColor: isSelected ? const Color(0xFF00AEEC).withValues(alpha: 0.15) : null,
                  leading: Icon(
                    isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                    color: isSelected ? const Color(0xFF00AEEC) : Colors.white38,
                  ),
                  title: Row(
                    children: [
                      Text(
                        q['title']!,
                        style: TextStyle(
                          color: isSelected ? const Color(0xFF00AEEC) : Colors.white,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      if (q['badge'] != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: q['badge'] == 'VIP / SESSDATA'
                                ? const Color(0xFFFB7299).withValues(alpha: 0.2)
                                : Colors.white12,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: q['badge'] == 'VIP / SESSDATA'
                                  ? const Color(0xFFFB7299)
                                  : Colors.white24,
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            q['badge']!,
                            style: TextStyle(
                              color: q['badge'] == 'VIP / SESSDATA'
                                  ? const Color(0xFFFB7299)
                                  : Colors.white70,
                              fontSize: 9.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    q['subtitle']!,
                    style: const TextStyle(color: Colors.white54, fontSize: 11.5),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    if (q['key'] != _currentQualityKey) {
                      _switchBilibiliQuality(q['key']!);
                    }
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Future<void> _switchBilibiliQuality(String newQuality) async {
    final details = _bilibiliDetails;
    final controller = _controller;
    if (details == null || controller == null) return;

    final currentPositionMs = _currentPosMs;
    final wasPlaying = controller.value.isPlaying;

    setState(() {
      _isSwitchingQuality = true;
    });

    try {
      final resolver = BilibiliResolver();
      final urls = await resolver.getMuxedVideoUrls(
        details,
        _settings.bilibiliSessData,
        newQuality,
      );
      if (urls.isEmpty) throw Exception('Không lấy được luồng video cho chất lượng này');
      final newUrl = urls.first;
      final headers = BilibiliResolver.requestHeaders(_settings.bilibiliSessData);

      _controller?.removeListener(_onPlayerUpdate);
      await _controller?.pause();
      await _controller?.dispose();

      final newController = await _initializeNetworkController(
        [newUrl],
        headers,
        VideoPlayerOptions(
          mixWithOthers: true,
          allowBackgroundPlayback: true,
        ),
      );

      if (!mounted) {
        await newController.dispose();
        return;
      }

      await newController.seekTo(Duration(milliseconds: currentPositionMs));
      if (wasPlaying) {
        await newController.play();
      }
      if (_playbackSpeed != 1.0) {
        try {
          await newController.setPlaybackSpeed(_playbackSpeed);
        } catch (_) {}
      }
      _settings.preferredVideoQuality = newQuality;
      setState(() {
        _controller = newController;
        _currentVideoPath = newUrl;
        _currentQualityKey = newQuality;
        _isSwitchingQuality = false;
      });

      _controller!.addListener(_onPlayerUpdate);
      _syncTtsWithVideo();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✨ Đã chuyển sang chất lượng $_currentQualityLabel'),
            duration: const Duration(seconds: 2),
            backgroundColor: const Color(0xFF00AEEC),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSwitchingQuality = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Không thể đổi chất lượng: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _goToBilibiliPage(int targetPage) async {
    final details = _bilibiliDetails;
    if (details == null || targetPage == details.selectedPageIndex) return;

    final newUrl = 'https://www.bilibili.com/video/${details.bvid}?p=$targetPage';
    String partTitle = 'P$targetPage';
    for (final p in details.pages) {
      if (p.page == targetPage) {
        if (p.part.isNotEmpty) partTitle = 'P$targetPage (${p.part})';
        break;
      }
    }
    final rawMain = details.rawTitle ?? details.title;
    final newTitle = '$rawMain - $partTitle';

    await _switchVideo(
      newVideoPath: newUrl,
      newDocument: SubtitleDocument(),
      newTitle: newTitle,
      newCoverUrl: details.coverUrl,
      newAuthor: details.author,
    );
  }

  Future<void> _goToBilibiliUgcEpisode(BilibiliUgcEpisode ep) async {
    final newUrl = ep.targetPlayUrl;
    await _switchVideo(
      newVideoPath: newUrl,
      newDocument: SubtitleDocument(),
      newTitle: ep.title,
      newCoverUrl: ep.cover.isNotEmpty ? ep.cover : null,
      newAuthor: _bilibiliDetails?.author,
    );
  }

  void _showAllBilibiliPagesSheet(BilibiliVideoDetails details) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.7,
          decoration: const BoxDecoration(
            color: Color(0xFF14161E),
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
                        'Danh sách các phần (${details.pages.length} phần)',
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
                      icon: const Icon(Icons.close_rounded, color: Colors.white60, size: 20),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white12, height: 1),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(14),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: 1.4,
                  ),
                  itemCount: details.pages.length,
                  itemBuilder: (ctx, i) {
                    final p = details.pages[i];
                    final isPlaying = p.page == details.selectedPageIndex;

                    return InkWell(
                      onTap: () {
                        Navigator.pop(ctx);
                        if (!isPlaying) {
                          _goToBilibiliPage(p.page);
                        }
                      },
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isPlaying
                              ? const Color(0xFFFB7299).withValues(alpha: 0.2)
                              : const Color(0xFF1E212B),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isPlaying
                                ? const Color(0xFFFB7299)
                                : Colors.white12,
                            width: isPlaying ? 1.5 : 1,
                          ),
                        ),
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isPlaying) ...[
                                  const Icon(
                                    Icons.graphic_eq_rounded,
                                    size: 14,
                                    color: Color(0xFFFB7299),
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                Text(
                                  'P${p.page}',
                                  style: TextStyle(
                                    color: isPlaying
                                        ? const Color(0xFFFB7299)
                                        : Colors.white,
                                    fontWeight: isPlaying
                                        ? FontWeight.bold
                                        : FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                            if (p.part.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                p.part,
                                style: TextStyle(
                                  color: isPlaying
                                      ? const Color(0xFFFB7299).withValues(alpha: 0.8)
                                      : Colors.white54,
                                  fontSize: 9.5,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
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

  Future<void> _loadBilibiliUploaderInfo(BilibiliVideoDetails details) async {
    final mid = details.ownerMid;
    final settings = await SettingsRepository.getInstance();
    final isFollowedLocal = settings.isBilibiliMidFollowed(mid);
    if (mounted) {
      setState(() {
        _isFollowingBilibiliUploader = isFollowedLocal;
      });
    }
    if (mid > 0) {
      final resolver = BilibiliResolver();
      final profile = await resolver.getUploaderProfile(mid, cookie: settings.bilibiliSessData);
      if (mounted) {
        setState(() {
          _bilibiliUploaderProfile = profile;
          _isFollowingBilibiliUploader = isFollowedLocal || (profile?.isFollowing ?? false);
        });
      }
    }
  }

  Future<void> _toggleBilibiliFollow() async {
    final details = _bilibiliDetails;
    final mid = details?.ownerMid ?? 0;
    if (mid <= 0 || _isTogglingBilibiliFollow) return;
    setState(() => _isTogglingBilibiliFollow = true);

    final settings = await SettingsRepository.getInstance();
    final targetFollow = !_isFollowingBilibiliUploader;
    setState(() {
      _isFollowingBilibiliUploader = targetFollow;
    });

    if (targetFollow) {
      settings.addBilibiliFollowedMid(mid);
    } else {
      settings.removeBilibiliFollowedMid(mid);
    }

    if (settings.bilibiliSessData.isNotEmpty) {
      unawaited(
        BilibiliResolver().modifyRelation(
          mid: mid,
          follow: targetFollow,
          cookie: settings.bilibiliSessData,
          csrf: settings.bilibiliBiliJct,
        ),
      );
    }

    if (mounted) {
      setState(() => _isTogglingBilibiliFollow = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            targetFollow
                ? '🎉 Đã đăng ký theo dõi "${details?.author ?? 'kênh'}"'
                : 'Đã hủy đăng ký theo dõi',
          ),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          backgroundColor: targetFollow
              ? const Color(0xFFFB7299)
              : const Color(0xFF282B37),
        ),
      );
    }
  }

  Future<void> _loadBilibiliComments(int aid, {bool reset = false}) async {
    if (aid <= 0) return;
    if (reset) {
      setState(() {
        _isLoadingBilibiliComments = true;
        _bilibiliComments.clear();
        _bilibiliCommentPage = 1;
        _hasMoreComments = true;
      });
    }
    try {
      final settings = await SettingsRepository.getInstance();
      final resolver = BilibiliResolver();
      final res = await resolver.getComments(
        aid: aid,
        page: _bilibiliCommentPage,
        pageSize: 20,
        sort: _bilibiliCommentSort,
        cookie: settings.bilibiliSessData,
      );
      if (mounted) {
        setState(() {
          _bilibiliCommentResult = res;
          if (reset) {
            _bilibiliComments = res.comments;
          } else {
            _bilibiliComments.addAll(res.comments);
          }
          _isLoadingBilibiliComments = false;
          _isLoadingMoreComments = false;
          if (res.comments.length < 15) {
            _hasMoreComments = false;
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoadingBilibiliComments = false;
          _isLoadingMoreComments = false;
        });
      }
    }
  }

  Future<void> _loadMoreBilibiliComments() async {
    final details = _bilibiliDetails;
    if (details == null || _isLoadingMoreComments || !_hasMoreComments) return;
    setState(() {
      _isLoadingMoreComments = true;
      _bilibiliCommentPage++;
    });
    await _loadBilibiliComments(details.aid, reset: false);
  }

  Future<void> _toggleCommentTranslationEngine() async {
    final next = _commentTranslationEngine == 'local' ? 'api' : 'local';
    setState(() {
      _commentTranslationEngine = next;
    });
    _settings.commentTranslationEngine = next;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                next == 'local'
                    ? Icons.phone_android_rounded
                    : Icons.auto_awesome_rounded,
                color: Colors.white,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  next == 'local'
                      ? '📱 Đã chuyển sang Dịch Local (Google ML Kit - Miễn phí, 0 token API)'
                      : '🤖 Đã chuyển sang Dịch AI (Gemini/Groq - Bắt trend, chuẩn văn phong)',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            ],
          ),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          backgroundColor: next == 'local'
              ? const Color(0xFF2E7D32)
              : const Color(0xFF0077A8),
        ),
      );
    }
  }

  Future<void> _toggleTranslateComment(int rpid, String rawText) async {
    if (_bilibiliCommentTranslations.containsKey(rpid)) {
      setState(() {
        _bilibiliCommentTranslations.remove(rpid);
      });
      return;
    }

    setState(() {
      _bilibiliTranslatingCommentIds.add(rpid);
    });

    try {
      final translated = await TitleTranslator.translateComment(
        rawText,
        engine: _commentTranslationEngine,
      );
      if (mounted && translated != null && translated.isNotEmpty) {
        setState(() {
          _bilibiliCommentTranslations[rpid] = translated;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _bilibiliTranslatingCommentIds.remove(rpid);
        });
      }
    }
  }

  Color _getBilibiliLevelColor(int level) {
    switch (level) {
      case 1:
        return const Color(0xFF999999);
      case 2:
        return const Color(0xFF5AB664);
      case 3:
        return const Color(0xFF5DB6F2);
      case 4:
        return const Color(0xFFFFB03B);
      case 5:
        return const Color(0xFFFF6600);
      case 6:
        return const Color(0xFFFF0000);
      default:
        return const Color(0xFF999999);
    }
  }

  Widget _buildBilibiliBelowContent() {
    final details = _bilibiliDetails;
    final commentCount = _bilibiliCommentResult?.totalCount ?? 0;
    final commentLabel = commentCount > 0 ? 'Bình luận $commentCount' : 'Bình luận';

    return Container(
      color: const Color(0xFF14161E),
      child: Column(
        children: [
          // 1. Thanh TabBar: 简介 (Giới thiệu) / 评论 (Bình luận)
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Colors.white12, width: 0.8)),
            ),
            child: Row(
              children: [
                _buildBilibiliTabItem(
                  index: 0,
                  label: 'Giới thiệu',
                  isSelected: _bilibiliTabIndex == 0,
                ),
                const SizedBox(width: 24),
                _buildBilibiliTabItem(
                  index: 1,
                  label: commentLabel,
                  isSelected: _bilibiliTabIndex == 1,
                ),
                const Spacer(),
                if (_bilibiliTabIndex == 0 && details != null && details.pages.length > 1)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFB7299).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: const Color(0xFFFB7299).withValues(alpha: 0.4),
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      'P${details.selectedPageIndex}/${details.pages.length}',
                      style: const TextStyle(
                        color: Color(0xFFFB7299),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // 2. Nội dung Tab (Giới thiệu hoặc Bình luận)
          Expanded(
            child: _bilibiliTabIndex == 0
                ? _buildBilibiliIntroTab(details)
                : _buildBilibiliCommentTab(details),
          ),
        ],
      ),
    );
  }

  Widget _buildBilibiliTabItem({
    required int index,
    required String label,
    required bool isSelected,
  }) {
    return InkWell(
      onTap: () {
        setState(() {
          _bilibiliTabIndex = index;
        });
      },
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isSelected ? const Color(0xFFFB7299) : Colors.transparent,
              width: 2.5,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white60,
            fontSize: 14,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildBilibiliIntroTab(BilibiliVideoDetails? details) {
    final displayTitle = _currentTitle.isNotEmpty
        ? _currentTitle
        : (widget.title ?? widget.bilibiliItem?.title ?? '');
    final author = (details != null && details.author.isNotEmpty)
        ? details.author
        : (_authorName ?? widget.author ?? widget.bilibiliItem?.author ?? '');
    final upFace = (details?.upFace != null && details!.upFace!.isNotEmpty)
        ? details.upFace
        : (_upFaceUrl ?? widget.bilibiliItem?.upFace);
    final viewCount = (details != null && details.viewCountText.isNotEmpty)
        ? details.viewCountText
        : (widget.bilibiliItem?.viewCountText ?? '');
    final danmaku = (details != null && details.danmakuText.isNotEmpty)
        ? details.danmakuText
        : (widget.bilibiliItem?.danmakuText ?? '');

    final fansText = _bilibiliUploaderProfile?.fansText.isNotEmpty == true
        ? _bilibiliUploaderProfile!.fansText
        : '';
    final videoCount = _bilibiliUploaderProfile?.videoCount ?? 0;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      children: [
        // 1. Thẻ Thông tin UP tác giả (Avatar, Tên, Fans, Video + Nút Đăng ký)
        if (author.isNotEmpty)
          InkWell(
            onTap: () {
              final mid = details?.ownerMid ?? 0;
              BilibiliUploaderSheet.show(
                context: context,
                mid: mid,
                authorName: author,
                initialAvatar: upFace,
                onSelectVideo: (item) {
                  _switchVideo(
                    newVideoPath: item.targetPlayUrl,
                    newDocument: SubtitleDocument(),
                    newTitle: item.title,
                    newCoverUrl: item.cover,
                    newAuthor: item.author,
                    newBilibiliItem: item,
                  );
                },
              );
            },
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: (upFace != null && upFace.isNotEmpty)
                        ? Image.network(
                            upFace,
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const CircleAvatar(
                              radius: 20,
                              backgroundColor: Color(0xFF282B37),
                              child: Icon(Icons.person, size: 22, color: Colors.white54),
                            ),
                          )
                        : const CircleAvatar(
                            radius: 20,
                            backgroundColor: Color(0xFF282B37),
                            child: Icon(Icons.person, size: 22, color: Colors.white54),
                          ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          author,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            if (fansText.isNotEmpty) ...[
                              Text(
                                '$fansText fans',
                                style: const TextStyle(color: Colors.white60, fontSize: 11),
                              ),
                              if (videoCount > 0)
                                const Text(' • ', style: TextStyle(color: Colors.white38)),
                            ],
                            if (videoCount > 0)
                              Text(
                                '$videoCount video',
                                style: const TextStyle(color: Colors.white60, fontSize: 11),
                              )
                            else if (fansText.isEmpty && viewCount.isNotEmpty)
                              Text(
                                '$viewCount lượt xem',
                                style: const TextStyle(color: Colors.white54, fontSize: 11),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // Nút Đăng ký / Theo dõi (+ 关注)
                  InkWell(
                    onTap: _toggleBilibiliFollow,
                    borderRadius: BorderRadius.circular(16),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: _isFollowingBilibiliUploader
                            ? Colors.white12
                            : const Color(0xFFFB7299),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: _isFollowingBilibiliUploader
                              ? Colors.white24
                              : const Color(0xFFFB7299),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!_isFollowingBilibiliUploader) ...[
                            const Icon(Icons.add, color: Colors.white, size: 13),
                            const SizedBox(width: 3),
                          ],
                          Text(
                            _isFollowingBilibiliUploader ? 'Đã theo dõi' : 'Theo dõi',
                            style: TextStyle(
                              color: _isFollowingBilibiliUploader
                                  ? Colors.white70
                                  : Colors.white,
                              fontSize: 11.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 10),

        // 2. Tiêu đề video & nút Dịch
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                displayTitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  height: 1.3,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: _isTranslatingTitle ? null : _togglePlayerTitleTranslation,
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _showTranslatedTitle
                      ? AppTheme.primaryEmerald.withValues(alpha: 0.25)
                      : Colors.white12,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: _showTranslatedTitle
                        ? AppTheme.primaryEmerald.withValues(alpha: 0.5)
                        : Colors.white24,
                  ),
                ),
                child: _isTranslatingTitle
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.translate_rounded,
                            size: 13,
                            color: _showTranslatedTitle
                                ? AppTheme.primaryEmerald
                                : Colors.white,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _showTranslatedTitle ? 'Gốc' : 'Dịch',
                            style: TextStyle(
                              color: _showTranslatedTitle
                                  ? AppTheme.primaryEmerald
                                  : Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),

        // Lượt xem, đạn mạc
        Row(
          children: [
            if (viewCount.isNotEmpty)
              Text(
                '$viewCount lượt xem',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            if (viewCount.isNotEmpty && danmaku.isNotEmpty)
              const Text(' • ', style: TextStyle(color: Colors.white38)),
            if (danmaku.isNotEmpty)
              Text(
                '$danmaku đạn mạc',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
          ],
        ),
        const SizedBox(height: 12),

        // 3. Thanh nút thao tác nhanh
        Row(
          children: [
            // Nút Vietsub AI
            Expanded(
              child: InkWell(
                onTap: () => _startOnDemandPipeline(enableTts: false),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00AEEC).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF00AEEC).withValues(alpha: 0.4)),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.subtitles_rounded, color: Color(0xFF00AEEC), size: 16),
                      SizedBox(width: 6),
                      Text(
                        'Vietsub AI',
                        style: TextStyle(
                          color: Color(0xFF00AEEC),
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Nút Lồng tiếng AI
            Expanded(
              child: InkWell(
                onTap: () => _startOnDemandPipeline(enableTts: true),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryEmerald.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.primaryEmerald.withValues(alpha: 0.4)),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.record_voice_over_rounded, color: AppTheme.primaryEmerald, size: 16),
                      SizedBox(width: 6),
                      Text(
                        'Lồng tiếng AI',
                        style: TextStyle(
                          color: AppTheme.primaryEmerald,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Nút Chọn chất lượng
            InkWell(
              onTap: _showQualitySelectionSheet,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.high_quality_rounded, color: Colors.white70, size: 16),
                    const SizedBox(width: 4),
                    Text(
                      _currentQualityLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Nút Tải về
            IconButton(
              icon: const Icon(Icons.download_for_offline_rounded, color: Colors.white70, size: 20),
              tooltip: 'Tải video về máy',
              onPressed: _showDownloadSelectionSheet,
            ),
          ],
        ),
        const SizedBox(height: 14),

        // 4. KHỐI CHỌN PHẦN (P1, P2...) - Yêu cầu người dùng
        if (details != null && details.pages.length > 1) ...[
          _buildBilibiliPagesSelector(details),
          const SizedBox(height: 14),
        ],

        // 5. KHỐI HỢP TẬP (合集 - UGC Season)
        if (details?.ugcSeason != null) ...[
          _buildBilibiliUgcSeasonCard(details!.ugcSeason!, details.bvid),
          const SizedBox(height: 14),
        ],

        const Divider(color: Colors.white12, height: 1),
        const SizedBox(height: 12),

        // 6. Header "Video đề xuất" & Nút "Đổi đề xuất"
        Row(
          children: [
            const Icon(Icons.auto_awesome_rounded, color: Color(0xFF00AEEC), size: 18),
            const SizedBox(width: 7),
            const Text(
              'Video đề xuất',
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            if (_isLoadingRelated)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00AEEC)),
              )
            else
              InkWell(
                onTap: _isRefreshingRelated ? null : () => _refreshRecommendations(),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_isRefreshingRelated)
                        const SizedBox(
                          width: 11,
                          height: 11,
                          child: CircularProgressIndicator(strokeWidth: 1.6, color: Color(0xFF00AEEC)),
                        )
                      else
                        const Icon(Icons.refresh_rounded, size: 14, color: Color(0xFF00AEEC)),
                      const SizedBox(width: 4),
                      const Text(
                        'Đổi đề xuất',
                        style: TextStyle(
                          color: Color(0xFF00AEEC),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),

        // 7. Thanh lọc đề xuất (Đa dạng, Liên quan, Cùng kênh, Khám phá)
        _buildRelatedFilterBar(),
        const SizedBox(height: 10),

        // 8. Danh sách video đề xuất
        if (_isLoadingRelated && _displayedRelatedVideos.isEmpty)
          _buildRelatedVideosSkeleton()
        else if (_displayedRelatedVideos.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                'Không có video đề xuất liên quan',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ),
          )
        else ...[
          ..._displayedRelatedVideos.map((item) => _buildRelatedVideoTile(item)),
          if (_selectedRelatedTab == 'blended' || _selectedRelatedTab == 'explore')
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: TextButton.icon(
                  onPressed: _isLoadingMoreRelated ? null : () => _loadMoreRecommendations(),
                  icon: _isLoadingMoreRelated
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00AEEC)),
                        )
                      : const Icon(Icons.expand_more_rounded, size: 18, color: Color(0xFF00AEEC)),
                  label: Text(
                    _isLoadingMoreRelated ? 'Đang nạp thêm...' : 'Tải thêm video đề xuất',
                    style: const TextStyle(color: Color(0xFF00AEEC), fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                  style: TextButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: 0.05),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: const BorderSide(color: Colors.white12),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }

  /// Khối chọn phần P1, P2... như app gốc Bilibili
  Widget _buildBilibiliPagesSelector(BilibiliVideoDetails details) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.format_list_numbered_rounded,
                  color: Color(0xFFFB7299),
                  size: 18,
                ),
                const SizedBox(width: 6),
                Text(
                  'Chọn phần (Đang phát P${details.selectedPageIndex}/${details.pages.length})',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            if (details.pages.length > 4)
              InkWell(
                onTap: () => _showAllBilibiliPagesSheet(details),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(
                    children: const [
                      Text(
                        'Xem tất cả',
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, size: 16, color: Colors.white60),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 48,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: details.pages.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (ctx, index) {
              final pageInfo = details.pages[index];
              final isSelected = pageInfo.page == details.selectedPageIndex;

              return InkWell(
                onTap: () {
                  if (!isSelected) {
                    _goToBilibiliPage(pageInfo.page);
                  }
                },
                borderRadius: BorderRadius.circular(8),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  constraints: const BoxConstraints(minWidth: 84),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? const Color(0xFFFB7299).withValues(alpha: 0.18)
                        : const Color(0xFF1E212B),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSelected
                          ? const Color(0xFFFB7299)
                          : Colors.white12,
                      width: isSelected ? 1.5 : 1,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isSelected) ...[
                            const Icon(
                              Icons.graphic_eq_rounded,
                              size: 14,
                              color: Color(0xFFFB7299),
                            ),
                            const SizedBox(width: 4),
                          ],
                          Text(
                            'P${pageInfo.page}',
                            style: TextStyle(
                              color: isSelected
                                  ? const Color(0xFFFB7299)
                                  : Colors.white,
                              fontSize: 13,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      if (pageInfo.part.isNotEmpty)
                        Text(
                          pageInfo.part,
                          style: TextStyle(
                            color: isSelected
                                ? const Color(0xFFFB7299).withValues(alpha: 0.8)
                                : Colors.white54,
                            fontSize: 9.5,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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

  /// Thẻ Hợp tập (合集 - UGC Season)
  Widget _buildBilibiliUgcSeasonCard(BilibiliUgcSeason season, String currentBvid) {
    int currentIdx = 1;
    for (var i = 0; i < season.episodes.length; i++) {
      if (season.episodes[i].bvid == currentBvid) {
        currentIdx = i + 1;
        break;
      }
    }

    return InkWell(
      onTap: () {
        BilibiliSeasonSheet.show(
          context: context,
          season: season,
          currentBvid: currentBvid,
          onSelectEpisode: _goToBilibiliUgcEpisode,
        );
      },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1E212B),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: const Color(0xFFFB7299).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(
                Icons.video_library_rounded,
                color: Color(0xFFFB7299),
                size: 16,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '合集 · ${season.title}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Row(
              children: [
                const Icon(
                  Icons.graphic_eq_rounded,
                  size: 13,
                  color: Color(0xFFFB7299),
                ),
                const SizedBox(width: 4),
                Text(
                  '$currentIdx/${season.episodes.length}',
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, size: 18, color: Colors.white38),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Tab xem bình luận video Bilibili
  Widget _buildBilibiliCommentTab(BilibiliVideoDetails? details) {
    if (details == null) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFFB7299)),
      );
    }

    final commentCount = _bilibiliCommentResult?.totalCount ?? 0;

    return Column(
      children: [
        // Header bộ lọc bình luận
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Text(
                'Bình luận ($commentCount)',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              _buildCommentEngineChip(),
              const Spacer(),
              _buildCommentSortChip(
                label: 'Mới nhất',
                isSelected: _bilibiliCommentSort == 2,
                onTap: () {
                  if (_bilibiliCommentSort != 2) {
                    setState(() => _bilibiliCommentSort = 2);
                    _loadBilibiliComments(details.aid, reset: true);
                  }
                },
              ),
              const SizedBox(width: 8),
              _buildCommentSortChip(
                label: 'Nổi bật',
                isSelected: _bilibiliCommentSort == 0,
                onTap: () {
                  if (_bilibiliCommentSort != 0) {
                    setState(() => _bilibiliCommentSort = 0);
                    _loadBilibiliComments(details.aid, reset: true);
                  }
                },
              ),
            ],
          ),
        ),
        const Divider(color: Colors.white12, height: 1),

        // Danh sách bình luận
        Expanded(
          child: _isLoadingBilibiliComments
              ? const Center(
                  child: CircularProgressIndicator(color: Color(0xFFFB7299)),
                )
              : _bilibiliComments.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.chat_bubble_outline_rounded, size: 48, color: Colors.white24),
                          SizedBox(height: 10),
                          Text(
                            'Chưa có bình luận nào cho video này',
                            style: TextStyle(color: Colors.white54, fontSize: 13),
                          ),
                        ],
                      ),
                    )
                  : NotificationListener<ScrollNotification>(
                      onNotification: (scrollInfo) {
                        if (scrollInfo.metrics.pixels >=
                                scrollInfo.metrics.maxScrollExtent - 200 &&
                            !_isLoadingMoreComments &&
                            _hasMoreComments &&
                            !_isLoadingBilibiliComments) {
                          _loadMoreBilibiliComments();
                        }
                        return false;
                      },
                      child: ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        itemCount: _bilibiliComments.length + (_hasMoreComments ? 1 : 0),
                        separatorBuilder: (_, _) => const Divider(color: Colors.white10, height: 16),
                        itemBuilder: (ctx, index) {
                          if (index == _bilibiliComments.length) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 16),
                              child: Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(0xFFFB7299),
                                  ),
                                ),
                              ),
                            );
                          }
                          final comment = _bilibiliComments[index];
                          return _buildBilibiliCommentTile(comment);
                        },
                      ),
                    ),
        ),
      ],
    );
  }

  Widget _buildCommentEngineChip() {
    final isLocal = _commentTranslationEngine == 'local';
    final activeColor = isLocal ? const Color(0xFF5AB664) : const Color(0xFF00AEEC);

    return InkWell(
      onTap: _toggleCommentTranslationEngine,
      borderRadius: BorderRadius.circular(12),
      child: Tooltip(
        message: 'Chạm để đổi qua lại giữa dịch Local (miễn phí) và dịch AI (API)',
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
          decoration: BoxDecoration(
            color: activeColor.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: activeColor.withValues(alpha: 0.55),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isLocal ? Icons.phone_android_rounded : Icons.auto_awesome_rounded,
                size: 11.5,
                color: activeColor,
              ),
              const SizedBox(width: 4),
              Text(
                isLocal ? 'Dịch Local' : 'Dịch AI',
                style: TextStyle(
                  color: activeColor,
                  fontSize: 10.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.swap_horiz_rounded,
                size: 12,
                color: activeColor.withValues(alpha: 0.7),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCommentSortChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFFFB7299).withValues(alpha: 0.18)
              : Colors.white10,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? const Color(0xFFFB7299) : Colors.white12,
            width: 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? const Color(0xFFFB7299) : Colors.white60,
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  /// Thẻ hiển thị một bình luận Bilibili (có avatar, tên, level, dịch sang tiếng Việt)
  Widget _buildBilibiliCommentTile(BilibiliCommentItem comment) {
    final hasTranslation = _bilibiliCommentTranslations.containsKey(comment.rpid);
    final translatedText = _bilibiliCommentTranslations[comment.rpid] ?? '';
    final isTranslating = _bilibiliTranslatingCommentIds.contains(comment.rpid);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Avatar người bình luận
        ClipRRect(
          borderRadius: BorderRadius.circular(17),
          child: comment.avatar.isNotEmpty
              ? Image.network(
                  comment.avatar,
                  width: 34,
                  height: 34,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const CircleAvatar(
                    radius: 17,
                    backgroundColor: Color(0xFF282B37),
                    child: Icon(Icons.person, size: 18, color: Colors.white54),
                  ),
                )
              : const CircleAvatar(
                  radius: 17,
                  backgroundColor: Color(0xFF282B37),
                  child: Icon(Icons.person, size: 18, color: Colors.white54),
                ),
        ),
        const SizedBox(width: 10),

        // Cột nội dung bình luận
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Tên + Badge Level + Nút Dịch
              Row(
                children: [
                  Flexible(
                    child: Text(
                      comment.uname,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (comment.level > 0) ...[
                    const SizedBox(width: 5),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
                      decoration: BoxDecoration(
                        color: _getBilibiliLevelColor(comment.level).withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                          color: _getBilibiliLevelColor(comment.level).withValues(alpha: 0.5),
                          width: 0.6,
                        ),
                      ),
                      child: Text(
                        'Lv${comment.level}',
                        style: TextStyle(
                          color: _getBilibiliLevelColor(comment.level),
                          fontSize: 8.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),

                  // Nút Dịch bình luận sang tiếng Việt
                  InkWell(
                    onTap: isTranslating ? null : () => _toggleTranslateComment(comment.rpid, comment.message),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      child: isTranslating
                          ? const SizedBox(
                              width: 11,
                              height: 11,
                              child: CircularProgressIndicator(strokeWidth: 1.5, color: AppTheme.primaryEmerald),
                            )
                          : Row(
                              children: [
                                Icon(
                                  Icons.translate_rounded,
                                  size: 11.5,
                                  color: hasTranslation ? AppTheme.primaryEmerald : Colors.white38,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  hasTranslation ? 'Gốc' : 'Dịch',
                                  style: TextStyle(
                                    color: hasTranslation ? AppTheme.primaryEmerald : Colors.white38,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),

              // Nội dung bình luận tiếng Trung gốc
              Text(
                comment.message,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),

              // Bản dịch Tiếng Việt (nếu người dùng bấm Dịch)
              if (hasTranslation && translatedText.isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryEmerald.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppTheme.primaryEmerald.withValues(alpha: 0.35),
                      width: 0.8,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.g_translate_rounded,
                        size: 13,
                        color: AppTheme.primaryEmerald,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          translatedText,
                          style: const TextStyle(
                            color: Color(0xFFD1F2E0),
                            fontSize: 12.5,
                            height: 1.35,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 6),

              // Chân trang: Thời gian + Thích + Phản hồi
              Row(
                children: [
                  if (comment.timeText.isNotEmpty)
                    Text(
                      comment.timeText,
                      style: const TextStyle(color: Colors.white38, fontSize: 10.5),
                    ),
                  const Spacer(),
                  if (comment.likeCount > 0) ...[
                    const Icon(Icons.thumb_up_alt_outlined, size: 12, color: Colors.white38),
                    const SizedBox(width: 3),
                    Text(
                      '${comment.likeCount}',
                      style: const TextStyle(color: Colors.white38, fontSize: 10.5),
                    ),
                    const SizedBox(width: 12),
                  ],
                  if (comment.replyCount > 0) ...[
                    const Icon(Icons.chat_bubble_outline_rounded, size: 12, color: Colors.white38),
                    const SizedBox(width: 3),
                    Text(
                      '${comment.replyCount}',
                      style: const TextStyle(color: Colors.white38, fontSize: 10.5),
                    ),
                  ],
                ],
              ),

              // Phản hồi con (subReplies)
              if (comment.subReplies.isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF191B24),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: comment.subReplies.take(2).map((sub) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: RichText(
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: '${sub.uname}: ',
                                style: const TextStyle(
                                  color: Color(0xFF00AEEC),
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              TextSpan(
                                text: sub.message,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRelatedFilterBar() {
    final currentAuthor = _authorName ?? _bilibiliDetails?.author ?? _bilibiliItem?.author ?? '';
    final hasSameAuthorVideos = currentAuthor.isNotEmpty &&
        (_rawDirectRelated.any((it) => it.author.trim() == currentAuthor.trim()) ||
         _blendedRelatedVideos.any((it) => it.author.trim() == currentAuthor.trim()));

    return SizedBox(
      height: 30,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _buildRelatedFilterChip('blended', 'Đa dạng', Icons.auto_awesome_rounded),
          const SizedBox(width: 8),
          _buildRelatedFilterChip('related', 'Liên quan', Icons.tune_rounded),
          if (hasSameAuthorVideos) ...[
            const SizedBox(width: 8),
            _buildRelatedFilterChip('same_author', 'Cùng kênh', Icons.person_rounded),
          ],
          const SizedBox(width: 8),
          _buildRelatedFilterChip('explore', 'Khám phá', Icons.explore_rounded),
        ],
      ),
    );
  }

  Widget _buildRelatedFilterChip(String key, String label, IconData icon) {
    final isSelected = _selectedRelatedTab == key;
    return InkWell(
      onTap: () {
        if (_selectedRelatedTab != key) {
          setState(() {
            _selectedRelatedTab = key;
          });
        }
      },
      borderRadius: BorderRadius.circular(15),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF00AEEC).withValues(alpha: 0.22)
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: isSelected ? const Color(0xFF00AEEC) : Colors.white12,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: isSelected ? const Color(0xFF00AEEC) : Colors.white60,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.white70,
                fontSize: 11.5,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRelatedVideosSkeleton() {
    return Column(
      children: List.generate(4, (index) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 124,
                height: 70,
                decoration: BoxDecoration(
                  color: const Color(0xFF1E212B),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Center(
                  child: Icon(Icons.movie_rounded, color: Colors.white12, size: 24),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 14,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E212B),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      height: 14,
                      width: 140,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E212B),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      height: 10,
                      width: 90,
                      decoration: BoxDecoration(
                        color: const Color(0xFF191B24),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }),
    );
  }

  Widget _buildRelatedVideoTile(BilibiliAnimeItem item) {
    final currentAuthor = _authorName ?? _bilibiliDetails?.author ?? _bilibiliItem?.author ?? '';
    final isSameAuthor = currentAuthor.isNotEmpty && item.author.trim() == currentAuthor.trim();

    return InkWell(
      onTap: () {
        _switchVideo(
          newVideoPath: item.targetPlayUrl,
          newDocument: SubtitleDocument(),
          newTitle: item.title,
          newCoverUrl: item.cover,
          newAuthor: item.author,
          newBilibiliItem: item,
        );
      },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Thumbnail 16:9 bo góc kèm thời lượng
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 124,
                height: 70,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (item.cover.isNotEmpty)
                      Image.network(
                        item.cover,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          color: const Color(0xFF282B37),
                          child: const Icon(Icons.movie_rounded, color: Colors.white24),
                        ),
                      )
                    else
                      Container(
                        color: const Color(0xFF282B37),
                        child: const Icon(Icons.movie_rounded, color: Colors.white24),
                      ),
                    if (item.durationText.isNotEmpty)
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            item.durationText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),

            // Tiêu đề & tác giả UP
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  FutureBuilder<String>(
                    future: OfflineMlKitTranslator.translateHongguoTitle(item.title),
                    initialData: item.title,
                    builder: (context, snapshot) {
                      return Text(
                        snapshot.data ?? item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0.8),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: isSameAuthor ? const Color(0xFFFB7299) : Colors.white30,
                            width: 0.8,
                          ),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          'UP',
                          style: TextStyle(
                            color: isSameAuthor ? const Color(0xFFFB7299) : Colors.white60,
                            fontSize: 7.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          item.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isSameAuthor ? const Color(0xFFFB7299) : Colors.white54,
                            fontSize: 11,
                            fontWeight: isSameAuthor ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ),
                      if (isSameAuthor) ...[
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFB7299).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(
                              color: const Color(0xFFFB7299).withValues(alpha: 0.5),
                              width: 0.8,
                            ),
                          ),
                          child: const Text(
                            'Cùng kênh',
                            style: TextStyle(
                              color: Color(0xFFFB7299),
                              fontSize: 8,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (item.viewCountText.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      '${item.viewCountText} lượt xem',
                      style: const TextStyle(color: Colors.white38, fontSize: 10),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _switchVideo({
    required String newVideoPath,
    required SubtitleDocument newDocument,
    required String newTitle,
    String? newCoverUrl,
    String? newAuthor,
    BilibiliAnimeItem? newBilibiliItem,
  }) async {
    await _controller?.pause();
    _controller?.removeListener(_onPlayerUpdate);
    await _controller?.dispose();
    _controller = null;

    _playbackMonitor?.cancel();
    _ttsScheduler.dispose();

    final item = newBilibiliItem;
    setState(() {
      _isInitialized = false;
      _playerError = null;
      _sourceVideoUrl = newVideoPath;
      _currentVideoPath = newVideoPath;
      _currentDocument = newDocument;
      _currentTitle = newTitle;
      _originalTitle = newTitle;
      _translatedTitle = null;
      _coverUrl = newCoverUrl ?? item?.cover ?? _coverUrl;
      _authorName = newAuthor ?? item?.author ?? _authorName;
      _upFaceUrl = item?.upFace ?? _upFaceUrl;
      _bilibiliItem = item;
      if (item != null) {
        _bilibiliDetails = BilibiliVideoDetails(
          bvid: item.bvid ?? '',
          aid: 0,
          cid: 0,
          title: item.title,
          rawTitle: item.title,
          coverUrl: item.cover.isNotEmpty ? item.cover : null,
          durationSeconds: item.durationSeconds,
          author: item.author,
          upFace: item.upFace.isNotEmpty ? item.upFace : null,
          viewCountText: item.viewCountText,
          danmakuText: item.danmakuText,
        );
      }
      _currentPosMs = 0;
      _lastObservedPositionMs = 0;
      _lastSavedPositionMs = -1;
      _lastPositionSaveAt = DateTime.fromMillisecondsSinceEpoch(0);
      _isScrubbing = false;
      _isPlaybackStalled = false;
      _userChosePlayRaw = false;
    });

    final newBvid = item?.bvid ??
        RegExp(r'BV[a-zA-Z0-9]+', caseSensitive: false).firstMatch(newVideoPath)?.group(0);
    if (newBvid != null && newBvid.isNotEmpty) {
      _loadRelatedVideos(newBvid);
    }

    _ttsScheduler = TtsAudioScheduler(newDocument);
    await _initPlayerForPath(
      newVideoPath,
      refreshHongguoUrl: false,
    );
  }

  void _showDownloadSelectionSheet() {
    final isBilibili = _bilibiliDetails != null ||
        BilibiliResolver.isBilibiliUrl(_sourceVideoUrl) ||
        BilibiliResolver.isBilibiliUrl(_currentVideoPath);
    final isHongguo = widget.dramaDetail != null;

    if (!isBilibili) {
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (ctx) {
          return Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            decoration: const BoxDecoration(
              color: Color(0xFF1A1C24),
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryEmerald.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.download_for_offline_rounded,
                        color: AppTheme.primaryEmerald,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isHongguo
                                ? 'Tải Tập $_currentEpisodeIndex về máy'
                                : 'Tải video ngoại tuyến',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            isHongguo
                                ? 'Lưu phim vào bộ nhớ để xem offline mượt mà không cần mạng.'
                                : 'Tải video về máy để xem không bị giật lag mạng.',
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryEmerald,
                      foregroundColor: const Color(0xFF0D1117),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                    icon: const Icon(Icons.download_rounded, size: 20),
                    label: Text(
                      isHongguo
                          ? 'Bắt đầu tải Tập $_currentEpisodeIndex'
                          : 'Bắt đầu tải video',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _downloadCurrentVideo();
                    },
                  ),
                ),
              ],
            ),
          );
        },
      );
      return;
    }

    var selectedQuality = _settings.preferredVideoQuality;
    final qualities = [
      {
        'key': '80',
        'title': '1080p (Full HD)',
        'subtitle': 'Độ nét cao nhất, xem đã mắt trên màn hình lớn',
        'badge': 'VIP / SESSDATA',
      },
      {
        'key': '64',
        'title': '720p (HD - Chuẩn)',
        'subtitle': 'Cân bằng tối ưu giữa độ nét và dung lượng (Khuyên dùng)',
        'badge': 'Phổ biến',
      },
      {
        'key': '32',
        'title': '480p (Tiết kiệm)',
        'subtitle': 'Dung lượng nhẹ, phù hợp mạng 4G/3G hoặc máy ít bộ nhớ',
        'badge': null,
      },
      {
        'key': '16',
        'title': '360p (Siêu nhẹ)',
        'subtitle': 'Tải siêu tốc trong vài giây, tốn rất ít dữ liệu mạng',
        'badge': null,
      },
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              decoration: const BoxDecoration(
                color: Color(0xFF1A1C24),
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryEmerald.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.video_settings_rounded,
                              color: AppTheme.primaryEmerald,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 10),
                          const Text(
                            'Chọn chất lượng tải về',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, color: Colors.white60, size: 20),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Chọn độ phân giải mong muốn để lưu video offline:',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 14),
                  ...qualities.map((q) {
                    final isSel = selectedQuality == q['key'];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: InkWell(
                        onTap: () {
                          setSheetState(() {
                            selectedQuality = q['key']!;
                          });
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                          decoration: BoxDecoration(
                            color: isSel
                                ? AppTheme.primaryEmerald.withValues(alpha: 0.15)
                                : const Color(0xFF14151B),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSel
                                  ? AppTheme.primaryEmerald
                                  : Colors.white12,
                              width: isSel ? 1.5 : 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isSel
                                    ? Icons.radio_button_checked_rounded
                                    : Icons.radio_button_unchecked_rounded,
                                color: isSel
                                    ? AppTheme.primaryEmerald
                                    : Colors.white38,
                                size: 20,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          q['title']!,
                                          style: TextStyle(
                                            color: isSel
                                                ? AppTheme.primaryEmerald
                                                : Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                          ),
                                        ),
                                        if (q['badge'] != null) ...[
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 1.5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: (q['key'] == '80'
                                                      ? Colors.amber
                                                      : AppTheme.primaryEmerald)
                                                  .withValues(alpha: 0.2),
                                              borderRadius: BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              q['badge']!,
                                              style: TextStyle(
                                                color: q['key'] == '80'
                                                    ? Colors.amber
                                                    : AppTheme.primaryEmerald,
                                                fontSize: 9.5,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      q['subtitle']!,
                                      style: TextStyle(
                                        color: Colors.white.withValues(alpha: 0.55),
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryEmerald,
                        foregroundColor: const Color(0xFF0D1117),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      icon: const Icon(Icons.download_rounded, size: 20),
                      label: Text(
                        'Tải ngay (${qualities.firstWhere((e) => e['key'] == selectedQuality)['title']?.split(' ').first})',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      onPressed: () {
                        _settings.preferredVideoQuality = selectedQuality;
                        Navigator.pop(ctx);
                        _downloadCurrentVideo(quality: selectedQuality);
                      },
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

  Future<void> _downloadCurrentVideo({String? quality}) async {
    if (_isDownloadingVideo) return;
    final isHongguo = widget.dramaDetail != null;
    final isBilibili = _bilibiliDetails != null ||
        BilibiliResolver.isBilibiliUrl(_sourceVideoUrl) ||
        BilibiliResolver.isBilibiliUrl(_currentVideoPath);

    void onDownloadProgress(double progress, String message) {
      if (!mounted) return;
      setState(() {
        _downloadProgress = progress;
        _downloadMessage = message;
      });
    }

    setState(() {
      _isDownloadingVideo = true;
      _showDownloadBanner = true;
      _downloadProgress = 0.02;
      _downloadMessage = isHongguo
          ? 'Đang chuẩn bị tải Tập $_currentEpisodeIndex...'
          : 'Đang kết nối tải video...';
    });

    try {
      if (isHongguo) {
        final drama = widget.dramaDetail!;
        final cachedVideo = await VideoCacheManager.getCachedVideoFile(
          url: _sourceVideoUrl,
          seriesId: drama.seriesId,
          episodeIndex: _currentEpisodeIndex,
        );
        final partFile = File('${cachedVideo.path}.part');

        var streamUrl = _currentVideoPath;
        if (!streamUrl.startsWith('http')) {
          streamUrl = await _prefetchManager?.getOrResolveUrl(_currentEpisodeIndex) ?? _sourceVideoUrl;
        }

        await MultiThreadDownloader.downloadFile(
          url: streamUrl,
          outputFile: partFile,
          headers: NetworkHeaderHelper.getHeadersForUri(streamUrl),
          concurrency: _settings.downloadThreadCount,
          progressCallback: onDownloadProgress,
        );

        if (await partFile.exists() && await partFile.length() > 1024 * 50) {
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
            await history.updateVideoPath(_sourceVideoUrl, cachedVideo.path);
            await history.updateVideoPath(streamUrl, cachedVideo.path);
          } catch (_) {}

          if (mounted) {
            setState(() {
              _downloadProgress = 1.0;
              _downloadMessage = '✅ Đã tải Tập $_currentEpisodeIndex thành công!';
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('✅ Tải Tập $_currentEpisodeIndex thành công! Đang chuyển sang phát offline mượt mà...'),
                backgroundColor: AppTheme.primaryEmerald,
                duration: const Duration(seconds: 3),
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
      } else if (isBilibili) {
        final resolver = BilibiliResolver();
        BilibiliVideoDetails details;
        if (_bilibiliDetails != null) {
          details = _bilibiliDetails!;
        } else {
          final target = await resolver.resolveUrl(_sourceVideoUrl);
          details = await resolver.getVideoDetails(
            target,
            _settings.bilibiliSessData,
          );
          _bilibiliDetails = details;
        }
        if (_currentTitle.isEmpty || _isGenericTitle(_currentTitle)) {
          _currentTitle = details.title;
          if (mounted) setState(() {});
        }
        if (details.coverUrl != null && details.coverUrl!.isNotEmpty) {
          try {
            final history = await HistoryRepository.getInstance();
            await history.updateCoverForVideo(_sourceVideoUrl, details.coverUrl!);
          } catch (_) {}
        }

        final cachedVideo = await VideoCacheManager.getCachedVideoFile(
          url: _sourceVideoUrl,
          bvid: details.bvid,
          bilibiliPage: details.selectedPageIndex,
        );
        final partFile = File('${cachedVideo.path}.part');
        await resolver.downloadVideo(
          details,
          partFile,
          _settings.bilibiliSessData,
          concurrency: _settings.downloadThreadCount,
          quality: quality ?? _settings.preferredVideoQuality,
          onProgress: onDownloadProgress,
        );

        if (await partFile.exists() && await partFile.length() > 1024 * 100) {
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
            await history.updateVideoPath(_sourceVideoUrl, cachedVideo.path);
            await history.updateVideoPath(_currentVideoPath, cachedVideo.path);
            if (_currentTitle.isNotEmpty && !_isGenericTitle(_currentTitle)) {
              await history.updateTitleForVideo(cachedVideo.path, _currentTitle);
              await history.updateTitleForVideo(_sourceVideoUrl, _currentTitle);
            }
          } catch (_) {}
          if (mounted) {
            setState(() {
              _downloadProgress = 1.0;
              _downloadMessage = '✅ Đã tải video Bilibili thành công!';
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('✅ Tải video thành công! Đang chuyển sang phát offline mượt mà...'),
                backgroundColor: AppTheme.primaryEmerald,
                duration: Duration(seconds: 3),
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
      } else {
        // Video MP4/HTTP thông thường
        final cachedVideo = await VideoCacheManager.getCachedVideoFile(
          url: _sourceVideoUrl,
        );
        final partFile = File('${cachedVideo.path}.part');
        final downloadUrl = _currentVideoPath.startsWith('http') ? _currentVideoPath : _sourceVideoUrl;
        await MultiThreadDownloader.downloadFile(
          url: downloadUrl,
          outputFile: partFile,
          headers: NetworkHeaderHelper.getHeadersForUri(downloadUrl),
          concurrency: _settings.downloadThreadCount,
          progressCallback: onDownloadProgress,
        );
        if (await partFile.exists() && await partFile.length() > 1024 * 100) {
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
            await history.updateVideoPath(_sourceVideoUrl, cachedVideo.path);
            await history.updateVideoPath(_currentVideoPath, cachedVideo.path);
          } catch (_) {}
          if (mounted) {
            setState(() {
              _downloadProgress = 1.0;
              _downloadMessage = '✅ Đã tải video thành công!';
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('✅ Tải video thành công! Đang chuyển sang phát offline mượt mà...'),
                backgroundColor: AppTheme.primaryEmerald,
                duration: Duration(seconds: 3),
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
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⚠️ Lỗi khi tải video: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDownloadingVideo = false;
          _downloadProgress = 0.0;
          _downloadMessage = '';
          _showDownloadBanner = true;
        });
      }
    }
  }

  @override
  void dispose() {
    unawaited(_persistPlaybackPosition(force: true));
    _pipControlsTimer?.cancel();
    _pipFeedbackTimer?.cancel();
    PipManager.isInPipMode.removeListener(_onPipModeChanged);
    PipManager.lastPipAction.removeListener(_onPipActionReceived);
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
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _isInBackground = true;
      unawaited(_persistPlaybackPosition(force: true));
      final isPlaying = _controller?.value.isPlaying ?? false;
      final allowBackground =
          _settings.backgroundPlayEnabled || PipManager.isInPipMode.value;

      if (allowBackground && isPlaying) {
        final displayTitle = _currentTitle.isNotEmpty
            ? _currentTitle
            : (widget.title ?? 'CapSub Video');
        final durationSec = _controller?.value.duration.inSeconds ?? 100;
        final currentSec = _currentPosMs ~/ 1000;
        ForegroundServiceManager.start(
          title: displayTitle,
          message: 'Đang phát âm thanh trong nền',
          progress: currentSec,
          maxProgress: durationSec > 0 ? durationSec : 100,
        );
      } else {
        if (!allowBackground) {
          _controller?.pause();
          _ttsScheduler.onSeek(_currentPosMs);
        }
        ForegroundServiceManager.stop();
      }
    } else if (state == AppLifecycleState.resumed) {
      _isInBackground = false;
      ForegroundServiceManager.stop();
      if (mounted) {
        setState(() {});
      }
    }
  }

  void _onPlayerUpdate() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final positionMs = controller.value.position.inMilliseconds;
    final durationMs = controller.value.duration.inMilliseconds;
    final now = DateTime.now();

    // Tự động chuyển sang tập tiếp theo khi xem xong (video kết thúc và còn < 1s) - Chỉ dành cho phim bộ Hồng Quả
    if (_autoPlayNextEpisode &&
        _hasNextEpisode &&
        widget.dramaDetail != null &&
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
      if (_isPlaybackStalled) {
        _isPlaybackStalled = false;
      }
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
    if (value == null || !value.isInitialized) return false;

    // Nếu video bị tạm dừng (người dùng bấm Pause) hoặc đã chạy hết video -> Không bao giờ hiển thị xoay buffering
    if (!value.isPlaying || value.position >= value.duration) {
      if (_isPlaybackStalled) {
        _isPlaybackStalled = false;
        return true;
      }
      return false;
    }

    // Video đang trong trạng thái Phát (isPlaying = true) nhưng vị trí video KHÔNG chạy trong ít nhất 1.2s -> Thực sự bị khựng lag chờ mạng
    final stalled = now.difference(_lastPositionAdvanceAt) >= _stallThreshold;
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
    if (_isScrubbing && !force) return;
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastPositionSaveAt) < _positionSaveInterval) {
      return;
    }
    final controller = _controller;
    final positionMs = controller?.value.isInitialized == true
        ? controller!.value.position.inMilliseconds
        : _currentPosMs;
    if (!force && positionMs == _lastSavedPositionMs) return;
    _lastPositionSaveAt = now;
    _lastSavedPositionMs = positionMs;
    try {
      final detail = widget.dramaDetail;
      if (detail != null && detail.seriesId.isNotEmpty) {
        final history = await HistoryRepository.getInstance();
        final updated = await history.updateSeriesPlaybackPosition(
          seriesId: detail.seriesId,
          episodeIndex: _currentEpisodeIndex,
          positionMs: positionMs,
          durationMs: controller?.value.duration.inMilliseconds,
          seriesTitle: detail.title,
        );
        // Bản ghi cũ có thể chưa có seriesId. Chỉ fallback callback cho đúng
        // tập ban đầu, tuyệt đối không ghi tiến độ tập mới vào tập đã mở trước đó.
        if (!updated &&
            _currentEpisodeIndex == (widget.currentEpisodeIndex ?? 1)) {
          await widget.onPlaybackPositionChanged?.call(positionMs);
        }
      } else {
        await widget.onPlaybackPositionChanged?.call(positionMs);
      }
    } catch (_) {}

    if (_isInBackground && (_controller?.value.isPlaying ?? false)) {
      final durationSec = _controller?.value.duration.inSeconds ?? 100;
      final currentSec = positionMs ~/ 1000;
      final displayTitle = _currentTitle.isNotEmpty
          ? _currentTitle
          : (widget.title ?? 'CapSub Video');
      unawaited(
        ForegroundServiceManager.update(
          title: displayTitle,
          message: 'Đang phát âm thanh trong nền',
          progress: currentSec,
          maxProgress: durationSec > 0 ? durationSec : 100,
        ),
      );
    }
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
    setState(() => _playbackSpeed = speed);
    if (widget.dramaDetail != null) {
      _settings.hongguoPlaybackSpeed = speed;
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      await controller.setPlaybackSpeed(speed);
      _syncTtsWithVideo();
    } catch (_) {
      if (!mounted) return;
      setState(() => _playbackSpeed = 1);
      if (widget.dramaDetail != null) {
        _settings.hongguoPlaybackSpeed = 1.0;
      }
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


  @override
  Widget build(BuildContext context) {
    if (_playerError != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _playerError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: () {
                    setState(() {
                      _playerError = null;
                      _isInitialized = false;
                    });
                    unawaited(_initPlayerForPath(_sourceVideoUrl));
                  },
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Thử lại'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final displayTitle = _currentTitle.isNotEmpty
        ? _currentTitle
        : (widget.title ?? widget.bilibiliItem?.title ?? '');

    // Nếu đang ở chế độ Mini-Player (Thu nhỏ kiểu YouTube)
    if (widget.isGlobalPlayer && GlobalPlayerManager.instance.isMiniPlayer) {
      return _buildMiniPlayer(displayTitle);
    }

    // Nếu đang ở chế độ Picture-in-Picture ngoài màn hình
    if (PipManager.isInPipMode.value) {
      return _buildPipPlayer();
    }

    final controller = _controller;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final isLocalVideo = !_currentVideoPath.startsWith('http://') &&
        !_currentVideoPath.startsWith('https://');
    final bool isHongguoWaitingTranslation = widget.dramaDetail != null &&
        _currentDocument.isEmpty &&
        !_userChosePlayRaw &&
        !isLocalVideo;

    // NẾU LÀ HỒNG QUẢ VÀ ĐANG CHỜ DỊCH: NHẢY THẲNG VÀO GATE OVERLAY (PHOTO 2)
    if (isHongguoWaitingTranslation) {
      return Scaffold(
        backgroundColor: const Color(0xFF0D1117),
        body: SafeArea(
          child: _buildHongguoTranslatingGateOverlay(displayTitle),
        ),
      );
    }

    final isBilibili = _bilibiliDetails != null ||
        widget.bilibiliItem != null ||
        BilibiliResolver.isBilibiliUrl(_sourceVideoUrl) ||
        BilibiliResolver.isBilibiliUrl(_currentVideoPath);
    final isBilibiliPortrait = !isLandscape && !_isPlayerFullScreen && (isBilibili && widget.dramaDetail == null);

    final Widget playerWidget;
    if (_isInitialized && controller != null && controller.value.isInitialized) {
      playerWidget = _buildVideoPlayerArea(
        controller,
        isLandscape,
        isHongguoWaitingTranslation,
        displayTitle,
        isBilibiliPortrait: isBilibiliPortrait,
      );
    } else {
      playerWidget = _buildPlayerLoadingArea(displayTitle);
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: isBilibiliPortrait
            ? Column(
                children: [
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: playerWidget,
                  ),
                  Expanded(
                    child: _buildBilibiliBelowContent(),
                  ),
                ],
              )
            : playerWidget,
      ),
    );
  }

  Widget _buildPlayerLoadingArea(String displayTitle) {
    final isHongguo = widget.dramaDetail != null;
    final cover = _coverUrl ?? _bilibiliDetails?.coverUrl;

    // Loading toàn màn hình dọc cho Hồng Quả (khi đã chọn xem bản gốc hoặc có sub nhưng đang nạp controller)
    if (isHongguo) {
      return Container(
        color: const Color(0xFF0D1117),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (cover != null && cover.isNotEmpty)
              Image.network(
                cover,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(color: const Color(0xFF0D1117)),
              )
            else
              Container(color: const Color(0xFF0D1117)),
            Container(color: Colors.black.withValues(alpha: 0.6)),
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  shape: BoxShape.circle,
                ),
                child: const SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: AppTheme.primaryEmerald,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white, size: 22),
                    onPressed: () {
                      if (widget.isGlobalPlayer) {
                        GlobalPlayerManager.instance.minimize();
                      } else {
                        Navigator.pop(context);
                      }
                    },
                  ),
                  if (displayTitle.isNotEmpty)
                    Expanded(
                      child: Text(
                        displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  IconButton(
                    icon: const Icon(
                      Icons.format_list_numbered_rounded,
                      color: Colors.white,
                    ),
                    tooltip: 'Danh sách tập',
                    onPressed: _showEpisodeListSheet,
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Ảnh bìa video (nạp tức thì 0ms từ bộ nhớ RAM cache của thẻ danh sách)
          if (cover != null && cover.isNotEmpty)
            Image.network(
              cover,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(color: const Color(0xFF14161E)),
            )
          else
            Container(color: const Color(0xFF14161E)),

          // 2. Lớp phủ làm mờ đen nhẹ
          Container(
            color: Colors.black.withValues(alpha: 0.45),
          ),

          // 3. Vòng xoay nạp mượt phong cách Bilibili
          Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                shape: BoxShape.circle,
              ),
              child: const SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Color(0xFFFB7299),
                ),
              ),
            ),
          ),

          // 4. Thanh nút điều hướng trên cùng (chỉ giữ nút quay lại, xóa nút mũi tên chỉ xuống)
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
                  onPressed: () {
                    if (widget.isGlobalPlayer) {
                      GlobalPlayerManager.instance.minimize();
                    } else {
                      Navigator.pop(context);
                    }
                  },
                ),
                if (displayTitle.isNotEmpty)
                  Expanded(
                    child: Text(
                      displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoPlayerArea(
    VideoPlayerController controller,
    bool isLandscape,
    bool isHongguoWaitingTranslation,
    String displayTitle, {
    required bool isBilibiliPortrait,
  }) {
    return GestureDetector(
      onTap: () {
        if (isHongguoWaitingTranslation) return;
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

          // Vòng xoay chờ tải mạng (Chỉ hiện khi video đang phát nhưng thực sự bị khựng lag không chạy được)
          if (_isPlaybackStalled && !controller.value.hasError)
            Center(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  shape: BoxShape.circle,
                ),
                child: const CircularProgressIndicator(
                  strokeWidth: 3.5,
                  color: Color(0xFF00AEEC),
                ),
              ),
            ),

          // Lớp chuyển đổi chất lượng video
          if (_isSwitchingQuality)
            Container(
              color: Colors.black54,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(
                      color: Color(0xFF00AEEC),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Đang đổi chất lượng sang $_currentQualityLabel...',
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

              // Banner tiến trình dịch cho tập hiện tại (Hồng Quả: khi đang phát video và dịch/lồng tiếng chạy ngầm)
              if (_prefetchManager != null &&
                  _currentDocument.isEmpty &&
                  (widget.dramaDetail != null || _userChosePlayRaw))
                Positioned(
                  top: 56,
                  left: 20,
                  right: 20,
                  child: ValueListenableBuilder<PrefetchState?>(
                    valueListenable: _prefetchManager!.prefetchStateNotifier,
                    builder: (context, state, _) {
                      if (state == null ||
                          state.episodeIndex != _currentEpisodeIndex) {
                        return Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.85),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: AppTheme.primaryEmerald.withValues(alpha: 0.6),
                                width: 1.2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.5),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
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
                                    color: AppTheme.primaryEmerald,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _settings.isTtsPlaybackEnabled
                                      ? 'Đang chuẩn bị sub & lồng tiếng Tập $_currentEpisodeIndex...'
                                      : 'Đang chuẩn bị dịch phụ đề Tập $_currentEpisodeIndex...',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
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
                            color: Colors.black.withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isFailed
                                  ? Colors.redAccent.withValues(alpha: 0.6)
                                  : AppTheme.primaryEmerald.withValues(alpha: 0.6),
                              width: 1.2,
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
                                              : (_settings.isTtsPlaybackEnabled
                                                  ? 'Đang dịch & tạo lồng tiếng Tập $_currentEpisodeIndex (${(state.progress * 100).toInt()}%)...'
                                                  : 'Đang bóc tách & dịch phụ đề Tập $_currentEpisodeIndex (${(state.progress * 100).toInt()}%)...')),
                                      style: TextStyle(
                                        fontSize: 11.5,
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
                                            if (_controller?.value.isPlaying ?? false) {
                                              if (_settings.isTtsPlaybackEnabled) {
                                                final pos = _controller?.value.position.inMilliseconds ?? 0;
                                                _ttsScheduler.onSeek(pos);
                                                _syncTtsWithVideo();
                                              }
                                            }
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
                              if (isTranslating) ...[
                                const SizedBox(height: 6),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(2),
                                  child: SizedBox(
                                    width: 170,
                                    height: 3.5,
                                    child: LinearProgressIndicator(
                                      value: state.progress > 0
                                          ? state.progress.clamp(0.0, 1.0)
                                          : null,
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

              // Banner tiến trình dịch theo yêu cầu (Bilibili / Link ngoài)
              if (_isTranslatingOnDemand)
                Positioned(
                  top: 56,
                  left: 20,
                  right: 20,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: const Color(0xFF00AEEC),
                          width: 1.2,
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
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF00AEEC),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  _onDemandProgressMessage,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          if (_onDemandProgressPct > 0) ...[
                            const SizedBox(height: 6),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: SizedBox(
                                width: 160,
                                height: 3,
                                child: LinearProgressIndicator(
                                  value: _onDemandProgressPct.clamp(0.0, 1.0),
                                  backgroundColor: Colors.white12,
                                  color: const Color(0xFF00AEEC),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),

              // Gợi ý tạo Vietsub / Lồng tiếng cho video chưa có phụ đề khi mở controls (Chỉ áp dụng Bilibili / Video ngoài, Hồng Quả đã chọn từ đầu)
              if (_showControls &&
                  widget.dramaDetail == null &&
                  _currentDocument.isEmpty &&
                  !_isTranslatingOnDemand)
                Positioned(
                  top: 56,
                  left: 20,
                  right: 20,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.subtitles_outlined, color: Colors.white70, size: 16),
                          const SizedBox(width: 8),
                          const Text(
                            'Xem thử video gốc',
                            style: TextStyle(color: Colors.white70, fontSize: 11),
                          ),
                          const SizedBox(width: 10),
                          InkWell(
                            onTap: () => _startOnDemandPipeline(enableTts: false),
                            borderRadius: BorderRadius.circular(14),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00AEEC),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.translate_rounded, color: Colors.white, size: 12),
                                  SizedBox(width: 4),
                                  Text(
                                    'Vietsub AI',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          InkWell(
                            onTap: () => _startOnDemandPipeline(enableTts: true),
                            borderRadius: BorderRadius.circular(14),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppTheme.primaryEmerald,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.record_voice_over_rounded, color: Colors.black, size: 12),
                                  SizedBox(width: 4),
                                  Text(
                                    'Lồng tiếng AI',
                                    style: TextStyle(
                                      color: Colors.black,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // Màn hình chờ dịch tập mới (Gatekeeper) khi chưa có sub và chưa chọn xem bản gốc
              if (isHongguoWaitingTranslation)
                Positioned.fill(
                  child: _buildHongguoTranslatingGateOverlay(displayTitle),
                ),

              // 4. Thanh điều khiển Video (Controls)
              if (_showControls && !isHongguoWaitingTranslation) ...[
                // Nút quay lại & tiêu đề trên cùng
                Positioned(
                  top: 8,
                  left: 8,
                  right: 8,
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () {
                          if (_isPlayerFullScreen) {
                            setState(() {
                              _isPlayerFullScreen = false;
                            });
                            return;
                          }
                          if (widget.isGlobalPlayer) {
                            if (_settings.miniPlayerEnabled) {
                              GlobalPlayerManager.instance.minimize();
                            } else {
                              GlobalPlayerManager.instance.close();
                            }
                          } else {
                            Navigator.pop(context);
                          }
                        },
                      ),
                      if (displayTitle.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: isLandscape
                                ? 420
                                : (MediaQuery.of(context).size.width * 0.45)
                                    .clamp(130.0, 220.0),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    fit: FlexFit.loose,
                                    child: Tooltip(
                                      message: 'Chạm để sao chép: $displayTitle',
                                      child: InkWell(
                                        onTap: () => _copyTitleToClipboard(displayTitle),
                                        borderRadius: BorderRadius.circular(4),
                                        child: SingleChildScrollView(
                                          scrollDirection: Axis.horizontal,
                                          physics: const BouncingScrollPhysics(),
                                          child: Text(
                                            displayTitle,
                                            maxLines: 1,
                                            softWrap: false,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 14,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  InkWell(
                                    onTap: _isTranslatingTitle ? null : _togglePlayerTitleTranslation,
                                    borderRadius: BorderRadius.circular(6),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: _showTranslatedTitle
                                            ? AppTheme.primaryEmerald.withValues(alpha: 0.25)
                                            : Colors.white24,
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                          color: _showTranslatedTitle
                                              ? AppTheme.primaryEmerald.withValues(alpha: 0.5)
                                              : Colors.white30,
                                        ),
                                      ),
                                      child: _isTranslatingTitle
                                          ? const SizedBox(
                                              width: 10,
                                              height: 10,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white,
                                              ),
                                            )
                                          : Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  Icons.translate_rounded,
                                                  size: 11,
                                                  color: _showTranslatedTitle
                                                      ? AppTheme.primaryEmerald
                                                      : Colors.white,
                                                ),
                                                const SizedBox(width: 3),
                                                Text(
                                                  _showTranslatedTitle ? 'Gốc' : 'Dịch',
                                                  style: TextStyle(
                                                    color: _showTranslatedTitle
                                                        ? AppTheme.primaryEmerald
                                                        : Colors.white,
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ],
                                            ),
                                    ),
                                  ),
                                ],
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
                                    Flexible(
                                      child: Text(
                                        (!_currentVideoPath.startsWith('http://') &&
                                                !_currentVideoPath.startsWith('https://'))
                                            ? 'Phát offline (Bộ nhớ máy)'
                                            : 'Phát trực tuyến (Online)',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                          color: (!_currentVideoPath.startsWith('http://') &&
                                                  !_currentVideoPath.startsWith('https://'))
                                              ? AppTheme.primaryEmerald
                                              : const Color(0xFFFFB74D),
                                        ),
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
                      ],

                      // Danh sách nút công cụ & tiện ích có thể cuộn ngang mượt mà khi quay dọc
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            physics: const BouncingScrollPhysics(),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 1. Nút Tự Chuyển Tập & Dịch Ngầm (Đưa lên vị trí đầu tiên)
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

                                // 2. Nút PiP ngoài màn hình (Picture-in-Picture)
                                IconButton(
                                  icon: const Icon(
                                    Icons.picture_in_picture_alt_rounded,
                                    color: Colors.white,
                                  ),
                                  tooltip: Platform.isIOS
                                      ? 'Thu nhỏ video (Mini-Player)'
                                      : 'Hình thu nhỏ ngoài màn hình (PiP)',
                                  onPressed: _enterPipMode,
                                ),

                                // 3. Cài đặt Bilibili
                                if (_bilibiliDetails != null || BilibiliResolver.isBilibiliUrl(_sourceVideoUrl)) ...[
                                  IconButton(
                                    icon: const Icon(
                                      Icons.tune_rounded,
                                      color: Color(0xFF00AEEC),
                                    ),
                                    tooltip: 'Cài đặt Bilibili',
                                    onPressed: () => BilibiliSettingsSheet.show(context),
                                  ),
                                ],

                                // 4. Nút Bật/Tắt Lồng tiếng AI
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

                                // 5. Chỉnh âm lượng độc lập (Âm lượng kép)
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

                                // 6. Tùy chỉnh phụ đề & vị trí
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

                                // 7. Tải video offline (nếu là video online)
                                if (_currentVideoPath.startsWith('http')) ...[
                                  if (_isDownloadingVideo)
                                    GestureDetector(
                                      onTap: () {
                                        setState(() {
                                          _showDownloadBanner = !_showDownloadBanner;
                                        });
                                      },
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 4),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: AppTheme.primaryEmerald.withValues(
                                              alpha: _showDownloadBanner ? 0.22 : 0.10,
                                            ),
                                            borderRadius: BorderRadius.circular(16),
                                            border: Border.all(
                                              color: AppTheme.primaryEmerald.withValues(
                                                alpha: _showDownloadBanner ? 0.7 : 0.35,
                                              ),
                                              width: 1,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              SizedBox(
                                                width: 13,
                                                height: 13,
                                                child: CircularProgressIndicator(
                                                  value: _downloadProgress > 0
                                                      ? _downloadProgress.clamp(0.0, 1.0)
                                                      : null,
                                                  strokeWidth: 2,
                                                  color: AppTheme.primaryEmerald,
                                                  backgroundColor: Colors.white12,
                                                ),
                                              ),
                                              const SizedBox(width: 5),
                                              Text(
                                                '${(_downloadProgress * 100).toInt()}%',
                                                style: const TextStyle(
                                                  color: AppTheme.primaryEmerald,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              const SizedBox(width: 4),
                                              Icon(
                                                _showDownloadBanner
                                                    ? Icons.visibility_rounded
                                                    : Icons.visibility_off_rounded,
                                                color: AppTheme.primaryEmerald
                                                    .withValues(alpha: 0.8),
                                                size: 13,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    )
                                  else
                                    IconButton(
                                      icon: const Icon(
                                        Icons.download_for_offline_rounded,
                                        color: Colors.white,
                                      ),
                                      tooltip: 'Tải video về máy để xem offline (không lag)',
                                      onPressed: _showDownloadSelectionSheet,
                                    ),
                                ],
                              ],
                            ),
                          ),
                        ),
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
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Nút chất lượng video Bilibili (1080P, 720P, ...)
                              if (_bilibiliDetails != null ||
                                  BilibiliResolver.isBilibiliUrl(_sourceVideoUrl) ||
                                  BilibiliResolver.isBilibiliUrl(_currentVideoPath)) ...[
                                InkWell(
                                  onTap: _showQualitySelectionSheet,
                                  borderRadius: BorderRadius.circular(4),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF00AEEC).withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(
                                        color: const Color(0xFF00AEEC).withValues(alpha: 0.6),
                                        width: 1,
                                      ),
                                    ),
                                    child: Text(
                                      _currentQualityLabel,
                                      style: const TextStyle(
                                        color: Color(0xFF00AEEC),
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                              ],
                              Text(
                                _formatDuration(controller.value.duration),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                iconSize: 22,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                icon: Icon(
                                  (isLandscape || _isPlayerFullScreen)
                                      ? Icons.fullscreen_exit_rounded
                                      : Icons.fullscreen_rounded,
                                  color: Colors.white,
                                ),
                                tooltip: (isLandscape || _isPlayerFullScreen)
                                    ? 'Thu nhỏ'
                                    : 'Toàn màn hình',
                                onPressed: () {
                                  setState(() {
                                    _isPlayerFullScreen = !_isPlayerFullScreen;
                                  });
                                },
                              ),
                            ],
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

              // 5. Thanh hiển thị tiến trình tải video offline (Floating Banner)
              if (_isDownloadingVideo && _showDownloadBanner)
                Positioned(
                  bottom: isLandscape
                      ? ((_showControls && !isHongguoWaitingTranslation) ? 58 : 12)
                      : ((_showControls && !isHongguoWaitingTranslation) ? 82 : 24),
                  left: isLandscape ? 32 : 16,
                  right: isLandscape ? 32 : 16,
                  child: Center(
                    child: isLandscape
                        ? _buildLandscapeDownloadBanner()
                        : _buildPortraitDownloadBanner(),
                  ),
                ),
            ],
          ),
        );
  }

  Widget _buildLandscapeDownloadBanner() {
    return Container(
      constraints: const BoxConstraints(maxWidth: 520),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF14161E).withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppTheme.primaryEmerald.withValues(alpha: 0.6),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.downloading_rounded,
            color: AppTheme.primaryEmerald,
            size: 15,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              _downloadMessage.isNotEmpty
                  ? _downloadMessage
                  : 'Đang tải video...',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 80,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: _downloadProgress > 0
                    ? _downloadProgress.clamp(0.0, 1.0)
                    : null,
                minHeight: 3,
                backgroundColor: Colors.white12,
                color: AppTheme.primaryEmerald,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${(_downloadProgress * 100).toInt()}%',
            style: const TextStyle(
              color: AppTheme.primaryEmerald,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: () {
              setState(() {
                _showDownloadBanner = false;
              });
            },
            child: const Padding(
              padding: EdgeInsets.all(2),
              child: Icon(
                Icons.close_rounded,
                color: Colors.white60,
                size: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPortraitDownloadBanner() {
    return Container(
      constraints: const BoxConstraints(maxWidth: 440),
      padding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: 9,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF14161E).withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppTheme.primaryEmerald.withValues(alpha: 0.7),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.downloading_rounded,
                color: AppTheme.primaryEmerald,
                size: 19,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _downloadMessage.isNotEmpty
                      ? _downloadMessage
                      : 'Đang tải video về máy để xem offline...',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(_downloadProgress * 100).toInt()}%',
                style: const TextStyle(
                  color: AppTheme.primaryEmerald,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () {
                  setState(() {
                    _showDownloadBanner = false;
                  });
                },
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(
                    Icons.close_rounded,
                    color: Colors.white60,
                    size: 16,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: _downloadProgress > 0
                  ? _downloadProgress.clamp(0.0, 1.0)
                  : null,
              minHeight: 4,
              backgroundColor: Colors.white12,
              color: AppTheme.primaryEmerald,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHongguoTranslatingGateOverlay(String displayTitle) {
    if (_prefetchManager == null && widget.dramaDetail != null) {
      _prefetchManager = HongguoPrefetchManager(widget.dramaDetail!);
      _prefetchManager!.registerVideoUrl(_currentEpisodeIndex, widget.videoPath);
      if (_currentDocument.isNotEmpty) {
        _prefetchManager!.registerDocument(_currentEpisodeIndex, _currentDocument);
      }
    }
    return Container(
      color: const Color(0xFF0D1117),
      child: Stack(
        children: [
          // Thanh tiêu đề phía trên cùng
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () {
                    if (widget.isGlobalPlayer) {
                      if (_settings.miniPlayerEnabled) {
                        GlobalPlayerManager.instance.minimize();
                      } else {
                        GlobalPlayerManager.instance.close();
                      }
                    } else {
                      Navigator.pop(context);
                    }
                  },
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Tooltip(
                    message: 'Chạm để sao chép: $displayTitle',
                    child: InkWell(
                      onTap: () => _copyTitleToClipboard(displayTitle),
                      borderRadius: BorderRadius.circular(4),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        child: Text(
                          displayTitle,
                          maxLines: 1,
                          softWrap: false,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.format_list_numbered_rounded,
                    color: Colors.white,
                  ),
                  tooltip: 'Danh sách tập',
                  onPressed: _showEpisodeListSheet,
                ),
              ],
            ),
          ),
          // Hộp thông báo tiến độ dịch tập phim
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ValueListenableBuilder<PrefetchState?>(
                valueListenable: _prefetchManager!.prefetchStateNotifier,
                builder: (context, state, _) {
                  final isFailed = state?.status == 'failed';
                  final progress = (state != null && state.episodeIndex == _currentEpisodeIndex)
                      ? state.progress.clamp(0.0, 1.0)
                      : 0.0;
                  final percent = (progress * 100).toInt();
                  final message = (state != null &&
                          state.episodeIndex == _currentEpisodeIndex &&
                          state.message.isNotEmpty)
                      ? state.message
                      : 'Đang chuẩn bị bóc tách & dịch phụ đề...';

                  return Container(
                    constraints: const BoxConstraints(maxWidth: 420),
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161B22),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isFailed
                            ? Colors.redAccent.withValues(alpha: 0.5)
                            : AppTheme.primaryEmerald.withValues(alpha: 0.35),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.6),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: isFailed
                                ? Colors.redAccent.withValues(alpha: 0.15)
                                : AppTheme.primaryEmerald.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: isFailed
                                ? const Icon(
                                    Icons.error_outline_rounded,
                                    color: Colors.redAccent,
                                    size: 34,
                                  )
                                : const SizedBox(
                                    width: 30,
                                    height: 30,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 3,
                                      color: AppTheme.primaryEmerald,
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          isFailed
                              ? 'Chưa thể dịch Tập $_currentEpisodeIndex'
                              : 'Đang dịch Tập $_currentEpisodeIndex ($percent%)',
                          style: TextStyle(
                            color: isFailed ? Colors.redAccent : Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          isFailed
                              ? (state?.message ?? 'Đã xảy ra lỗi trong quá trình bóc tách phụ đề.')
                              : message,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 13,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        if (!isFailed) ...[
                          const SizedBox(height: 18),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: progress > 0 ? progress : null,
                              backgroundColor: Colors.white12,
                              color: AppTheme.primaryEmerald,
                              minHeight: 6,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Bạn có thể đợi hoàn tất để xem Vietsub & lồng tiếng AI,\nhoặc bấm nút dưới đây để xem trước bản gốc tiếng Trung.',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.55),
                              fontSize: 12,
                              height: 1.4,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                        const SizedBox(height: 24),
                        if (!isFailed)
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.primaryEmerald,
                                foregroundColor: const Color(0xFF0D1117),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                elevation: 0,
                              ),
                              icon: const Icon(
                                Icons.play_arrow_rounded,
                                size: 22,
                                color: Color(0xFF0D1117),
                              ),
                              label: const Text(
                                'Xem luôn bản gốc tiếng Trung (Dịch ngầm)',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                              onPressed: () {
                                setState(() {
                                  _userChosePlayRaw = true;
                                });
                                _controller?.play();
                              },
                            ),
                          )
                        else
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    side: BorderSide(
                                      color: Colors.white.withValues(alpha: 0.3),
                                    ),
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                  icon: const Icon(Icons.refresh_rounded, size: 18),
                                  label: const Text('Thử lại'),
                                  onPressed: () {
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
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.white24,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    elevation: 0,
                                  ),
                                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                                  label: const Text('Xem bản gốc'),
                                  onPressed: () {
                                    setState(() {
                                      _userChosePlayRaw = true;
                                    });
                                    _controller?.play();
                                  },
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
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

  Widget _buildPipPlayer() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: AppTheme.primaryEmerald),
        ),
      );
    }

    final durationMs = controller.value.duration.inMilliseconds;
    final currentPosMs = _currentPosMs.clamp(0, durationMs > 0 ? durationMs : 0);
    final isPlaying = controller.value.isPlaying;

    return Scaffold(
      backgroundColor: Colors.black,
      body: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: GestureDetector(
          onTap: _togglePipControls,
          onScaleStart: (details) {
            _pipBaseScale = _pipZoomScale;
          },
          onScaleUpdate: (details) {
            setState(() {
              _pipZoomScale = (_pipBaseScale * details.scale).clamp(0.85, 2.8);
            });
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 1. Video Layer với thu phóng mượt mà
              Center(
                child: Transform.scale(
                  scale: _pipZoomScale,
                  child: AspectRatio(
                    aspectRatio: controller.value.aspectRatio,
                    child: VideoPlayer(controller),
                  ),
                ),
              ),

              // 2. Vùng nhận diện chạm đúp tua 10s trái / phải
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onDoubleTap: () {
                        _skipBy(-10000);
                        _triggerDoubleTapFeedback(isLeft: true);
                        _startPipControlsTimer();
                      },
                      child: const SizedBox.expand(),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onDoubleTap: () {
                        _skipBy(10000);
                        _triggerDoubleTapFeedback(isLeft: false);
                        _startPipControlsTimer();
                      },
                      child: const SizedBox.expand(),
                    ),
                  ),
                ],
              ),

              // 3. Hiệu ứng Double-tap Ripple trực quan (YouTube style)
              if (_pipDoubleTapLeft)
                Positioned(
                  left: 20,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        shape: BoxShape.circle,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.replay_10, color: Colors.white, size: 22),
                          SizedBox(height: 2),
                          Text('-10s', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
                ),
              if (_pipDoubleTapRight)
                Positioned(
                  right: 20,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        shape: BoxShape.circle,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.forward_10, color: Colors.white, size: 22),
                          SizedBox(height: 2),
                          Text('+10s', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
                ),

              // 4. Phụ đề Subtitle Pill (nằm trên thanh progress bar)
              if (_currentDocument.isNotEmpty)
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: _pipShowControls ? 28 : 8,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    alignment: Alignment.center,
                    child: _buildMiniSubtitleSnippet(),
                  ),
                ),

              // 5. Giao diện điều khiển kiểu hình mẫu Image 2
              AnimatedOpacity(
                opacity: _pipShowControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 240),
                child: IgnorePointer(
                  ignoring: !_pipShowControls,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.65),
                          Colors.black.withValues(alpha: 0.25),
                          Colors.black.withValues(alpha: 0.65),
                        ],
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Thanh trên cùng: Nút Đóng (✕) bên trái, Nút chỉnh tỷ lệ & Phóng to bên phải
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            GestureDetector(
                              onTap: () {
                                controller.pause();
                                _ttsScheduler.onSeek(_currentPosMs);
                                ForegroundServiceManager.stop();
                                if (widget.isGlobalPlayer) {
                                  GlobalPlayerManager.instance.close();
                                }
                              },
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.55),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white24, width: 0.8),
                                ),
                                child: const Icon(Icons.close, color: Colors.white, size: 16),
                              ),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                GestureDetector(
                                  onTap: _cyclePipAspectRatio,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(alpha: 0.55),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: Colors.white24, width: 0.8),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.aspect_ratio_rounded, color: Colors.white, size: 13),
                                        const SizedBox(width: 3),
                                        Text(
                                          _pipRatioLabel,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 9,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                GestureDetector(
                                  onTap: () {
                                    if (widget.isGlobalPlayer) {
                                      GlobalPlayerManager.instance.expand();
                                    }
                                  },
                                  child: Container(
                                    width: 28,
                                    height: 28,
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(alpha: 0.55),
                                      shape: BoxShape.circle,
                                      border: Border.all(color: Colors.white24, width: 0.8),
                                    ),
                                    child: const Icon(Icons.open_in_full_rounded, color: Colors.white, size: 13),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),

                        // Cụm điều khiển ở giữa: Tua lại 10s, Phát/Dừng tròn lớn, Tua tới 10s (chuẩn Image 2)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            GestureDetector(
                              onTap: () {
                                _skipBy(-10000);
                                _triggerDoubleTapFeedback(isLeft: true);
                                _startPipControlsTimer();
                              },
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.55),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white24, width: 0.8),
                                ),
                                child: const Icon(Icons.replay_10, color: Colors.white, size: 20),
                              ),
                            ),
                            const SizedBox(width: 18),
                            GestureDetector(
                              onTap: () async {
                                if (controller.value.isPlaying) {
                                  await controller.pause();
                                  _ttsScheduler.onSeek(_currentPosMs);
                                } else {
                                  await controller.play();
                                  _syncTtsWithVideo();
                                }
                                unawaited(PipManager.updatePipActions(isPlaying: controller.value.isPlaying));
                                _startPipControlsTimer();
                                if (mounted) setState(() {});
                              },
                              child: Container(
                                width: 46,
                                height: 46,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.85),
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.4),
                                      blurRadius: 8,
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                  color: Colors.black87,
                                  size: 28,
                                ),
                              ),
                            ),
                            const SizedBox(width: 18),
                            GestureDetector(
                              onTap: () {
                                _skipBy(10000);
                                _triggerDoubleTapFeedback(isLeft: false);
                                _startPipControlsTimer();
                              },
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.55),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white24, width: 0.8),
                                ),
                                child: const Icon(Icons.forward_10, color: Colors.white, size: 20),
                              ),
                            ),
                          ],
                        ),

                        // Thanh dưới cùng: Thời gian và Thanh tiến trình mượt mà
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      _formatDuration(Duration(milliseconds: currentPosMs)),
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      _formatDuration(Duration(milliseconds: durationMs)),
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: durationMs > 0 ? (currentPosMs / durationMs).clamp(0.0, 1.0) : 0.0,
                                  backgroundColor: Colors.white24,
                                  valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primaryEmerald),
                                  minHeight: 2.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMiniPlayer(String displayTitle) {
    final controller = _controller;
    final isPlaying = controller?.value.isPlaying ?? false;
    final durationMs = controller?.value.duration.inMilliseconds ?? 0;
    final currentPosMs = _currentPosMs.clamp(0, durationMs > 0 ? durationMs : 0);

    return Dismissible(
      key: ValueKey('mini_${widget.videoPath}'),
      direction: DismissDirection.horizontal,
      onDismissed: (_) {
        GlobalPlayerManager.instance.close();
      },
      child: GestureDetector(
        onTap: () {
          GlobalPlayerManager.instance.expand();
        },
        child: Container(
          height: 64,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF1E222D).withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.12),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              children: [
                Row(
                  children: [
                    // Mini Video Preview
                    Container(
                      width: 90,
                      height: 52,
                      margin: const EdgeInsets.only(left: 6, top: 6, bottom: 6),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (controller != null && controller.value.isInitialized)
                              FittedBox(
                                fit: BoxFit.cover,
                                child: SizedBox(
                                  width: controller.value.size.width,
                                  height: controller.value.size.height,
                                  child: VideoPlayer(controller),
                                ),
                              )
                            else if (_coverUrl != null && _coverUrl!.isNotEmpty)
                              Image.network(
                                _coverUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => Container(
                                  color: Colors.black54,
                                  child: const Icon(Icons.movie_rounded, color: Colors.white24),
                                ),
                              )
                            else
                              Container(
                                color: Colors.black54,
                                child: const Center(
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Color(0xFFFB7299),
                                    ),
                                  ),
                                ),
                              ),
                            // Mini Subtitle text preview
                            if (_currentDocument.isNotEmpty)
                              Positioned(
                                left: 2,
                                right: 2,
                                bottom: 2,
                                child: _buildMiniSubtitleSnippet(),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Tiêu đề & Thông tin tiến trình
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayTitle.isNotEmpty ? displayTitle : 'Đang phát video',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              if (widget.dramaDetail != null) ...[
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: AppTheme.primaryEmerald.withValues(alpha: 0.25),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: AppTheme.primaryEmerald.withValues(alpha: 0.4),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Text(
                                    'Tập $_currentEpisodeIndex',
                                    style: const TextStyle(
                                      color: AppTheme.primaryEmerald,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                              ],
                              Flexible(
                                child: Text(
                                  '${_formatDuration(Duration(milliseconds: currentPosMs))} / ${_formatDuration(Duration(milliseconds: durationMs))}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.65),
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                              if (_settings.isTtsPlaybackEnabled) ...[
                                const SizedBox(width: 4),
                                const Icon(
                                  Icons.record_voice_over,
                                  size: 11,
                                  color: Colors.lightGreenAccent,
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),

                    // Nút Tua lùi 10s
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      icon: const Icon(Icons.replay_10, color: Colors.white70, size: 20),
                      tooltip: 'Lùi 10 giây',
                      onPressed: () => _skipBy(-10000),
                    ),

                    // Nút Play / Pause
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                      icon: Icon(
                        isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        color: AppTheme.primaryEmerald,
                        size: 26,
                      ),
                      tooltip: isPlaying ? 'Tạm dừng' : 'Phát tiếp',
                      onPressed: () async {
                        if (controller == null) return;
                        if (isPlaying) {
                          await controller.pause();
                          _ttsScheduler.onSeek(_currentPosMs);
                        } else {
                          await controller.play();
                          _syncTtsWithVideo();
                        }
                        if (mounted) setState(() {});
                      },
                    ),

                    // Nút Tua tới 10s
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      icon: const Icon(Icons.forward_10, color: Colors.white70, size: 20),
                      tooltip: 'Tới 10 giây',
                      onPressed: () => _skipBy(10000),
                    ),

                    // Nút Đóng mini-player (X)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 20),
                      tooltip: 'Đóng trình phát',
                      onPressed: () {
                        GlobalPlayerManager.instance.close();
                      },
                    ),
                    const SizedBox(width: 4),
                  ],
                ),

                // Thanh tiến trình chạy dưới đáy thẻ
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: LinearProgressIndicator(
                    value: durationMs > 0 ? (currentPosMs / durationMs).clamp(0.0, 1.0) : 0.0,
                    backgroundColor: Colors.white12,
                    valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primaryEmerald),
                    minHeight: 2.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMiniSubtitleSnippet() {
    final sub = _currentDocument.getActiveItem(_currentPosMs);
    final text = sub?.getDisplayText(_settings.subtitleMode) ?? '';
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 8,
          fontWeight: FontWeight.bold,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}
