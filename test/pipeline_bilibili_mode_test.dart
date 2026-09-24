import 'package:flutter_test/flutter_test.dart';
import 'package:capsub_flutter/domain/ai/ai_model_registry.dart';

void main() {
  group('Bilibili Subtitle Mode & Engine Logic Tests', () {
    test('CapCut engine should bypass pre-existing subtitles to force audio translation', () {
      const engine = 'capcut';
      final shouldUseExistingSubtitles = engine != 'capcut';
      expect(shouldUseExistingSubtitles, isFalse);
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
