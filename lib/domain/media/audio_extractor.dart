import 'dart:io';

import 'package:flutter/services.dart';

class AudioExtractResult {
  final int durationMs;
  final int actualStartMs;

  const AudioExtractResult({
    required this.durationMs,
    required this.actualStartMs,
  });

  @override
  String toString() =>
      'AudioExtractResult(actualStartMs: $actualStartMs, durationMs: $durationMs)';
}

class ContentMediaMetadata {
  const ContentMediaMetadata({
    required this.name,
    required this.sizeBytes,
    required this.durationMs,
  });

  final String name;
  final int sizeBytes;
  final int durationMs;
}

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

  static Future<ContentMediaMetadata> getContentMetadata(String uri) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'getContentMetadata',
      {'uri': uri},
    );
    if (result == null) {
      throw StateError('Không đọc được thông tin media.');
    }
    return ContentMediaMetadata(
      name: (result['name'] as String?)?.trim() ?? '',
      sizeBytes: (result['sizeBytes'] as num?)?.toInt() ?? 0,
      durationMs: (result['durationMs'] as num?)?.toInt() ?? 0,
    );
  }

  static Future<AudioExtractResult> extractAudio({
    required String videoPath,
    required String outputPath,
    int startMs = 0,
    int durationMs = -1,
  }) async {
    final outFile = File(outputPath);
    if (!await outFile.parent.exists()) {
      await outFile.parent.create(recursive: true);
    }

    final res = await _channel.invokeMethod<dynamic>('extractAudio', {
      'videoPath': videoPath,
      'outputPath': outputPath,
      'startMs': startMs,
      'durationMs': durationMs,
    });

    if (res is Map) {
      final dur = (res['durationMs'] as num?)?.toInt() ?? 0;
      final actualStart = (res['actualStartMs'] as num?)?.toInt() ?? startMs;
      return AudioExtractResult(
        durationMs: dur,
        actualStartMs: actualStart,
      );
    } else if (res is num) {
      return AudioExtractResult(
        durationMs: res.toInt(),
        actualStartMs: startMs,
      );
    }

    return AudioExtractResult(
      durationMs: 0,
      actualStartMs: startMs,
    );
  }
}
