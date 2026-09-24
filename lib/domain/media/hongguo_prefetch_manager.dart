import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../data/model/subtitle_document.dart';
import '../../data/repository/history_repository.dart';
import '../../data/repository/settings_repository.dart';
import '../pipeline/subtitling_pipeline.dart';
import 'hongguo_resolver.dart';

class PrefetchState {
  final int episodeIndex;
  final String status; // 'idle', 'resolving', 'translating', 'ready', 'failed'
  final double progress; // 0.0 - 1.0
  final String message;
  final SubtitleDocument? document;
  final String? videoUrl;

  const PrefetchState({
    required this.episodeIndex,
    this.status = 'idle',
    this.progress = 0.0,
    this.message = '',
    this.document,
    this.videoUrl,
  });

  bool get isReady => status == 'ready' && document != null;
  bool get isTranslating => status == 'translating' || status == 'resolving';
}

class HongguoPrefetchManager {
  final HongguoDramaDetail detail;
  final HongguoResolver _resolver = HongguoResolver();

  final Map<int, SubtitleDocument> _cachedDocs = {};
  final Map<int, String> _cachedUrls = {};
  final Map<int, Completer<SubtitleDocument?>> _inFlightDocCompleters = {};
  final Map<int, Completer<String?>> _inFlightUrlCompleters = {};

  final ValueNotifier<PrefetchState?> prefetchStateNotifier =
      ValueNotifier<PrefetchState?>(null);

  SubtitlingPipeline? _activePipeline;
  StreamSubscription? _pipelineSub;
  bool _isDisposed = false;
  int _currentPlayingIndex = 1;

  HongguoPrefetchManager(this.detail);

  /// Đăng ký tài liệu đã dịch sẵn (nếu có từ trước)
  void registerDocument(int episodeIndex, SubtitleDocument doc) {
    _cachedDocs[episodeIndex] = doc;
  }

  /// Đăng ký URL video đã biết (nếu có)
  void registerVideoUrl(int episodeIndex, String url) {
    _cachedUrls[episodeIndex] = url;
  }

  /// Lấy SubtitleDocument đã có trong cache
  SubtitleDocument? getCachedDocument(int episodeIndex) {
    return _cachedDocs[episodeIndex];
  }

  /// Lấy Video URL đã có trong cache
  String? getCachedUrl(int episodeIndex) {
    return _cachedUrls[episodeIndex];
  }

  /// Kích hoạt khi bắt đầu phát một tập phim:
  /// 1. Nếu tập hiện tại chưa có sub -> dịch ngay tập hiện tại
  /// 2. Gối đầu dịch ngầm tập kế tiếp (N + 1)
  Future<void> onEpisodePlaying(
    int episodeIndex, {
    bool translateCurrentIfEmpty = true,
    void Function(SubtitleDocument doc)? onCurrentSubtitleReady,
  }) async {
    if (_isDisposed) return;
    _currentPlayingIndex = episodeIndex;

    // 1. Kiểm tra tập hiện tại đã có phụ đề chưa
    var currentDoc = _cachedDocs[episodeIndex];
    if (currentDoc == null) {
      currentDoc = await _findInHistory(episodeIndex);
      if (currentDoc != null) {
        _cachedDocs[episodeIndex] = currentDoc;
        onCurrentSubtitleReady?.call(currentDoc);
      }
    }

    // Nếu tập hiện tại chưa có sub và người dùng yêu cầu dịch ngay
    if (currentDoc == null && translateCurrentIfEmpty) {
      debugPrint('[Prefetch] Tập hiện tại $episodeIndex chưa có sub, đang dịch ngay...');
      final doc = await _executeTranslation(episodeIndex);
      if (doc != null && !_isDisposed && _currentPlayingIndex == episodeIndex) {
        onCurrentSubtitleReady?.call(doc);
      }
    }

    // 2. Tự động gối đầu dịch ngầm các tập tiếp theo theo cấu hình (1 hoặc 2 tập...)
    final settings = await SettingsRepository.getInstance();
    if (!settings.autoPlayNextEpisode) {
      debugPrint('[Prefetch] Tự động chuyển tập đang TẮT, không chạy dịch ngầm.');
      return;
    }

    final bufferCount = settings.prefetchEpisodeCount;
    final total = detail.episodes.isNotEmpty
        ? detail.episodes.length
        : (detail.totalEpisodes > 0 ? detail.totalEpisodes : 100);

    unawaited(_runPrefetchQueue(episodeIndex, bufferCount, total));
  }

  /// Chạy hàng đợi dịch ngầm tuần tự theo số tập đệm đã cài đặt
  Future<void> _runPrefetchQueue(
    int playingIndex,
    int bufferCount,
    int total,
  ) async {
    for (var i = 1; i <= bufferCount; i++) {
      if (_isDisposed || _currentPlayingIndex != playingIndex) break;
      final settings = await SettingsRepository.getInstance();
      if (!settings.autoPlayNextEpisode) break;

      final nextIndex = playingIndex + i;
      if (nextIndex <= total) {
        await _prefetchNextEpisode(nextIndex);
      }
    }
  }

  /// Tiến trình dịch ngầm tập tiếp theo
  Future<void> _prefetchNextEpisode(int nextIndex) async {
    if (_isDisposed) return;

    // Nếu đã có trong cache
    if (_cachedDocs.containsKey(nextIndex)) {
      prefetchStateNotifier.value = PrefetchState(
        episodeIndex: nextIndex,
        status: 'ready',
        progress: 1.0,
        message: 'Tập $nextIndex đã có sẵn phụ đề',
        document: _cachedDocs[nextIndex],
        videoUrl: _cachedUrls[nextIndex],
      );
      return;
    }

    // Nếu đã có trong Lịch sử trước đó
    final fromHistory = await _findInHistory(nextIndex);
    if (fromHistory != null) {
      _cachedDocs[nextIndex] = fromHistory;
      prefetchStateNotifier.value = PrefetchState(
        episodeIndex: nextIndex,
        status: 'ready',
        progress: 1.0,
        message: 'Tập $nextIndex đã có trong lịch sử',
        document: fromHistory,
        videoUrl: _cachedUrls[nextIndex],
      );
      return;
    }

    debugPrint('[Prefetch] Bắt đầu dịch ngầm gối đầu Tập $nextIndex...');
    await _executeTranslation(nextIndex);
  }

  /// Thực thi toàn bộ pipeline tải -> STT -> Dịch AI cho một tập phim
  Future<SubtitleDocument?> _executeTranslation(int episodeIndex) async {
    if (_isDisposed) return null;

    if (_cachedDocs.containsKey(episodeIndex)) {
      return _cachedDocs[episodeIndex];
    }

    if (_inFlightDocCompleters.containsKey(episodeIndex)) {
      return _inFlightDocCompleters[episodeIndex]!.future;
    }

    final completer = Completer<SubtitleDocument?>();
    _inFlightDocCompleters[episodeIndex] = completer;

    try {
      prefetchStateNotifier.value = PrefetchState(
        episodeIndex: episodeIndex,
        status: 'resolving',
        progress: 0.05,
        message: 'Đang kết nối video Tập $episodeIndex...',
      );

      // Bước 1: Lấy URL phát video
      final playUrl = await getOrResolveUrl(episodeIndex);
      if (playUrl == null || _isDisposed) {
        throw StateError('Không thể lấy đường dẫn video tập $episodeIndex');
      }

      prefetchStateNotifier.value = PrefetchState(
        episodeIndex: episodeIndex,
        status: 'translating',
        progress: 0.15,
        message: 'Đang nghe và dịch Tập $episodeIndex...',
        videoUrl: playUrl,
      );

      // Bước 2: Chuẩn bị SubtitlingPipeline theo cấu hình người dùng
      final settings = await SettingsRepository.getInstance();
      _activePipeline?.cancel();
      await _pipelineSub?.cancel();

      final pipeline = SubtitlingPipeline(
        apiKeys: settings.geminiApiKeys,
        groqApiKeys: settings.groqApiKeys,
        translationEngine: settings.selectedModel,
        stylePreset: settings.selectedStyle,
        customPrompt: settings.geminiCustomPrompt,
        targetLanguage: settings.targetLanguage,
        geminiThreadCount: settings.geminiThreadCount,
        geminiBatchSize: settings.geminiBatchSize,
        groqThreadCount: settings.groqThreadCount,
        groqBatchSize: settings.groqBatchSize,
      );
      _activePipeline = pipeline;

      _pipelineSub = pipeline.progressStream.listen((progress) {
        if (_isDisposed) return;
        final pct = progress.progress.clamp(0.0, 1.0);
        prefetchStateNotifier.value = PrefetchState(
          episodeIndex: episodeIndex,
          status: 'translating',
          progress: pct,
          message: progress.message.isNotEmpty
              ? progress.message
              : 'Đang dịch Tập $episodeIndex (${(pct * 100).toInt()}%)...',
          videoUrl: playUrl,
        );
      });

      // Bước 3: Chạy quy trình bóc tách âm thanh & dịch phụ đề
      // Phim ngắn Hồng Quả trung bình 1.5 - 2 phút (~120000ms)
      final doc = await pipeline.execute(
        videoPath: playUrl,
        totalDurationMs: 120000,
        sourceLanguage: settings.defaultSourceLanguage,
      );

      if (_isDisposed) {
        completer.complete(null);
        return null;
      }

      // Bước 4: Lưu vào Cache và Lịch sử
      _cachedDocs[episodeIndex] = doc;
      final epTitle = '${detail.title} - Tập $episodeIndex';
      try {
        final historyRepo = await HistoryRepository.getInstance();
        await historyRepo.saveHistory(
          videoPath: playUrl,
          title: epTitle,
          document: doc,
          durationMs: 120000,
          seriesId: detail.seriesId,
          seriesCover: detail.cover,
          episodeIndex: episodeIndex,
          totalEpisodes: detail.totalEpisodes > 0
              ? detail.totalEpisodes
              : detail.episodes.length,
        );
      } catch (e) {
        debugPrint('[Prefetch] Lỗi lưu history: $e');
      }

      prefetchStateNotifier.value = PrefetchState(
        episodeIndex: episodeIndex,
        status: 'ready',
        progress: 1.0,
        message: 'Tập $episodeIndex đã sẵn sàng!',
        document: doc,
        videoUrl: playUrl,
      );

      completer.complete(doc);
      return doc;
    } catch (e) {
      debugPrint('[Prefetch] Lỗi dịch tập $episodeIndex: $e');
      if (!_isDisposed) {
        prefetchStateNotifier.value = PrefetchState(
          episodeIndex: episodeIndex,
          status: 'failed',
          progress: 0.0,
          message: 'Lỗi dịch Tập $episodeIndex: $e',
        );
      }
      completer.complete(null);
      return null;
    } finally {
      _inFlightDocCompleters.remove(episodeIndex);
    }
  }

  /// Lấy hoặc phân giải URL của tập phim
  Future<String?> getOrResolveUrl(int episodeIndex) async {
    if (_cachedUrls.containsKey(episodeIndex)) {
      return _cachedUrls[episodeIndex];
    }

    if (_inFlightUrlCompleters.containsKey(episodeIndex)) {
      return _inFlightUrlCompleters[episodeIndex]!.future;
    }

    final completer = Completer<String?>();
    _inFlightUrlCompleters[episodeIndex] = completer;

    try {
      var vid = '';
      if (detail.episodes.isNotEmpty &&
          episodeIndex <= detail.episodes.length) {
        vid = detail.episodes[episodeIndex - 1].vid;
      }

      final url = await _resolver.getEpisodePlayUrl(
        detail.seriesId,
        vid.isNotEmpty ? vid : detail.seriesId,
      );

      _cachedUrls[episodeIndex] = url;
      completer.complete(url);
      return url;
    } catch (e) {
      completer.complete(null);
      return null;
    } finally {
      _inFlightUrlCompleters.remove(episodeIndex);
    }
  }

  /// Tìm xem tập phim này đã từng được dịch và lưu trong Lịch sử chưa
  Future<SubtitleDocument?> _findInHistory(int episodeIndex) async {
    try {
      final historyRepo = await HistoryRepository.getInstance();
      final list = historyRepo.getHistory();
      final item = list.firstWhere(
        (it) {
          if (it.seriesId != null &&
              it.seriesId == detail.seriesId &&
              it.extractedEpisodeIndex == episodeIndex) {
            return true;
          }
          final epTitle = '${detail.title} - Tập $episodeIndex';
          if (it.title.trim() == epTitle.trim()) return true;
          return it.title.contains(detail.title) &&
              it.title.contains('Tập $episodeIndex');
        },
        orElse: () => throw 'not_found',
      );

      return await historyRepo.loadSubtitleDocument(item);
    } catch (_) {
      return null;
    }
  }

  /// Dừng các tác vụ dịch ngầm hiện tại (khi người dùng tắt công tắc AutoPlay)
  void cancelPrefetch() {
    _activePipeline?.cancel();
    _pipelineSub?.cancel();
    _activePipeline = null;
    prefetchStateNotifier.value = null;
  }

  /// Huỷ bỏ các tác vụ ngầm khi đóng trình phát
  void dispose() {
    _isDisposed = true;
    cancelPrefetch();
    prefetchStateNotifier.dispose();
  }
}
