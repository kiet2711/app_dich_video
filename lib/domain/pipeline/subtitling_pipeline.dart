import '../media/network_header_helper.dart';
import '../media/multi_thread_downloader.dart';
import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../data/api/capcut_stt_client.dart';
import '../../data/api/capcut_vod_uploader.dart';
import '../../data/api/gemini_translator.dart';
import '../../data/api/groq_translator.dart';
import '../../data/model/device_config.dart';
import '../../data/model/process_progress.dart';
import '../../data/model/subtitle_document.dart';
import '../../data/model/subtitle_item.dart';
import '../../data/repository/settings_repository.dart';
import '../ai/ai_model_registry.dart';
import '../ai/smart_ai_translator.dart';
import '../media/audio_chunker.dart';
import '../media/bilibili_resolver.dart';

class SubtitlingPipeline {
  final List<String> apiKeys;
  final List<String> groqApiKeys;
  final String translationEngine; // "capcut", "gemini-...", "openai/...", "none"
  final String stylePreset;
  final String customPrompt;
  final String targetLanguage;
  final int geminiThreadCount;
  final int? geminiBatchSize;
  final int groqThreadCount;
  final int? groqBatchSize;

  final _progressController = StreamController<ProcessProgress>.broadcast();
  Stream<ProcessProgress> get progressStream => _progressController.stream;

  bool _isCancelled = false;

  SubtitlingPipeline({
    required this.apiKeys,
    this.groqApiKeys = const [],
    this.translationEngine = 'gemini-3.5-flash-lite',
    this.stylePreset = 'Zhihu',
    this.customPrompt = '',
    this.targetLanguage = 'vi-VN',
    this.geminiThreadCount = 2,
    this.geminiBatchSize,
    this.groqThreadCount = 3,
    this.groqBatchSize,
  });

  void cancel() {
    _isCancelled = true;
    _emit(
      const ProcessProgress(
        stage: ProcessStage.cancelled,
        message: 'Đã huỷ bởi người dùng.',
      ),
    );
  }

  void _emit(ProcessProgress p) {
    if (!_progressController.isClosed) {
      _progressController.add(p);
    }
  }

  Future<SubtitleDocument> execute({
    required String videoPath,
    required int totalDurationMs,
    String sourceLanguage = 'zh-CN',
    File? outputSrtFile,
  }) async {
    _isCancelled = false;
    if (totalDurationMs <= 0) {
      throw ArgumentError.value(
        totalDurationMs,
        'totalDurationMs',
        'Thời lượng media phải lớn hơn 0',
      );
    }
    if (translationEngine.startsWith('gemini') && apiKeys.isEmpty) {
      throw StateError('Đã chọn Gemini nhưng chưa cấu hình API Key.');
    }
    final tempBase = await getTemporaryDirectory();
    final sessionDir = Directory(
      '${tempBase.path}/sub_session_${DateTime.now().millisecondsSinceEpoch}_${const Uuid().v4().substring(0, 6)}',
    );
    await sessionDir.create(recursive: true);

    try {
      final settings = await SettingsRepository.getInstance();
      var extractionPath = videoPath;
      SubtitleDocument? sourceDocument;

      if (BilibiliResolver.isBilibiliPageUrl(videoPath)) {
        final resolver = BilibiliResolver();
        _emit(
          const ProcessProgress(
            stage: ProcessStage.extractingAudio,
            progress: 0.02,
      message: 'Đang phân tích link Bilibili...',
          ),
        );
        final target = await resolver.resolveUrl(videoPath);
        final details = await resolver.getVideoDetails(
          target,
          settings.bilibiliSessData,
        );

        // Tự động kiểm tra phụ đề có sẵn:
        // - Nếu chọn AI (Gemini/Groq) hoặc 'none': Dùng phụ đề Bilibili có sẵn để dịch siêu tốc mà không cần tải audio.
        // - Nếu chọn 'capcut': Vì CapCut chỉ dịch được khi nghe audio (không hỗ trợ dịch text thuần),
        //   ta bỏ qua phụ đề text có sẵn và tải audio DASH để CapCut STT bóc tách và dịch song ngữ sang tiếng Việt.
        final shouldUseExistingSubtitles = translationEngine != 'capcut';
        if (shouldUseExistingSubtitles) {
          try {
            final subtitles = await resolver.getSubtitles(
              details,
              settings.bilibiliSessData,
            );
            final manualSubtitles = subtitles
                .where((item) => !item.isAi)
                .toList();
            final preferred = manualSubtitles.isNotEmpty
                ? manualSubtitles.first
                : (subtitles.isNotEmpty ? subtitles.first : null);
            if (preferred != null) {
              sourceDocument = await resolver.downloadSubtitle(preferred);
              if (sourceDocument != null) {
                _emit(
                  ProcessProgress(
                    stage: ProcessStage.extractingAudio,
                    progress: 0.20,
                    message:
          'Đã nạp ${sourceDocument.size} câu phụ đề Bilibili (${preferred.languageName}).',
                  ),
                );
              }
            }
          } on BilibiliSubtitleLoginRequiredException catch (error) {
            _emit(
              ProcessProgress(
                stage: ProcessStage.extractingAudio,
                progress: 0.03,
                message: '$error Đang chuyển sang nhận diện âm thanh.',
              ),
            );
          } catch (_) {}
        } else {
          _emit(
            const ProcessProgress(
              stage: ProcessStage.extractingAudio,
              progress: 0.03,
              message:
                  'Đã chọn CapCut: Đang tải luồng âm thanh để CapCut nghe & dịch song ngữ...',
            ),
          );
        }

        if (sourceDocument == null) {
          final audioUrl = await resolver.getAudioUrl(
            details,
            settings.bilibiliSessData,
          );
          final downloadedAudio = File(
            '${sessionDir.path}${Platform.pathSeparator}bilibili_audio.m4a',
          );
          await resolver.downloadAudio(
            audioUrl,
            downloadedAudio,
            settings.bilibiliSessData,
            concurrency: settings.downloadThreadCount,
            onProgress: (progress, message) {
              _emit(
                ProcessProgress(
                  stage: ProcessStage.extractingAudio,
                  progress: 0.03 + progress * 0.15,
                  message: message,
                ),
              );
            },
          );
          extractionPath = downloadedAudio.path;
        }
      }

      final allItems = <SubtitleItem>[];
      if (sourceDocument != null) {
        allItems.addAll(sourceDocument.items);
        _emit(
          ProcessProgress(
            stage: ProcessStage.extractingAudio,
            progress: 0.50,
            message: 'Đã nạp ${sourceDocument.size} câu phụ đề có sẵn! Chuẩn bị dịch...',
          ),
        );
      } else {
        // Nếu là URL video online thông thường (không phải Bilibili), tải trước qua MultiThreadDownloader
        if (NetworkHeaderHelper.isRemoteUrl(extractionPath)) {
          _emit(
            const ProcessProgress(
              stage: ProcessStage.extractingAudio,
              progress: 0.03,
              message: 'Đang tải video trực tuyến để bóc tách âm thanh...',
            ),
          );
          final tempRemoteFile = File(
            '${sessionDir.path}${Platform.pathSeparator}downloaded_remote_stream.mp4',
          );
          final headers = NetworkHeaderHelper.getHeadersForUrl(extractionPath, settings.bilibiliSessData);
          await MultiThreadDownloader.downloadFile(
            url: extractionPath,
            outputFile: tempRemoteFile,
            headers: headers,
            concurrency: settings.downloadThreadCount,
            progressCallback: (pct, msg) {
              _emit(
                ProcessProgress(
                  stage: ProcessStage.extractingAudio,
                  progress: 0.03 + pct * 0.12,
                  message: msg,
                ),
              );
            },
          );
          extractionPath = tempRemoteFile.path;
        }

        // GIAI ĐOẠN 1: TÁCH ÂM THANH SANG M4A
        if (_isCancelled) throw Exception('Đã huỷ tác vụ');
        _emit(
          const ProcessProgress(
            stage: ProcessStage.extractingAudio,
            progress: 0.05,
            message: 'Đang trích xuất luồng âm thanh từ video...',
          ),
        );

        final chunks = await AudioChunker.sliceMedia(
          videoPath: extractionPath,
          totalDurationMs: totalDurationMs,
          tempDir: sessionDir,
          chunkDurationSec: settings.audioChunkDurationSec,
          concurrency: settings.audioSliceConcurrency,
          progressCallback: (pct, msg) {
            _emit(
              ProcessProgress(
                stage: ProcessStage.extractingAudio,
                progress: (0.05 + pct * 0.15).clamp(0.05, 0.20),
                message: msg,
              ),
            );
          },
        );

        // -------------------------------------------------------------
        // GIAI ĐOẠN 2 & 3: UPLOAD VOD VÀ STT CAPCUT ĐA LUỒNG SONG SONG
        // -------------------------------------------------------------
        final totalChunks = chunks.length;
        final chunkResults = List<List<SubtitleItem>?>.filled(totalChunks, null);
        var nextChunkIndex = 0;
        var completedChunks = 0;
        final concurrency = settings.capcutSttConcurrency.clamp(1, totalChunks);

        _emit(
          ProcessProgress(
            stage: ProcessStage.uploadingVod,
            progress: 0.20,
            message: totalChunks > 1
                ? 'Bắt đầu xử lý đa luồng ($concurrency luồng) cho $totalChunks phân đoạn...'
                : 'Bắt đầu tải lên CapCut Cloud...',
          ),
        );

        Future<void> sttWorker(int workerId) async {
          while (nextChunkIndex < totalChunks) {
            if (_isCancelled) throw Exception('Đã huỷ tác vụ');
            final idx = nextChunkIndex++;
            if (idx >= totalChunks) break;
            final chunk = chunks[idx];

            final device = DeviceConfig().randomize();
            final uploader = CapCutVodUploader(device: device);

            // 2. Upload VOD
            final uploadResult = await uploader.uploadFile(
              chunk.file,
              isCancelled: () => _isCancelled,
              progressCallback: (pct, msg) {},
            );

            // 3. STT CapCut
            if (_isCancelled) throw Exception('Đã huỷ tác vụ');
            final sttClient = CapCutSttClient(device: device);

            final chunkDoc = await sttClient.transcribeAudio(
              audioVid: uploadResult.vid,
              audioMd5: uploadResult.md5,
              durationMs: chunk.durationMs,
              language: sourceLanguage,
              useTranslation: translationEngine == 'capcut',
              translationLanguage: targetLanguage,
              timeOffsetMs: chunk.startMs,
              isCancelled: () => _isCancelled,
              progressCallback: (pct, msg) {},
            );

            chunkResults[idx] = chunkDoc.items;
            completedChunks++;

            final overallProgress =
                (0.20 + (completedChunks / totalChunks) * 0.50).clamp(0.20, 0.70);
            _emit(
              ProcessProgress(
                stage: ProcessStage.sttTranscribing,
                progress: overallProgress,
                message: totalChunks > 1
                    ? 'CapCut STT: Đã hoàn tất $completedChunks/$totalChunks đoạn (${(completedChunks / totalChunks * 100).round()}%)...'
                    : 'CapCut đã hoàn tất nhận diện âm thanh!',
              ),
            );
          }
        }

        final activeWorkers = concurrency;
        final workers = List.generate(activeWorkers, (id) => sttWorker(id + 1));
        await Future.wait(workers);

        for (var i = 0; i < totalChunks; i++) {
          if (chunkResults[i] != null) {
            allItems.addAll(chunkResults[i]!);
          }
        }
      }

      final fullDoc = SubtitleDocument(allItems);
      fullDoc.reindex();

      // -------------------------------------------------------------
      // GIAI ĐOẠN 4: DỊCH PHỤ ĐỀ BẰNG AI THÔNG MINH ĐA TẦNG
      // -------------------------------------------------------------
      final isAi = AiModelRegistry.isAiTranslationModel(translationEngine);
      if (isAi && fullDoc.isNotEmpty) {
        if (_isCancelled) throw Exception('Đã huỷ tác vụ');
        _emit(
          const ProcessProgress(
            stage: ProcessStage.aiTranslating,
            progress: 0.70,
            message: 'Bắt đầu dịch phụ đề thông minh với AI đa tầng...',
          ),
        );

        final effectiveGeminiKeys = apiKeys.isNotEmpty ? apiKeys : settings.geminiApiKeys;
        final effectiveGroqKeys = groqApiKeys.isNotEmpty ? groqApiKeys : settings.groqApiKeys;
        final effectiveThreadCount = translationEngine.startsWith('gemini')
            ? geminiThreadCount
            : groqThreadCount;
        final effectiveBatchSize = translationEngine.startsWith('gemini')
            ? (geminiBatchSize ?? settings.geminiBatchSize)
            : (groqBatchSize ?? settings.groqBatchSize);

        final smartTranslator = SmartAiTranslator(
          geminiKeys: effectiveGeminiKeys,
          groqKeys: effectiveGroqKeys,
          initialModelId: translationEngine,
          enableSmartModelFallback: settings.enableSmartModelFallback,
          enableCrossProviderFallback: settings.enableCrossProviderFallback,
          enableDualModelBalancing: settings.enableDualModelBalancing,
        );

        await smartTranslator.translateSubtitles(
          document: fullDoc,
          stylePreset: stylePreset,
          customPrompt: customPrompt,
          targetLanguage: targetLanguage,
          chunkSize: effectiveBatchSize,
          threadCount: effectiveThreadCount,
          isCancelled: () => _isCancelled,
          progressCallback: (pct, msg) {
            final overall = 0.70 + (pct * 0.28);
            _emit(
              ProcessProgress(
                stage: ProcessStage.aiTranslating,
                progress: overall.clamp(0.70, 0.98),
                message: msg,
              ),
            );
          },
        );
      }

      if (outputSrtFile != null) {
        await fullDoc.saveToFile(outputSrtFile);
      }

      _emit(
        ProcessProgress(
          stage: ProcessStage.completed,
          progress: 1.0,
      message: 'Hoàn tất xử lý phụ đề!',
          resultDocument: fullDoc,
        ),
      );

      return fullDoc;
    } catch (e) {
      if (!_isCancelled) {
        _emit(
          ProcessProgress(
            stage: ProcessStage.error,
            message: 'Lỗi: $e',
            error: e,
          ),
        );
      }
      rethrow;
    } finally {
      try {
        if (await sessionDir.exists()) {
          await sessionDir.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  void dispose() {
    _progressController.close();
  }
}
