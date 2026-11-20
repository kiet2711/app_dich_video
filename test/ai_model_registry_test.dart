import 'package:ksub/domain/ai/ai_model_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AiModelRegistry Tests', () {
    test('detectProvider correctly identifies CapCut, Gemini, Groq, None', () {
      expect(AiModelRegistry.detectProvider('capcut'), AiProvider.capcut);
      expect(AiModelRegistry.detectProvider('none'), AiProvider.none);
      expect(AiModelRegistry.detectProvider(''), AiProvider.none);

      expect(
        AiModelRegistry.detectProvider('gemini-3.5-flash-lite'),
        AiProvider.gemini,
      );
      expect(
        AiModelRegistry.detectProvider('gemini-3.1-flash-lite'),
        AiProvider.gemini,
      );

      expect(
        AiModelRegistry.detectProvider('openai/gpt-oss-120b'),
        AiProvider.groq,
      );
      expect(
        AiModelRegistry.detectProvider('openai/gpt-oss-20b'),
        AiProvider.groq,
      );
      expect(
        AiModelRegistry.detectProvider('qwen/qwen3.8-27b'),
        AiProvider.groq,
      );
    });

    test('isAiTranslationModel identifies Gemini and Groq as AI models', () {
      expect(AiModelRegistry.isAiTranslationModel('gemini-3.5-flash-lite'), isTrue);
      expect(AiModelRegistry.isAiTranslationModel('openai/gpt-oss-120b'), isTrue);
      expect(AiModelRegistry.isAiTranslationModel('qwen/qwen3.8-27b'), isTrue);
      expect(AiModelRegistry.isAiTranslationModel('capcut'), isFalse);
      expect(AiModelRegistry.isAiTranslationModel('none'), isFalse);
    });

    test('groqModels contains all 3 requested models', () {
      final ids = AiModelRegistry.groqModels.map((m) => m.id).toList();
      expect(ids, contains('openai/gpt-oss-120b'));
      expect(ids, contains('openai/gpt-oss-20b'));
      expect(ids, contains('qwen/qwen3.8-27b'));
    });

    test('geminiLiveModels contains all 3 Live API models and candidate mappings', () {
      final names = AiModelRegistry.geminiLiveModels
          .map((m) => m.displayName)
          .toList();
      expect(names, [
        'Gemini 3.8 Live',
        'Gemini 3.8 Live Extended Thinking',
        'Gemini 3 Flash Live',
      ]);

      for (final model in AiModelRegistry.geminiLiveModels) {
        expect(model.provider, AiProvider.gemini);
        expect(AiModelRegistry.detectProvider(model.id), AiProvider.gemini);
        final candidates = AiModelRegistry.liveModelCandidateIds[model.id];
        expect(candidates, isNotNull);
        expect(candidates, isNotEmpty);
      }
    });
  });
}
