import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/api/capcut_tts_client.dart';
import '../../data/model/subtitle_document.dart';
import '../../data/model/subtitle_item.dart';
import '../../data/model/voice_model.dart';

class TtsGenerationState {
  final bool isRunning;
  final int completedCount;
  final int totalCount;
  final double speedPerSec;
  final String currentSentence;
  final Map<int, String> failedItems;

  const TtsGenerationState({
    this.isRunning = false,
    this.completedCount = 0,
    this.totalCount = 0,
    this.speedPerSec = 0.0,
    this.currentSentence = '',
    this.failedItems = const {},
  });

  TtsGenerationState copyWith({
    bool? isRunning,
    int? completedCount,
    int? totalCount,
    double? speedPerSec,
    String? currentSentence,
    Map<int, String>? failedItems,
  }) {
    return TtsGenerationState(
      isRunning: isRunning ?? this.isRunning,
      completedCount: completedCount ?? this.completedCount,
      totalCount: totalCount ?? this.totalCount,
      speedPerSec: speedPerSec ?? this.speedPerSec,
      currentSentence: currentSentence ?? this.currentSentence,
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

  void cancel() {
    _isCancelled = true;
  }

  static String _md5Text(String text) {
    return md5.convert(utf8.encode(text)).toString().substring(0, 10);
  }

  static Future<Directory> getCacheDir(String voiceType) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/tts_cache_$voiceType');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<void> linkAudioFiles(
    SubtitleDocument document,
    String voiceType,
  ) async {
    final cacheDir = await getCacheDir(voiceType);
    for (final item in document.items) {
      final text = item.translatedText.trim().isNotEmpty
          ? item.translatedText.trim()
          : item.originalText.trim();
      if (text.isEmpty) continue;

      final hash = _md5Text(text);
      final file = File('${cacheDir.path}/sub_${item.id}_$hash.mp3');
      if (await file.exists() && await file.length() > 200) {
        item.audioFilePath = file.path;
        if (item.audioDurationMs <= 0) {
          final srtDuration = max(200, item.endMs - item.startMs);
          item.audioDurationMs = srtDuration;
          item.playbackSpeed = 1.0;
        }
      } else {
        item.audioFilePath = null;
      }
    }
  }

  Future<void> generateAll({
    required SubtitleDocument document,
    required VoiceItem voice,
    int threadCount = 50,
    bool forceRegenerate = false,
  }) async {
    _isCancelled = false;
    final items = document.items;
    final total = items.length;
    if (total == 0) return;

    final failedMap = <int, String>{};
    progress.value = TtsGenerationState(
      isRunning: true,
      totalCount: total,
      completedCount: 0,
      currentSentence: 'Đang chuẩn bị tạo $total câu...',
      failedItems: failedMap,
    );

    final cacheDir = await getCacheDir(voice.voiceType);
    final client = CapCutTtsClient();
    final effectiveThreads = threadCount.clamp(1, 100);

    var completed = 0;
    var queueIdx = 0;
    final startTime = DateTime.now().millisecondsSinceEpoch;

    Future<void> worker() async {
      while (!_isCancelled) {
        if (queueIdx >= items.length) break;
        final idx = queueIdx++;
        if (idx >= items.length) break;
        final item = items[idx];

        final text = item.translatedText.trim().isNotEmpty
            ? item.translatedText.trim()
            : item.originalText.trim();

        if (text.isEmpty) {
          completed++;
          continue;
        }

        final hash = _md5Text(text);
        final destFile = File('${cacheDir.path}/sub_${item.id}_$hash.mp3');

        try {
          final needGen = forceRegenerate ||
              !await destFile.exists() ||
              await destFile.length() < 200;

          if (needGen) {
            await client.generateSpeechToFile(
              text: text,
              voiceType: voice.voiceType,
              resourceId: voice.resourceId,
              rate: '1.0',
              destFile: destFile,
            );
          }

          var durationMs = 0;
          try {
            final tempPlayer = AudioPlayer();
            final dur = await tempPlayer.setFilePath(destFile.path);
            durationMs = dur?.inMilliseconds ?? 0;
            await tempPlayer.dispose();
          } catch (_) {
            durationMs = max(200, item.endMs - item.startMs);
          }

          item.audioFilePath = destFile.path;
          item.audioDurationMs = durationMs > 0 ? durationMs : (item.endMs - item.startMs);
          final srtDurationMs = max(200, item.endMs - item.startMs);
          if (item.audioDurationMs > srtDurationMs) {
            final factor = (item.audioDurationMs / srtDurationMs).clamp(1.0, 2.2);
            item.playbackSpeed = (factor * 10).round() / 10.0;
          } else {
            item.playbackSpeed = 1.0;
          }
        } catch (e) {
          failedMap[item.id] = e.toString();
          item.audioFilePath = null;
        }

        completed++;
        final now = DateTime.now().millisecondsSinceEpoch;
        final elapsedSec = (now - startTime) / 1000.0;
        final speed = elapsedSec > 0.5 ? completed / elapsedSec : 0.0;

        progress.value = progress.value.copyWith(
          completedCount: completed,
          speedPerSec: speed,
          currentSentence: 'Đã tạo $completed/$total câu (${failedMap.length} lỗi)',
          failedItems: Map.unmodifiable(failedMap),
        );
      }
    }

    final workers = List.generate(min(effectiveThreads, total), (_) => worker());
    await Future.wait(workers);

    progress.value = progress.value.copyWith(
      isRunning: false,
      currentSentence: _isCancelled
          ? 'Đã hủy bởi người dùng'
          : 'Hoàn tất $completed/$total câu!',
    );
  }

  Future<File?> generateSingle({
    required SubtitleItem item,
    required VoiceItem voice,
  }) async {
    final text = item.translatedText.trim().isNotEmpty
        ? item.translatedText.trim()
        : item.originalText.trim();
    if (text.isEmpty) return null;

    final cacheDir = await getCacheDir(voice.voiceType);
    final hash = _md5Text(text);
    final destFile = File('${cacheDir.path}/sub_${item.id}_$hash.mp3');

    final client = CapCutTtsClient();
    await client.generateSpeechToFile(
      text: text,
      voiceType: voice.voiceType,
      resourceId: voice.resourceId,
      rate: '1.0',
      destFile: destFile,
    );

    var durationMs = 0;
    try {
      final tempPlayer = AudioPlayer();
      final dur = await tempPlayer.setFilePath(destFile.path);
      durationMs = dur?.inMilliseconds ?? 0;
      await tempPlayer.dispose();
    } catch (_) {
      durationMs = max(200, item.endMs - item.startMs);
    }

    item.audioFilePath = destFile.path;
    item.audioDurationMs = durationMs > 0 ? durationMs : (item.endMs - item.startMs);
    final srtDurationMs = max(200, item.endMs - item.startMs);
    if (item.audioDurationMs > srtDurationMs) {
      final factor = (item.audioDurationMs / srtDurationMs).clamp(1.0, 2.2);
      item.playbackSpeed = (factor * 10).round() / 10.0;
    } else {
      item.playbackSpeed = 1.0;
    }

    return destFile;
  }
}
