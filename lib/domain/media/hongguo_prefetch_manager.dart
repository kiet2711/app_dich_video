import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

import '../../data/model/history_item.dart';
import '../../data/model/subtitle_document.dart';
import '../../data/model/voice_model.dart';
import '../../data/repository/history_repository.dart';
import '../../data/repository/settings_repository.dart';
import '../pipeline/subtitling_pipeline.dart';
import '../service/foreground_service_manager.dart';
import '../tts/tts_cache_helper.dart';
import '../tts/tts_generation_manager.dart';
import 'hongguo_resolver.dart';
import 'video_cache_manager.dart';

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

  final Map<int, SubtitlingPipeline> _activePipelines = {};
  final Map<int, StreamSubscription> _pipelineSubs = {};
  bool _isDisposed = false;
  int _currentPlayingIndex = 1;

  HongguoPrefetchManager(this.detail);

  /// Nạp nóng (Preload) toàn bộ các tập đã có trong Lịch sử của bộ phim vào RAM
  /// Giúp khi chuyển sang các tập đã dịch trước đó (do dịch gối đầu), video và sub
  /// phát được ngay lập tức 0ms mà không bị kẹt quay tròn hay chờ dịch lại.
  Future<void> preloadFromHistory({List<HistoryItem>? seedItems}) async {
    if (_isDisposed) return;
    try {
      final historyRepo = await HistoryRepository.getInstance();
      final items = seedItems ?? historyRepo.getHistory();
      final targetSeriesId = detail.seriesId.trim();
      final targetTitle = detail.title.trim().toLowerCase();

      for (final item in items) {
        if (_isDisposed) break;
        final epIdx = item.extractedEpisodeIndex;
        if (epIdx <= 0) continue;

        final isSameSeries = (targetSeriesId.isNotEmpty && item.seriesId == targetSeriesId) ||
            (targetTitle.isNotEmpty &&
                (item.extractedSeriesTitle.trim().toLowerCase() == targetTitle ||
                    item.title.toLowerCase().contains(targetTitle) ||
                    targetTitle.contains(item.extractedSeriesTitle.trim().toLowerCase())));

        if (!isSameSeries) continue;

        // 1. Nạp SubtitleDocument nếu chưa có trong RAM
        if (!_cachedDocs.containsKey(epIdx)) {
          final doc = await historyRepo.loadSubtitleDocument(item);
          if (doc != null && doc.isNotEmpty) {
            _cachedDocs[epIdx] = doc;
          }
        }

        // 2. Nạp file video nếu hợp lệ
        if (!_cachedUrls.containsKey(epIdx)) {
          final resolvedVideo = await HistoryRepository.resolveItemVideoPath(item);
          if (resolvedVideo.isNotEmpty) {
            final isLocal = !resolvedVideo.startsWith('http://') && !resolvedVideo.startsWith('https://');
            if (isLocal &&
                await File(resolvedVideo).exists() &&
                (await File(resolvedVideo).length()) > 1024 * 50) {
              _cachedUrls[epIdx] = resolvedVideo;
            } else if (!isLocal) {
              _cachedUrls[epIdx] = resolvedVideo;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[Prefetch] Lỗi preloadFromHistory: $e');
    }
  }

  /// Tìm nhanh tài liệu phụ đề từ RAM hoặc Lịch sử cho một tập cụ thể
  Future<SubtitleDocument?> findDocumentInHistory(int episodeIndex) async {
    final cached = _cachedDocs[episodeIndex];
    if (cached != null && cached.isNotEmpty) return cached;
    return await _findInHistory(episodeIndex);
  }

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

    final settings = await SettingsRepository.getInstance();

    // 1. Kiểm tra tập hiện tại đã có phụ đề chưa
    var currentDoc = _cachedDocs[episodeIndex];
    if (currentDoc == null) {
      currentDoc = await _findInHistory(episodeIndex);
      if (currentDoc != null) {
        _cachedDocs[episodeIndex] = currentDoc;
        onCurrentSubtitleReady?.call(currentDoc);
      }
    }

    // Nếu tập hiện tại đã có sub và đang bật lồng tiếng AI -> đảm bảo tạo file âm thanh
    if (currentDoc != null && settings.isTtsPlaybackEnabled) {
      unawaited(ensureTtsGenerated(currentDoc, episodeIndex: episodeIndex).then((_) {
        if (!_isDisposed && _currentPlayingIndex == episodeIndex) {
          onCurrentSubtitleReady?.call(currentDoc!);
        }
      }));
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

  /// Đảm bảo các câu phụ đề đã được tạo file âm thanh lồng tiếng AI (nếu đang bật TTS)
  Future<VoiceItem?> ensureTtsGenerated(
    SubtitleDocument doc, {
    int? episodeIndex,
  }) async {
    if (_isDisposed) return null;
    try {
      final settings = await SettingsRepository.getInstance();
      final voiceType = settings.hongguoSelectedTtsVoice;
      final voice = VoicePresets.vietnameseVoices.firstWhere(
        (v) => v.voiceType == voiceType,
        orElse: () => VoicePresets.defaultVoice,
      );

      // 1. Liên kết các file âm thanh đã có trong cache
      await TtsCacheHelper.linkAudioFiles(doc, voice.voiceType);

      // 2. Tìm các câu chưa có file âm thanh
      final unlinked = doc.items.where(
        (item) =>
            (item.audioFilePath == null || item.audioFilePath!.isEmpty) &&
            TtsGenerationManager.isPronounceable(item.translatedText),
      ).toList();

      if (unlinked.isNotEmpty) {
        if (episodeIndex != null && !_isDisposed) {
          prefetchStateNotifier.value = PrefetchState(
            episodeIndex: episodeIndex,
            status: 'translating',
            progress: 0.92,
            message:
                'Đang tạo lồng tiếng AI Tập $episodeIndex (${voice.displayName})...',
            document: doc,
          );
        }

        await TtsGenerationManager().generateAll(
          document: doc,
          voice: voice,
          threadCount: settings.ttsThreadCount,
        );
      }
      return voice;
    } catch (e) {
      debugPrint('[Prefetch] Lỗi tạo lồng tiếng ngầm: $e');
      return null;
    }
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
    final settings = await SettingsRepository.getInstance();

    // Nếu đã có trong cache
    if (_cachedDocs.containsKey(nextIndex)) {
      final doc = _cachedDocs[nextIndex]!;
      if (settings.isTtsPlaybackEnabled) {
        await ensureTtsGenerated(doc, episodeIndex: nextIndex);
      }
      prefetchStateNotifier.value = PrefetchState(
        episodeIndex: nextIndex,
        status: 'ready',
        progress: 1.0,
        message:
            'Tập $nextIndex đã có sẵn ${settings.isTtsPlaybackEnabled ? "lồng tiếng & vietsub" : "phụ đề"}',
        document: doc,
        videoUrl: _cachedUrls[nextIndex],
      );
      return;
    }

    // Nếu đã có trong Lịch sử trước đó
    final fromHistory = await _findInHistory(nextIndex);
    if (fromHistory != null) {
      if (settings.isTtsPlaybackEnabled) {
        await ensureTtsGenerated(fromHistory, episodeIndex: nextIndex);
      }
      _cachedDocs[nextIndex] = fromHistory;
      prefetchStateNotifier.value = PrefetchState(
        episodeIndex: nextIndex,
        status: 'ready',
        progress: 1.0,
        message:
            'Tập $nextIndex đã có trong lịch sử (${settings.isTtsPlaybackEnabled ? "lồng tiếng" : "vietsub"})',
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

    unawaited(
      ForegroundServiceManager.start(
        title: '🎬 Đang dịch: ${detail.title}',
        message: 'Tập $episodeIndex: Đang kết nối video...',
        progress: 5,
      ),
    );

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

      // Bước 2: Chuẩn bị SubtitlingPipeline theo cấu hình riêng của Hồng Quả
      final settings = await SettingsRepository.getInstance();
      _activePipelines[episodeIndex]?.cancel();
      await _pipelineSubs[episodeIndex]?.cancel();

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
          // Chưa có API key nào -> tự động fallback sang CapCut Free an toàn
          engine = 'capcut';
        }
      }

      final modeText = engine == 'capcut' ? 'CapCut Free' : 'API Online';
      debugPrint('[Prefetch] Tập $episodeIndex dùng chế độ: $modeText ($engine)');

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
      _activePipelines[episodeIndex] = pipeline;

      _pipelineSubs[episodeIndex] = pipeline.progressStream.listen((progress) {
        if (_isDisposed) return;
        final pct = progress.progress.clamp(0.0, 1.0);
        final pctInt = (pct * 100).toInt();
        prefetchStateNotifier.value = PrefetchState(
          episodeIndex: episodeIndex,
          status: 'translating',
          progress: pct,
          message: progress.message.isNotEmpty
              ? progress.message
              : 'Đang dịch Tập $episodeIndex [$modeText] ($pctInt%)...',
          videoUrl: playUrl,
        );
        unawaited(
          ForegroundServiceManager.update(
            title: '🎬 Đang dịch: ${detail.title}',
            message: 'Tập $episodeIndex: ${progress.message.isNotEmpty ? progress.message : "Đang xử lý"} ($pctInt%)',
            progress: pctInt,
            maxProgress: 100,
          ),
        );
      });

      // Bước 3: Chạy quy trình bóc tách âm thanh & dịch phụ đề (cố định zh-CN -> vi-VN)
      // Phim ngắn Hồng Quả trung bình 1.5 - 2 phút (~120000ms)
      final doc = await pipeline.execute(
        videoPath: playUrl,
        totalDurationMs: 120000,
        sourceLanguage: 'zh-CN',
        seriesId: detail.seriesId,
        episodeIndex: episodeIndex,
      );

      if (_isDisposed) {
        completer.complete(null);
        return null;
      }

      if (doc.isEmpty) {
        throw StateError('Không thể tạo phụ đề cho tập $episodeIndex');
      }

      // Bước 4: Tự động tạo lồng tiếng nếu đang bật lồng tiếng AI
      String? appliedTtsVoice;
      if (settings.isTtsPlaybackEnabled) {
        final voice = await ensureTtsGenerated(doc, episodeIndex: episodeIndex);
        if (voice != null) {
          appliedTtsVoice = voice.displayName;
        }
      }

      // Bước 5: Lưu vào Cache và Lịch sử (Ưu tiên đường dẫn file video cục bộ để phát mượt không lag)
      final finalVideoPath = pipeline.lastLocalVideoPath ?? playUrl;
      _cachedDocs[episodeIndex] = doc;
      _cachedUrls[episodeIndex] = finalVideoPath;
      final epTitle = '${detail.title} - Tập $episodeIndex';
      try {
        final historyRepo = await HistoryRepository.getInstance();
        final isPrefetchEp = episodeIndex != _currentPlayingIndex;
        await historyRepo.saveHistory(
          videoPath: finalVideoPath,
          title: epTitle,
          document: doc,
          durationMs: 120000,
          ttsVoice: appliedTtsVoice,
          seriesId: detail.seriesId,
          seriesCover: detail.cover,
          episodeIndex: episodeIndex,
          totalEpisodes: detail.totalEpisodes > 0
              ? detail.totalEpisodes
              : detail.episodes.length,
          isPrefetch: isPrefetchEp,
        );
      } catch (e) {
        debugPrint('[Prefetch] Lỗi lưu history: $e');
      }

      prefetchStateNotifier.value = PrefetchState(
        episodeIndex: episodeIndex,
        status: 'ready',
        progress: 1.0,
        message:
            'Tập $episodeIndex đã sẵn sàng ${settings.isTtsPlaybackEnabled ? "(Lồng tiếng & Sub)" : "(Vietsub)"}!',
        document: doc,
        videoUrl: finalVideoPath,
      );

      unawaited(
        ForegroundServiceManager.update(
          title: '🎬 Hoàn tất: ${detail.title}',
          message: 'Tập $episodeIndex đã dịch xong và sẵn sàng xem!',
          progress: 100,
        ),
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
      _activePipelines.remove(episodeIndex);
      unawaited(_pipelineSubs[episodeIndex]?.cancel());
      _pipelineSubs.remove(episodeIndex);
    }
  }

  /// Lấy hoặc phân giải URL của tập phim
  Future<String?> getOrResolveUrl(int episodeIndex) async {
    final cachedUrl = _cachedUrls[episodeIndex];
    if (cachedUrl != null && cachedUrl.isNotEmpty) {
      final isRemote = cachedUrl.startsWith('http://') ||
          cachedUrl.startsWith('https://');
      if (isRemote ||
          (await File(cachedUrl).exists() &&
              await File(cachedUrl).length() > 1024 * 50)) {
        return cachedUrl;
      }
      // Cache video có thể đã bị dọn tự động sau khi xem các tập tiếp theo.
      _cachedUrls.remove(episodeIndex);
    }

    // 1. Thử tìm nhanh video offline trong Lịch sử trước khi gọi mạng
    await _findInHistory(episodeIndex);
    final historyUrl = _cachedUrls[episodeIndex];
    if (historyUrl != null && historyUrl.isNotEmpty) {
      final isRemote = historyUrl.startsWith('http://') || historyUrl.startsWith('https://');
      if (isRemote ||
          (await File(historyUrl).exists() && await File(historyUrl).length() > 1024 * 50)) {
        return historyUrl;
      }
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
        episodeIndex: episodeIndex,
      );

      final cached = await VideoCacheManager.findCachedFile(
        url: url,
        seriesId: detail.seriesId,
        episodeIndex: episodeIndex,
      );
      final finalPath = cached != null ? cached.path : url;

      _cachedUrls[episodeIndex] = finalPath;
      completer.complete(finalPath);
      return finalPath;
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
      final targetSeriesId = detail.seriesId.trim();
      final targetTitle = detail.title.trim().toLowerCase();

      final item = list.firstWhere(
        (it) {
          if (it.extractedEpisodeIndex != episodeIndex) return false;
          if (targetSeriesId.isNotEmpty && it.seriesId == targetSeriesId) {
            return true;
          }
          if (targetTitle.isNotEmpty) {
            final itSeries = it.extractedSeriesTitle.trim().toLowerCase();
            if (itSeries == targetTitle ||
                it.title.toLowerCase().contains(targetTitle) ||
                targetTitle.contains(itSeries)) {
              return true;
            }
          }
          final epTitle = '${detail.title} - Tập $episodeIndex';
          if (it.title.trim().toLowerCase() == epTitle.toLowerCase()) {
            return true;
          }
          return false;
        },
        orElse: () => throw 'not_found',
      );

      final resolvedVideo = await HistoryRepository.resolveItemVideoPath(item);
      final isLocalVideo = resolvedVideo.isNotEmpty &&
          !resolvedVideo.startsWith('http://') &&
          !resolvedVideo.startsWith('https://');
      if (isLocalVideo &&
          await File(resolvedVideo).exists() &&
          await File(resolvedVideo).length() > 1024 * 50) {
        _cachedUrls[episodeIndex] = resolvedVideo;
      } else if (resolvedVideo.isNotEmpty && !_cachedUrls.containsKey(episodeIndex)) {
        _cachedUrls[episodeIndex] = resolvedVideo;
      }

      final doc = await historyRepo.loadSubtitleDocument(item);
      if (doc != null && doc.isNotEmpty) {
        _cachedDocs[episodeIndex] = doc;
      }
      return doc;
    } catch (_) {
      return null;
    }
  }

  /// Dừng các tác vụ dịch ngầm hiện tại (khi người dùng tắt công tắc AutoPlay)
  void cancelPrefetch() {
    for (final p in _activePipelines.values) {
      p.cancel();
    }
    _activePipelines.clear();
    for (final sub in _pipelineSubs.values) {
      unawaited(sub.cancel());
    }
    _pipelineSubs.clear();
    prefetchStateNotifier.value = null;
    unawaited(ForegroundServiceManager.stop());
  }

  /// Huỷ bỏ các tác vụ ngầm khi đóng trình phát
  void dispose() {
    _isDisposed = true;
    cancelPrefetch();
    prefetchStateNotifier.dispose();
  }
}
