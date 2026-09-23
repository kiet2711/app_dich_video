import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'audio_file_validator.dart';
import 'tts_cache_helper.dart';

import '../../data/api/capcut_tts_client.dart';
import '../../data/model/device_config.dart';
import '../../data/model/subtitle_document.dart';
import '../../data/model/subtitle_item.dart';
import '../../data/model/voice_model.dart';

class TtsFailedItem {
  final int itemId;
  final String text;
  final String reason;
  final String filePath;

  const TtsFailedItem({
    required this.itemId,
    required this.text,
    required this.reason,
    this.filePath = '',
  });
}

class TtsGenerationState {
  final bool isRunning;
  final int completedCount;
  final int totalCount;
  final double speedPerSec;
  final String currentSentence;
  final bool isCancelled;
  final bool isFinished;
  final String? errorMessage;
  final List<TtsFailedItem> failedItems;

  const TtsGenerationState({
    this.isRunning = false,
    this.completedCount = 0,
    this.totalCount = 0,
    this.speedPerSec = 0.0,
    this.currentSentence = '',
    this.isCancelled = false,
    this.isFinished = false,
    this.errorMessage,
    this.failedItems = const [],
  });

  TtsGenerationState copyWith({
    bool? isRunning,
    int? completedCount,
    int? totalCount,
    double? speedPerSec,
    String? currentSentence,
    bool? isCancelled,
    bool? isFinished,
    String? errorMessage,
    List<TtsFailedItem>? failedItems,
  }) {
    return TtsGenerationState(
      isRunning: isRunning ?? this.isRunning,
      completedCount: completedCount ?? this.completedCount,
      totalCount: totalCount ?? this.totalCount,
      speedPerSec: speedPerSec ?? this.speedPerSec,
      currentSentence: currentSentence ?? this.currentSentence,
      isCancelled: isCancelled ?? this.isCancelled,
      isFinished: isFinished ?? this.isFinished,
      errorMessage: errorMessage ?? this.errorMessage,
      failedItems: failedItems ?? this.failedItems,
    );
  }
}

class TtsGenerationManager {
  static final TtsGenerationManager _instance = TtsGenerationManager._();
  factory TtsGenerationManager() => _instance;
  TtsGenerationManager._();

  final ValueNotifier<TtsGenerationState> progress =
      ValueNotifier<TtsGenerationState>(const TtsGenerationState());

  bool _isCancelled = false;

  static bool isPronounceable(String text) =>
      RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(text);

  static bool isTrulyBlankSubtitle(SubtitleItem item) =>
      !isPronounceable(item.originalText) &&
      !isPronounceable(item.translatedText);

  void cancel() {
    if (!progress.value.isRunning) return;
    _isCancelled = true;
    progress.value = progress.value.copyWith(
      isRunning: false,
      isCancelled: true,
      isFinished: false,
      currentSentence: 'Đã hủy tiến trình lồng tiếng',
    );
  }

  static String _md5Text(String text) {
    return md5.convert(utf8.encode(text)).toString().substring(0, 10);
  }

  static Future<Directory> getCacheDir(String voiceType) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/tts_cache_$voiceType');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String _textFor(SubtitleItem item) {
    return item.translatedText.trim().isNotEmpty
        ? item.translatedText.trim()
        : item.originalText.trim();
  }

  static Future<File> _audioFileFor(
    SubtitleItem item,
    String voiceType, [
    SubtitleDocument? document,
  ]) async {
    if (document != null) {
      return TtsCacheHelper.getAudioFile(document, item, voiceType);
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/tts_cache_$voiceType');
    if (!await dir.exists()) await dir.create(recursive: true);
    final hash = _md5Text(_textFor(item));
    return File('${dir.path}/sub_${item.id}_$hash.mp3');
  }

  static Future<bool> _validateAndAttach(SubtitleItem item, File file) async {
    final result = await AudioFileValidator.validate(file);
    if (!result.isValid || result.durationMs <= 0) return false;
    _attachAudio(item, file, result.durationMs);
    return true;
  }

  static Future<void> linkAudioFiles(
    SubtitleDocument document,
    String voiceType,
  ) async {
    await TtsCacheHelper.linkAudioFiles(document, voiceType);
  }

  Future<void> generateAll({
    required SubtitleDocument document,
    required VoiceItem voice,
    int threadCount = 50,
    bool forceRegenerate = false,
  }) async {
    document.reindex();
    _isCancelled = false;
    final targets = <SubtitleItem>[];
    for (final item in document.items) {
      if (isTrulyBlankSubtitle(item)) continue;
      final file = await _audioFileFor(item, voice.voiceType, document);
      final valid = !forceRegenerate && await _validateAndAttach(item, file);
      if (!valid) targets.add(item);
    }

    if (targets.isEmpty) {
      await _finishFromAudit(document, voice, const {});
      return;
    }
    await _runBatch(
      document: document,
      voice: voice,
      items: targets,
      threadCount: threadCount,
      forceRegenerate: forceRegenerate,
    );
  }

  Future<void> retryFailedItems({
    required SubtitleDocument document,
    required VoiceItem voice,
    required Map<int, String> editedTexts,
    int threadCount = 50,
  }) async {
    final failedIds = progress.value.failedItems
        .map((failure) => failure.itemId)
        .toSet();
    _applyEditedTexts(document, editedTexts);
    final targets = document.items
        .where(
          (item) => failedIds.contains(item.id) && !isTrulyBlankSubtitle(item),
        )
        .toList(growable: false);
    if (targets.isEmpty) return;
    _isCancelled = false;
    await _runBatch(
      document: document,
      voice: voice,
      items: targets,
      threadCount: threadCount,
      forceRegenerate: true,
    );
  }

  Future<void> retryFailedItem({
    required SubtitleDocument document,
    required VoiceItem voice,
    required int itemId,
    required String editedText,
    int threadCount = 50,
  }) async {
    _applyEditedTexts(document, {itemId: editedText});
    final item = document.items
        .where((entry) => entry.id == itemId)
        .firstOrNull;
    if (item == null || isTrulyBlankSubtitle(item)) return;
    _isCancelled = false;
    await _runBatch(
      document: document,
      voice: voice,
      items: [item],
      threadCount: threadCount,
      forceRegenerate: true,
    );
  }

  Future<void> skipFailedItems({
    required SubtitleDocument document,
    required VoiceItem voice,
  }) async {
    _isCancelled = false;
    await linkAudioFiles(document, voice.voiceType);
    final validTargetCount = document.items
        .where((item) => !isTrulyBlankSubtitle(item))
        .length;
    final linkedCount = document.items
        .where((item) => item.audioFilePath?.isNotEmpty == true)
        .length;
    progress.value = TtsGenerationState(
      isFinished: true,
      completedCount: linkedCount,
      totalCount: validTargetCount,
      currentSentence:
          'Đã bỏ qua các câu lỗi. Đã sẵn sàng phát video ($linkedCount câu)!',
    );
  }

  Future<void> _runBatch({
    required SubtitleDocument document,
    required VoiceItem voice,
    required List<SubtitleItem> items,
    required int threadCount,
    required bool forceRegenerate,
  }) async {
    final total = items.length;
    final effectiveThreads = min(threadCount.clamp(1, 100), total);
    final failureReasons = <int, String>{};
    var queueIndex = 0;
    var processed = 0;
    var succeeded = 0;
    var lastUiUpdate = 0;
    final startedAt = DateTime.now().millisecondsSinceEpoch;

    progress.value = TtsGenerationState(
      isRunning: true,
      totalCount: total,
      currentSentence:
          'Đang khởi tạo $effectiveThreads luồng tổng hợp (${voice.displayName})...',
    );

    void notifyProgress({required String text, bool force = false}) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (force || now - lastUiUpdate >= 200 || processed >= total) {
        lastUiUpdate = now;
        _updateRunningProgress(
          processed: processed,
          total: total,
          succeeded: succeeded,
          text: text,
          startedAt: startedAt,
          force: true,
        );
      }
    }

    Future<void> worker(int workerIndex) async {
      final client = CapCutTtsClient(device: DeviceConfig().randomize());
      if (workerIndex > 0) {
        await Future<void>.delayed(Duration(milliseconds: workerIndex * 15));
      }
      while (!_isCancelled) {
        final index = queueIndex++;
        if (index >= items.length) return;
        final item = items[index];
        final text = _textFor(item);

        if (!isPronounceable(text)) {
          item.audioFilePath = null;
          item.audioDurationMs = 0;
          failureReasons[item.id] =
              'Bản dịch bị nuốt/chỉ chứa dấu câu (${text.isEmpty ? 'trống' : text})';
          processed++;
          notifyProgress(text: text, force: processed >= total);
          continue;
        }

        try {
          final destination =
              await _audioFileFor(item, voice.voiceType, document);
          final valid =
              !forceRegenerate && await _validateAndAttach(item, destination);
          if (!valid) {
            await client.generateSpeechToFile(
              text: text,
              voiceType: voice.voiceType,
              resourceId: voice.resourceId,
              rate: '1.0',
              destFile: destination,
            );
          }
          if (!await _validateAndAttach(item, destination)) {
            throw const FormatException('File âm thanh không hợp lệ');
          }
          succeeded++;
        } catch (error) {
          item.audioFilePath = null;
          item.audioDurationMs = 0;
          failureReasons[item.id] = _readableError(error);
        } finally {
          processed++;
          notifyProgress(text: text, force: processed >= total);
        }
      }
    }

    await Future.wait(
      List.generate(effectiveThreads, (index) => worker(index)),
    );
    if (!_isCancelled) {
      await _finishFromAudit(document, voice, failureReasons);
    }
  }

  void _updateRunningProgress({
    required int processed,
    required int total,
    required int succeeded,
    required String text,
    required int startedAt,
    required bool force,
  }) {
    if (!force || _isCancelled) return;
    final elapsed =
        (DateTime.now().millisecondsSinceEpoch - startedAt) / 1000.0;
    final failed = processed - succeeded;
    progress.value = progress.value.copyWith(
      completedCount: processed,
      speedPerSec: elapsed > 0.5 ? processed / elapsed : 0,
      currentSentence: failed > 0
          ? 'Đã xử lý $processed/$total câu ($failed câu đang lỗi)'
          : 'Đã xử lý $processed/$total: ${_shortText(text, 35)}',
    );
  }

  Future<void> _finishFromAudit(
    SubtitleDocument document,
    VoiceItem voice,
    Map<int, String> failureReasons,
  ) async {
    final failures = <TtsFailedItem>[];
    var successCount = 0;
    var validTargetCount = 0;

    for (final item in document.items) {
      if (isTrulyBlankSubtitle(item)) continue;
      validTargetCount++;
      final text = _textFor(item);
      final file = await _audioFileFor(item, voice.voiceType, document);
      if (isPronounceable(text) && await _validateAndAttach(item, file)) {
        successCount++;
        continue;
      }
      final reason = !isPronounceable(text)
          ? 'Bản dịch bị nuốt/chỉ chứa dấu câu (${text.isEmpty ? 'trống' : text})'
          : failureReasons[item.id] ?? 'Thiếu hoặc hỏng file âm thanh';
      failures.add(
        TtsFailedItem(
          itemId: item.id,
          text: text.isEmpty ? item.originalText : text,
          reason: reason,
          filePath: file.path,
        ),
      );
    }

    final finished = failures.isEmpty;
    progress.value = TtsGenerationState(
      completedCount: successCount,
      totalCount: validTargetCount,
      isFinished: finished,
      currentSentence: finished
          ? 'Đã hoàn thành lồng tiếng toàn bộ $successCount câu thoại!'
          : 'Đã tạo $successCount/$validTargetCount câu. '
                'Còn ${failures.length} câu cần xử lý.',
      failedItems: List.unmodifiable(failures),
      errorMessage: failures.firstOrNull?.reason,
    );
  }

  static void _applyEditedTexts(
    SubtitleDocument document,
    Map<int, String> editedTexts,
  ) {
    for (final entry in editedTexts.entries) {
      final cleanText = entry.value.trim();
      if (cleanText.isEmpty) continue;
      final item = document.items
          .where((candidate) => candidate.id == entry.key)
          .firstOrNull;
      if (item != null) item.translatedText = cleanText;
    }
  }

  Future<File?> generateSingle({
    required SubtitleItem item,
    required VoiceItem voice,
    SubtitleDocument? document,
  }) async {
    final text = _textFor(item);
    if (!isPronounceable(text)) return null;
    final destination = await _audioFileFor(item, voice.voiceType, document);
    await CapCutTtsClient(device: DeviceConfig().randomize())
        .generateSpeechToFile(
          text: text,
          voiceType: voice.voiceType,
          resourceId: voice.resourceId,
          rate: '1.0',
          destFile: destination,
        );
    if (!await _validateAndAttach(item, destination)) {
      throw const FormatException('File âm thanh không hợp lệ');
    }
    return destination;
  }

  static void _attachAudio(SubtitleItem item, File file, int durationMs) {
    item.audioFilePath = file.path;
    item.audioDurationMs = durationMs;
    final srtDurationMs = max(200, item.endMs - item.startMs);
    if (durationMs > srtDurationMs) {
      final factor = (durationMs / srtDurationMs).clamp(1.0, 2.2);
      item.playbackSpeed = (factor * 10).round() / 10.0;
    } else {
      item.playbackSpeed = 1.0;
    }
  }

  static String _readableError(Object error) => error.toString().replaceFirst(
    RegExp(r'^[A-Za-z]+Exception(?:\([^)]*\))?:\s*'),
    '',
  );

  static String _shortText(String text, int maxLength) =>
      text.length <= maxLength ? text : '${text.substring(0, maxLength)}…';
}
