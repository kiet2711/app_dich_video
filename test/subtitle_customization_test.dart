import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ksub/data/model/subtitle_item.dart';
import 'package:ksub/data/repository/settings_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Subtitle Customization Tests', () {
    late SettingsRepository settings;

    setUp(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (MethodCall methodCall) async {
              return '';
            },
          );
      SharedPreferences.setMockInitialValues({
        'sub_font_size': 20.0,
        'sub_offset_y': 0.0,
        'sub_mode': 'translated',
        'selected_font_family': '',
        'custom_fonts': <String>['SVN-Futura', 'Montserrat'],
      });
      settings = await SettingsRepository.getInstance();
    });

    test('Subtitle font size clamps properly between 5.0 and 30.0', () {
      settings.subtitleFontSize = 35.0;
      expect(settings.subtitleFontSize, equals(30.0));

      settings.subtitleFontSize = 2.0;
      expect(settings.subtitleFontSize, equals(5.0));

      settings.subtitleFontSize = 14.5;
      expect(settings.subtitleFontSize, equals(14.5));
    });

    test('Subtitle offset Y and mode getters/setters work properly', () {
      settings.subtitleOffsetY = 50.0;
      expect(settings.subtitleOffsetY, equals(50.0));

      settings.subtitleMode = 'bilingual';
      expect(settings.subtitleMode, equals('bilingual'));
    });

    test(
      'Hongguo video resolver switches exclusively between local and HF',
      () {
        expect(settings.hongguoVideoResolverEngine, equals('local'));

        settings.hongguoVideoResolverEngine = 'hf';
        expect(settings.hongguoVideoResolverEngine, equals('hf'));

        settings.hongguoVideoResolverEngine = 'invalid';
        expect(settings.hongguoVideoResolverEngine, equals('local'));
      },
    );

    test('Custom font family settings work properly', () {
      expect(settings.customFonts, contains('SVN-Futura'));
      expect(settings.customFonts, contains('Montserrat'));

      settings.selectedFontFamily = 'SVN-Futura';
      expect(settings.selectedFontFamily, equals('SVN-Futura'));

      final list = List<String>.from(settings.customFonts)
        ..add('Roboto-Custom');
      settings.customFonts = list;
      expect(settings.customFonts, contains('Roboto-Custom'));
    });

    test('Gemini batch size default and updating works properly', () {
      expect(settings.geminiBatchSize, equals(100));

      settings.geminiBatchSize = 80;
      expect(settings.geminiBatchSize, equals(80));

      settings.geminiBatchSize = 45;
      expect(settings.geminiBatchSize, equals(45));
    });

    test('Audio slice concurrency and chunk duration getters/setters work properly', () {
      expect(settings.audioSliceConcurrency, equals(10));
      settings.audioSliceConcurrency = 5;
      expect(settings.audioSliceConcurrency, equals(5));
      settings.audioSliceConcurrency = 3;
      expect(settings.audioSliceConcurrency, equals(3));
      settings.audioSliceConcurrency = 25;
      expect(settings.audioSliceConcurrency, equals(20));
      settings.audioSliceConcurrency = 0;
      expect(settings.audioSliceConcurrency, equals(1));

      expect(settings.audioChunkDurationMin, equals(10));
      expect(settings.audioChunkDurationSec, equals(600));
      settings.audioChunkDurationMin = 15;
      expect(settings.audioChunkDurationMin, equals(15));
      expect(settings.audioChunkDurationSec, equals(900));
      settings.audioChunkDurationMin = 20;
      expect(settings.audioChunkDurationMin, equals(15));
      settings.audioChunkDurationMin = 0;
      expect(settings.audioChunkDurationMin, equals(1));
      expect(settings.audioChunkDurationSec, equals(60));
    });

    test('CapCut STT, Gemini, and Groq concurrency getters/setters clamp up to 20 threads', () {
      // CapCut STT
      expect(settings.capcutSttConcurrency, equals(10));
      settings.capcutSttConcurrency = 20;
      expect(settings.capcutSttConcurrency, equals(20));
      settings.capcutSttConcurrency = 30;
      expect(settings.capcutSttConcurrency, equals(20));
      settings.capcutSttConcurrency = 0;
      expect(settings.capcutSttConcurrency, equals(1));

      // Gemini thread count
      settings.geminiThreadCount = 20;
      expect(settings.geminiThreadCount, equals(20));
      settings.geminiThreadCount = 25;
      expect(settings.geminiThreadCount, equals(20));
      settings.geminiThreadCount = 0;
      expect(settings.geminiThreadCount, equals(1));

      // Groq thread count
      settings.groqThreadCount = 20;
      expect(settings.groqThreadCount, equals(20));
      settings.groqThreadCount = 35;
      expect(settings.groqThreadCount, equals(20));
      settings.groqThreadCount = 0;
      expect(settings.groqThreadCount, equals(1));
    });

    test(
      'SubtitleItem getDisplayText handles bilingual, translated, and original',
      () {
        final item = SubtitleItem(
          id: 1,
          startMs: 1000,
          endMs: 3000,
          originalText: '你好世界',
          translatedText: 'Xin chào thế giới',
        );

        expect(item.getDisplayText('original'), equals('你好世界'));
        expect(item.getDisplayText('translated'), equals('Xin chào thế giới'));
        expect(
          item.getDisplayText('bilingual'),
          equals('你好世界\nXin chào thế giới'),
        );
      },
    );

    test('Fresh install defaults match configured profile with no API keys', () async {
      await settings.prefs.clear();
      expect(settings.geminiApiKeys, isEmpty);
      expect(settings.groqApiKeys, isEmpty);
      expect(settings.bilibiliSessData, isEmpty);
      expect(settings.selectedModel, equals('gemini-3.1-flash-lite'));
      expect(settings.selectedTtsVoice, equals('BV074_streaming_dsp'));
      expect(settings.bilibiliSelectedTtsVoice, equals('BV074_streaming_dsp'));
      expect(settings.hongguoSelectedTtsVoice, equals('BV074_streaming_dsp'));
      expect(settings.geminiThreadCount, equals(7));
      expect(settings.geminiBatchSize, equals(100));
      expect(settings.capcutSttConcurrency, equals(10));
      expect(settings.audioSliceConcurrency, equals(10));
      expect(settings.preferredVideoQuality, equals('80'));
      expect(settings.bilibiliPreferredQuality, equals('80'));
      expect(settings.bilibiliTranslationMode, equals('api_online'));
      expect(settings.hongguoTranslationMode, equals('api_online'));
      expect(settings.hongguoFeedTab, equals('comic'));
      expect(settings.prefetchEpisodeCount, equals(2));
      expect(settings.playerBufferSizeMb, equals(128));
      expect(settings.subtitleFontSize, equals(14.0));
      expect(settings.isBlackBoxEnabled, isFalse);
      expect(settings.subtitlePosPortrait, equals(0.24));
      expect(settings.subtitlePosLandscape, equals(0.06));
      expect(settings.subtitleOffsetY, equals(90.0));
      expect(settings.originalVideoVolume, closeTo(0.57, 0.001));
      expect(settings.ttsVolume, closeTo(0.72, 0.001));
    });
  });
}
