import 'dart:io';

import 'package:capsub_flutter/domain/media/audio_chunker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioChunker Tests', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('audio_chunker_test_');

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.capcut.capsub/media'),
            (MethodCall methodCall) async {
              if (methodCall.method == 'extractAudio') {
                final args = methodCall.arguments as Map<dynamic, dynamic>;
                final outputPath = args['outputPath'] as String;
                final file = File(outputPath);
                await file.create(recursive: true);
                await file.writeAsString('mock audio content');
                return 1000;
              }
              return null;
            },
          );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('isAudioFile accurately detects audio formats', () {
      expect(AudioChunker.isAudioFile('test.m4a'), isTrue);
      expect(AudioChunker.isAudioFile('audio.AAC'), isTrue);
      expect(AudioChunker.isAudioFile('song.mp3'), isTrue);
      expect(AudioChunker.isAudioFile('track.wav'), isTrue);
      expect(AudioChunker.isAudioFile('audio.flac'), isTrue);
      expect(AudioChunker.isAudioFile('sound.ogg'), isTrue);
      expect(AudioChunker.isAudioFile('video.mp4'), isFalse);
      expect(AudioChunker.isAudioFile('movie.mov'), isFalse);
      expect(AudioChunker.isAudioFile('clip.mkv'), isFalse);
    });

    test('sliceMedia returns single chunk for short media without slicing', () async {
      final videoFile = File('${tempDir.path}/input.mp4');
      await videoFile.writeAsString('mock video');

      final chunks = await AudioChunker.sliceMedia(
        videoPath: videoFile.path,
        totalDurationMs: 300000, // 5 phút
        tempDir: tempDir,
        chunkDurationSec: 600, // 10 phút
      );

      expect(chunks.length, equals(1));
      expect(chunks.first.index, equals(0));
      expect(chunks.first.startMs, equals(0));
      expect(chunks.first.durationMs, equals(300000));
      expect(chunks.first.file.path, contains('audio_full.m4a'));
    });

    test('sliceMedia extracts full audio once and slices concurrently for long media', () async {
      final videoFile = File('${tempDir.path}/long_input.mp4');
      await videoFile.writeAsString('mock video');

      // Video 25 phút (1500s), mỗi đoạn 10 phút (600s) -> 3 đoạn
      final chunks = await AudioChunker.sliceMedia(
        videoPath: videoFile.path,
        totalDurationMs: 1500000,
        tempDir: tempDir,
        chunkDurationSec: 600,
        concurrency: 3,
      );

      expect(chunks.length, equals(3));

      expect(chunks[0].index, equals(0));
      expect(chunks[0].startMs, equals(0));
      expect(chunks[0].durationMs, equals(600000));
      expect(chunks[0].file.path, contains('chunk_000.m4a'));

      expect(chunks[1].index, equals(1));
      expect(chunks[1].startMs, equals(600000));
      expect(chunks[1].durationMs, equals(600000));
      expect(chunks[1].file.path, contains('chunk_001.m4a'));

      expect(chunks[2].index, equals(2));
      expect(chunks[2].startMs, equals(1200000));
      expect(chunks[2].durationMs, equals(300000));
      expect(chunks[2].file.path, contains('chunk_002.m4a'));
    });

    test('sliceMedia uses audio directly if input is already audio', () async {
      final audioFile = File('${tempDir.path}/source.m4a');
      await audioFile.writeAsString('already audio');

      final chunks = await AudioChunker.sliceMedia(
        videoPath: audioFile.path,
        totalDurationMs: 1200000, // 20 phút
        tempDir: tempDir,
        chunkDurationSec: 900, // 15 phút -> 2 chunks
      );

      expect(chunks.length, equals(2));
      expect(chunks[0].startMs, equals(0));
      expect(chunks[0].durationMs, equals(900000));
      expect(chunks[1].startMs, equals(900000));
      expect(chunks[1].durationMs, equals(300000));
    });
  });
}
