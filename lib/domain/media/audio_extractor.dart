import 'dart:io';

import 'package:flutter/services.dart';

class AudioExtractor {
  static const MethodChannel _channel = MethodChannel(
    'com.capcut.capsub/media',
  );

  static Future<int> probeDuration(String mediaPath) async {
    final result = await _channel.invokeMethod<num>('probeMedia', {
      'mediaPath': mediaPath,
    });
    final durationMs = result?.toInt() ?? 0;
    if (durationMs <= 0) {
      throw StateError('Không đọc được thời lượng của tệp media.');
    }
    return durationMs;
  }

  static Future<int> extractAudio({
    required String videoPath,
    required String outputPath,
    int startMs = 0,
    int durationMs = -1,
  }) async {
    final outFile = File(outputPath);
    if (!await outFile.parent.exists()) {
      await outFile.parent.create(recursive: true);
    }

    final res = await _channel.invokeMethod<num>('extractAudio', {
      'videoPath': videoPath,
      'outputPath': outputPath,
      'startMs': startMs,
      'durationMs': durationMs,
    });

    return res?.toInt() ?? 0;
  }
}
