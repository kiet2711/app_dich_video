import '../media/network_header_helper.dart';
import '../media/multi_thread_downloader.dart';
import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../data/api/capcut_stt_client.dart';
import '../../data/api/capcut_vod_uploader.dart';
import '../../data/api/gemini_translator.dart';
import '../../data/model/device_config.dart';
import '../../data/model/process_progress.dart';
import '../../data/model/subtitle_document.dart';
import '../../data/model/subtitle_item.dart';
import '../../data/repository/settings_repository.dart';
import '../media/audio_chunker.dart';
import '../media/bilibili_resolver.dart';

class SubtitlingPipeline {
  final List<String> apiKeys;
  final String translationEngine; // "capcut", "gemini-2.5-flash-lite", "none"
  final String stylePreset;
  final String customPrompt;
  final String targetLanguage;
  final int geminiThreadCount;

  final _progressController = StreamController<ProcessProgress>.broadcast();
  Stream<ProcessProgress> get progressStream => _progressController.stream;

  bool _isCancelled = false;

  SubtitlingPipeline({
    required this.apiKeys,
    this.translationEngine = 'gemini-3.5-flash-lite',
    this.stylePreset = 'Zhihu',
    this.customPrompt = '',
    this.targetLanguage = 'vi-VN',
    this.geminiThreadCount = 2,
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
      var extractionPath = videoPath;
      SubtitleDocument? sourceDocument;

      if (BilibiliResolver.isBilibiliPageUrl(videoPath)) {
        final resolver = BilibiliResolver();
        final settings = await SettingsRepository.getInstance();
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

        // Tự động kiểm tra phụ đề có sẵn không phụ thuộc engine
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
        } catch (_) {}

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
          final settings = await SettingsRepository.getInstance();
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
          progressCallback: (pct, msg) {
            _emit(
              ProcessProgress(
                stage: ProcessStage.extractingAudio,
                progress: pct,
                message: msg,
              ),
            );
          },
        );

        // -------------------------------------------------------------
    // GIAI ĐOẠN 2 & 3: UPLOAD VOD VÀ STT CAPCUT CHO TỪNG CHUNK
        // -------------------------------------------------------------
        final totalChunks = chunks.length;
        for (var i = 0; i < totalChunks; i++) {
      if (_isCancelled) throw Exception('Đã huỷ tác vụ');
          final chunk = chunks[i];

          // 2. Upload VOD
          final device = DeviceConfig().randomize();
          final uploader = CapCutVodUploader(device: device);

          _emit(
            ProcessProgress(
              stage: ProcessStage.uploadingVod,
              progress: 0.20 + (i / totalChunks) * 0.30,
              message:
        'Đang tải phân đoạn ${i + 1}/$totalChunks lên CapCut Cloud...',
            ),
          );

          final uploadResult = await uploader.uploadFile(
            chunk.file,
            isCancelled: () => _isCancelled,
            progressCallback: (pct, msg) {
              final overall =
                  0.20 +
                  (i / totalChunks) * 0.30 +
                  (pct * (0.30 / totalChunks));
              _emit(
                ProcessProgress(
                  stage: ProcessStage.uploadingVod,
                  progress: overall,
      message: '[Đoạn ${i + 1}/$totalChunks] $msg',
                ),
              );
            },
          );

          // 3. STT CapCut
      if (_isCancelled) throw Exception('Đã huỷ tác vụ');
          final sttClient = CapCutSttClient(device: device);

          _emit(
            ProcessProgress(
              stage: ProcessStage.sttTranscribing,
              progress: 0.50 + (i / totalChunks) * 0.25,
              message:
        'CapCut đang nhận diện giọng nói [Đoạn ${i + 1}/$totalChunks]...',
            ),
          );

          final chunkDoc = await sttClient.transcribeAudio(
            audioVid: uploadResult.vid,
            audioMd5: uploadResult.md5,
            durationMs: chunk.durationMs,
            language: sourceLanguage,
            useTranslation: translationEngine == 'capcut',
            translationLanguage: targetLanguage,
            timeOffsetMs: chunk.startMs,
            isCancelled: () => _isCancelled,
            progressCallback: (pct, msg) {
              final overall =
                  0.50 +
                  (i / totalChunks) * 0.25 +
                  (pct * (0.25 / totalChunks));
              _emit(
                ProcessProgress(
                  stage: ProcessStage.sttTranscribing,
                  progress: overall,
      message: '[Đoạn ${i + 1}/$totalChunks] $msg',
                ),
              );
            },
          );

          allItems.addAll(chunkDoc.items);
        }
      }

      final fullDoc = SubtitleDocument(allItems);
      fullDoc.reindex();

      // -------------------------------------------------------------
    // GIAI ĐOẠN 4: DỊCH PHỤ ĐỀ BẰNG GEMINI AI
      // -------------------------------------------------------------
      if (translationEngine.startsWith('gemini') && fullDoc.isNotEmpty) {
    if (_isCancelled) throw Exception('Đã huỷ tác vụ');
        _emit(
          const ProcessProgress(
            stage: ProcessStage.aiTranslating,
            progress: 0.75,
      message: 'Bắt đầu dịch phụ đề theo ngữ cảnh với Gemini AI...',
          ),
        );

        final translator = GeminiTranslator(
          apiKeys: apiKeys,
          modelId: translationEngine,
        );

        await translator.translateSubtitles(
          document: fullDoc,
          stylePreset: stylePreset,
          customPrompt: customPrompt,
          targetLanguage: targetLanguage,
          threadCount: geminiThreadCount,
          isCancelled: () => _isCancelled,
          progressCallback: (pct, msg) {
            final overall = 0.75 + (pct * 0.23);
            _emit(
              ProcessProgress(
                stage: ProcessStage.aiTranslating,
                progress: overall,
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
