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

  static Future<List<AudioChunkInfo>> sliceMedia({
    required String videoPath,
    required int totalDurationMs,
    required Directory tempDir,
    int chunkDurationSec = defaultChunkDurationSec,
    void Function(double progress, String message)? progressCallback,
  }) async {
    final chunkDurationMs = chunkDurationSec * 1000;
    if (!await tempDir.exists()) {
      await tempDir.create(recursive: true);
    }

    if (totalDurationMs <= chunkDurationMs) {
      final singleFile = File('${tempDir.path}/audio_full.m4a');
      progressCallback?.call(0.05, 'Đang trích xuất luồng âm thanh...');
      await AudioExtractor.extractAudio(
        videoPath: videoPath,
        outputPath: singleFile.path,
      );
      return [
        AudioChunkInfo(
          index: 0,
          startMs: 0,
          durationMs: totalDurationMs,
          file: singleFile,
        ),
      ];
    }

    // Với video dài > 10 phút, cắt thành các chunk
    final numChunks = (totalDurationMs / chunkDurationMs).ceil();
    final chunkList = <AudioChunkInfo>[];

    for (var i = 0; i < numChunks; i++) {
      final startMs = i * chunkDurationMs;
      final durMs = (totalDurationMs - startMs).clamp(0, chunkDurationMs);
      final chunkFile = File(
        '${tempDir.path}/chunk_${i.toString().padLeft(3, '0')}.m4a',
      );

      final pct = (i / numChunks) * 0.2;
      progressCallback?.call(
        pct,
        'Đang cắt phân đoạn ${i + 1}/$numChunks (${durMs ~/ 1000}s)...',
      );

      await AudioExtractor.extractAudio(
        videoPath: videoPath,
        outputPath: chunkFile.path,
        startMs: startMs,
        durationMs: durMs,
      );

      chunkList.add(
        AudioChunkInfo(
          index: i,
          startMs: startMs,
          durationMs: durMs,
          file: chunkFile,
        ),
      );
    }

    return chunkList;
  }
}
