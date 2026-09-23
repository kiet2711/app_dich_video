import 'package:capsub_flutter/player/tts_audio_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TtsAudioScheduler.calculatePlaybackSpeed', () {
    test('keeps normal speed when audio fits the subtitle slot', () {
      expect(
        TtsAudioScheduler.calculatePlaybackSpeed(
          audioDurationMs: 1800,
          subtitleDurationMs: 2000,
        ),
        1.0,
      );
    });

    test('uses the real audio/SRT ratio and rounds to 0.1x', () {
      expect(
        TtsAudioScheduler.calculatePlaybackSpeed(
          audioDurationMs: 3000,
          subtitleDurationMs: 2000,
        ),
        1.5,
      );
      expect(
        TtsAudioScheduler.calculatePlaybackSpeed(
          audioDurationMs: 2650,
          subtitleDurationMs: 2000,
        ),
        1.3,
      );
    });

    test('caps playback speed at 2.2x', () {
      expect(
        TtsAudioScheduler.calculatePlaybackSpeed(
          audioDurationMs: 5000,
          subtitleDurationMs: 1000,
        ),
        2.2,
      );
    });
  });

  group('TtsAudioScheduler.calculateSourceOffsetMs', () {
    test('starts a normally reached sentence at its beginning', () {
      expect(
        TtsAudioScheduler.calculateSourceOffsetMs(
          timelineOffsetMs: 80,
          speed: 1.5,
          explicitSeek: false,
        ),
        0,
      );
    });

    test('catches up when AVPlayer starts noticeably late', () {
      expect(
        TtsAudioScheduler.calculateSourceOffsetMs(
          timelineOffsetMs: 250,
          speed: 1.5,
          explicitSeek: false,
        ),
        375,
      );
    });

    test('an explicit seek always uses the exact sentence offset', () {
      expect(
        TtsAudioScheduler.calculateSourceOffsetMs(
          timelineOffsetMs: 80,
          speed: 1.5,
          explicitSeek: true,
        ),
        120,
      );
    });
  });

  group('TtsAudioScheduler.calculateAudioPlaybackSpeed', () {
    test('keeps TTS synchronized with the selected video speed', () {
      expect(
        TtsAudioScheduler.calculateAudioPlaybackSpeed(
          ttsSpeed: 1.5,
          videoSpeed: 0.5,
        ),
        0.75,
      );
      expect(
        TtsAudioScheduler.calculateAudioPlaybackSpeed(
          ttsSpeed: 1.5,
          videoSpeed: 2.0,
        ),
        3.0,
      );
    });
  });
}
