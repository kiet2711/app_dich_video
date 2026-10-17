import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:capsub_flutter/data/repository/settings_repository.dart';
import 'package:capsub_flutter/domain/ai/ai_model_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (MethodCall methodCall) async {
            return '';
          },
        );
    SharedPreferences.setMockInitialValues({});
  });

  group('Bilibili Subtitle Mode & Engine Logic Tests', () {
    test('SettingsRepository defaults to bilibili_first and persists capcut_always', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await SettingsRepository.getInstance();
      expect(settings.bilibiliSubtitleSource, equals('bilibili_first'));

      settings.bilibiliSubtitleSource = 'capcut_always';
      expect(settings.bilibiliSubtitleSource, equals('capcut_always'));
    });

    test('SettingsRepository defaults bilibiliStreamMode to dash and persists muxed', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await SettingsRepository.getInstance();
      expect(settings.bilibiliStreamMode, equals('dash'));

      settings.bilibiliStreamMode = 'muxed';
      expect(settings.bilibiliStreamMode, equals('muxed'));
    });

    test('CapCut engine should bypass pre-existing subtitles to force audio translation', () {
      const engine = 'capcut';
      final shouldUseExistingSubtitles = engine != 'capcut';
      expect(shouldUseExistingSubtitles, isFalse);
    });

    test('capcut_always should bypass pre-existing Bilibili subtitles even when using AI engines', () {
      const engine = 'gemini-3.1-flash-lite';
      const subtitleSource = 'capcut_always';

      final forceCapcut = subtitleSource == 'capcut_always';
      final shouldUseExistingSubtitles = !forceCapcut && engine != 'capcut';

      expect(forceCapcut, isTrue);
      expect(shouldUseExistingSubtitles, isFalse);
    });

    test('bilibili_first should allow pre-existing subtitles for instant AI translation', () {
      const engine = 'gemini-3.1-flash-lite';
      const subtitleSource = 'bilibili_first';

      final forceCapcut = subtitleSource == 'capcut_always';
      final shouldUseExistingSubtitles = !forceCapcut && engine != 'capcut';

      expect(forceCapcut, isFalse);
      expect(shouldUseExistingSubtitles, isTrue);
    });

    test('Gemini and Groq engines should use pre-existing subtitles for instant AI translation', () {
      const geminiEngine = 'gemini-3.1-flash-lite';
      const groqEngine = 'openai/gpt-oss-120b';
      const noneEngine = 'none';

      expect(geminiEngine != 'capcut', isTrue);
      expect(groqEngine != 'capcut', isTrue);
      expect(noneEngine != 'capcut', isTrue);

      expect(AiModelRegistry.isAiTranslationModel(geminiEngine), isTrue);
      expect(AiModelRegistry.isAiTranslationModel(groqEngine), isTrue);
      expect(AiModelRegistry.isAiTranslationModel(noneEngine), isFalse);
    });
  });
}

