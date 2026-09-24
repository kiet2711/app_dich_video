import 'package:capsub_flutter/domain/ai/ai_model_registry.dart';
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
  });
}
