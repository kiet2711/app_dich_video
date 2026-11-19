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

  group('TtsAudioScheduler.computeEqualizerBandGainDb', () {
    test('returns 0 dB when warmth and brightness are neutral', () {
      for (final freq in [60.0, 230.0, 910.0, 3600.0, 14000.0]) {
        expect(
          TtsAudioScheduler.computeEqualizerBandGainDb(
            centerFrequencyHz: freq,
            warmth: 0.0,
            brightness: 0.0,
            minDb: -15.0,
            maxDb: 15.0,
          ),
          0.0,
        );
      }
    });

    test('warmth boosts low-mid and negative brightness cuts shrill high bands', () {
      final lowMid = TtsAudioScheduler.computeEqualizerBandGainDb(
        centerFrequencyHz: 230.0,
        warmth: 0.5,
        brightness: -0.5,
        minDb: -15.0,
        maxDb: 15.0,
      );
      final shrillHigh = TtsAudioScheduler.computeEqualizerBandGainDb(
        centerFrequencyHz: 3600.0,
        warmth: 0.5,
        brightness: -0.5,
        minDb: -15.0,
        maxDb: 15.0,
      );
      expect(lowMid, greaterThan(0.0));
      expect(shrillHigh, lessThan(0.0));
    });

    test('clamps gain within device equalizer minDb..maxDb limits', () {
      expect(
        TtsAudioScheduler.computeEqualizerBandGainDb(
          centerFrequencyHz: 14000.0,
          warmth: 0.0,
          brightness: -1.0,
          minDb: -6.0,
          maxDb: 6.0,
        ),
        -6.0,
      );
      expect(
        TtsAudioScheduler.computeEqualizerBandGainDb(
          centerFrequencyHz: 230.0,
          warmth: 1.0,
          brightness: 0.0,
          minDb: -4.0,
          maxDb: 4.0,
        ),
        4.0,
      );
    });
  });
}
