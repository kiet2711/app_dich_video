import 'dart:io';
import 'dart:typed_data';

import 'package:capsub_flutter/domain/tts/audio_file_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('validator_test_');
  });

  tearDown(() async {
    AudioFileValidator.clearCache();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('rejects non-existent file', () async {
    final missing = File('${tempDir.path}/missing.mp3');
    final result = await AudioFileValidator.validate(missing);
    expect(result.isValid, isFalse);
    expect(result.reason, contains('Chưa nhận được'));
  });

  test('rejects file smaller than minAudioBytes', () async {
    final tiny = File('${tempDir.path}/tiny.mp3');
    await tiny.writeAsBytes(Uint8List(50));
    final result = await AudioFileValidator.validate(tiny);
    expect(result.isValid, isFalse);
    expect(result.reason, contains('rỗng'));
  });

  test('validates audio and caches results', () async {
    final file = File('${tempDir.path}/sample.mp3');
    // Write 2048 bytes of dummy audio data
    await file.writeAsBytes(Uint8List(2048));
    final result1 = await AudioFileValidator.validate(file);
    expect(result1.isValid, isTrue);
    expect(result1.durationMs, greaterThan(0));

    // Cache hit
    final result2 = await AudioFileValidator.validate(file);
    expect(identical(result1, result2), isTrue);

    // Invalidation
    AudioFileValidator.invalidate(file);
    final result3 = await AudioFileValidator.validate(file);
    expect(result3.isValid, isTrue);
  });
}
