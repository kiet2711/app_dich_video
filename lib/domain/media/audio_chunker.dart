import 'dart:io';

import 'audio_extractor.dart';

class AudioChunkInfo {
  final int index;
  final int startMs;
  final int durationMs;
  final File file;

  const AudioChunkInfo({
    required this.index,
    required this.startMs,
    required this.durationMs,
    required this.file,
  });
}

class AudioChunker {
  static const int defaultChunkDurationSec = 600; // 10 phút

  static bool isAudioFile(String path) {
    final lower = path.toLowerCase().split('?').first;
    return lower.endsWith('.m4a') ||
        lower.endsWith('.aac') ||
        lower.endsWith('.mp3') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.flac') ||
        lower.endsWith('.ogg');
  }

  static Future<List<AudioChunkInfo>> sliceMedia({
    required String videoPath,
    required int totalDurationMs,
    required Directory tempDir,
    int chunkDurationSec = defaultChunkDurationSec,
    int concurrency = 3,
    void Function(double progress, String message)? progressCallback,
  }) async {
    final chunkDurationMs = chunkDurationSec * 1000;
    if (!await tempDir.exists()) {
      await tempDir.create(recursive: true);
    }

    // BƯỚC 1 (Cách 1): Trích xuất toàn bộ track âm thanh sang file M4A duy nhất (chỉ đọc video 1 lần)
    final isSourceAudio = isAudioFile(videoPath);
    String sourceAudioPath;

    if (isSourceAudio) {
      sourceAudioPath = videoPath;
    } else {
      final fullAudioFile = File('${tempDir.path}/audio_full.m4a');
      progressCallback?.call(
        0.03,
        'Đang trích xuất toàn bộ luồng âm thanh từ video sang M4A...',
      );
      await AudioExtractor.extractAudio(
        videoPath: videoPath,
        outputPath: fullAudioFile.path,
      );
      sourceAudioPath = fullAudioFile.path;
    }

    // Nếu thời lượng <= chunkDuration, dùng trực tiếp file âm thanh tổng
    if (totalDurationMs <= chunkDurationMs) {
      return [
        AudioChunkInfo(
          index: 0,
          startMs: 0,
          durationMs: totalDurationMs,
          file: File(sourceAudioPath),
        ),
      ];
    }

    // BƯỚC 2: Với video dài > chunkDuration, cắt song song từ file âm thanh tổng (cực nhẹ và nhanh)
    final numChunks = (totalDurationMs / chunkDurationMs).ceil();
    final chunkList = List<AudioChunkInfo?>.filled(numChunks, null);
    final activeWorkers = concurrency.clamp(1, 6).clamp(1, numChunks);

    var nextChunkIndex = 0;
    var completed = 0;

    progressCallback?.call(
      0.05,
      activeWorkers > 1
          ? 'Đang cắt song song ($activeWorkers luồng) $numChunks phân đoạn âm thanh...'
          : 'Đang chuẩn bị cắt $numChunks phân đoạn âm thanh...',
    );

    Future<void> worker() async {
      while (true) {
        final i = nextChunkIndex++;
        if (i >= numChunks) break;

        final startMs = i * chunkDurationMs;
        final durMs = (totalDurationMs - startMs).clamp(0, chunkDurationMs);
        final chunkFile = File(
          '${tempDir.path}/chunk_${i.toString().padLeft(3, '0')}.m4a',
        );

        await AudioExtractor.extractAudio(
          videoPath: sourceAudioPath,
          outputPath: chunkFile.path,
          startMs: startMs,
          durationMs: durMs,
        );

        chunkList[i] = AudioChunkInfo(
          index: i,
          startMs: startMs,
          durationMs: durMs,
          file: chunkFile,
        );

        completed++;
        final pct = 0.05 + (completed / numChunks) * 0.15;
        progressCallback?.call(
          pct,
          'Đã cắt $completed/$numChunks phân đoạn (${durMs ~/ 1000}s)...',
        );
      }
    }

    await Future.wait(List.generate(activeWorkers, (_) => worker()));
    return chunkList.whereType<AudioChunkInfo>().toList();
  }
}
