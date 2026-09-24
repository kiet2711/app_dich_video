import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capsub_flutter/data/model/subtitle_document.dart';
import 'package:capsub_flutter/data/model/subtitle_item.dart';
import 'package:capsub_flutter/domain/ai/ai_model_registry.dart';
import 'package:capsub_flutter/domain/ai/smart_ai_translator.dart';

void main() {
  group('SmartAiTranslator Tests', () {
    test('getCandidateModels returns ordered models prioritizing requested model', () {
      final translator = SmartAiTranslator(
        geminiKeys: ['gem-key-1'],
        groqKeys: ['groq-key-1'],
        initialModelId: 'gemini-3.1-flash-lite',
      );

      final geminiCandidates = translator.getCandidateModels(
        AiProvider.gemini,
        'gemini-3.1-flash-lite',
      );
      expect(geminiCandidates, equals(['gemini-3.1-flash-lite', 'gemini-3.5-flash-lite']));

      final geminiCandidatesReversed = translator.getCandidateModels(
        AiProvider.gemini,
        'gemini-3.5-flash-lite',
      );
      expect(geminiCandidatesReversed, equals(['gemini-3.5-flash-lite', 'gemini-3.1-flash-lite']));

      final groqCandidates = translator.getCandidateModels(
        AiProvider.groq,
        'openai/gpt-oss-120b',
      );
      expect(
        groqCandidates,
        equals(['openai/gpt-oss-120b', 'openai/gpt-oss-20b', 'qwen/qwen3.8-27b']),
      );
    });

    test('isRateLimitError and isDeadKeyError classify HTTP and string errors accurately', () {
      // 429 Rate limit
      final rateLimitDio = DioException(
        requestOptions: RequestOptions(path: '/'),
        response: Response(
          requestOptions: RequestOptions(path: '/'),
          statusCode: 429,
        ),
      );
      expect(SmartAiTranslator.isRateLimitError(rateLimitDio), isTrue);
      expect(SmartAiTranslator.isRateLimitError(Exception('RESOURCE_EXHAUSTED')), isTrue);
      expect(SmartAiTranslator.isRateLimitError(Exception('rate_limit_exceeded')), isTrue);

      // Dead key errors: 400 (API_KEY_INVALID), 401, 403
      final invalidKeyDio = DioException(
        requestOptions: RequestOptions(path: '/'),
        response: Response(
          requestOptions: RequestOptions(path: '/'),
          statusCode: 400,
          data: {'error': {'message': 'API_KEY_INVALID'}},
        ),
      );
      expect(SmartAiTranslator.isDeadKeyError(invalidKeyDio), isTrue);

      final unauthorizedDio = DioException(
        requestOptions: RequestOptions(path: '/'),
        response: Response(
          requestOptions: RequestOptions(path: '/'),
          statusCode: 401,
        ),
      );
      expect(SmartAiTranslator.isDeadKeyError(unauthorizedDio), isTrue);

      final forbiddenDio = DioException(
        requestOptions: RequestOptions(path: '/'),
        response: Response(
          requestOptions: RequestOptions(path: '/'),
          statusCode: 403,
        ),
      );
      expect(SmartAiTranslator.isDeadKeyError(forbiddenDio), isTrue);
    });

    test('isTargetAvailable tracks dead keys and cooldowns properly', () {
      final translator = SmartAiTranslator(
        geminiKeys: ['key-1', 'key-2'],
        groqKeys: ['groq-1'],
      );

      final target1 = const TranslationTarget(
        provider: AiProvider.gemini,
        apiKey: 'key-1',
        modelId: 'gemini-3.1-flash-lite',
      );

      expect(translator.isTargetAvailable(target1), isTrue);

      // Set cooldown on target1
      translator.markCooldown(target1, duration: const Duration(seconds: 30));
      expect(translator.isTargetAvailable(target1), isFalse);

      // Target with different model on same key is still available
      final target1AlternativeModel = const TranslationTarget(
        provider: AiProvider.gemini,
        apiKey: 'key-1',
        modelId: 'gemini-3.5-flash-lite',
      );
      expect(translator.isTargetAvailable(target1AlternativeModel), isTrue);

      // Mark key as dead
      translator.markDeadKey('key-1');
      expect(translator.isTargetAvailable(target1AlternativeModel), isFalse);
    });

    test('fallback from model 3.1 to 3.5 on SAME KEY when 429 occurs', () async {
      final requestedModels = <String>[];
      final requestedKeys = <String>[];

      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final uri = options.uri.toString();
            if (uri.contains('gemini-3.1-flash-lite')) {
              requestedModels.add('gemini-3.1-flash-lite');
              requestedKeys.add(options.uri.queryParameters['key'] ?? '');
              return handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response(
                    requestOptions: options,
                    statusCode: 429,
                    data: 'RESOURCE_EXHAUSTED',
                  ),
                ),
              );
            } else if (uri.contains('gemini-3.5-flash-lite')) {
              requestedModels.add('gemini-3.5-flash-lite');
              requestedKeys.add(options.uri.queryParameters['key'] ?? '');
              return handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'candidates': [
                      {
                        'content': {
                          'parts': [
                            {
                              'text':
                                  '1\n00:00:01,000 --> 00:00:03,000\nXin chào bạn\n\n',
                            },
                          ],
                        },
                      },
                    ],
                  },
                ),
              );
            }
            return handler.next(options);
          },
        ),
      );

      final translator = SmartAiTranslator(
        geminiKeys: ['gem-key-A', 'gem-key-B'],
        groqKeys: ['groq-key-1'],
        initialModelId: 'gemini-3.1-flash-lite',
        enableSmartModelFallback: true,
        dio: dio,
      );

      final doc = SubtitleDocument([
        SubtitleItem(
          id: 1,
          startMs: 1000,
          endMs: 3000,
          originalText: 'Hello friend',
        ),
      ]);

      final result = await translator.translateSubtitles(
        document: doc,
        threadCount: 1,
      );

      expect(result.items.first.translatedText, equals('Xin chào bạn'));
      // Verify that 3.1 was tried first, then 3.5 on the SAME key ('gem-key-A')
      expect(requestedModels, equals(['gemini-3.1-flash-lite', 'gemini-3.5-flash-lite']));
      expect(requestedKeys, equals(['gem-key-A', 'gem-key-A']));
    });

    test('Cross-provider fallback to Groq when all Gemini models fail with 429', () async {
      final providersCalled = <String>[];

      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final uri = options.uri.toString();
            if (uri.contains('googleapis.com')) {
              providersCalled.add('gemini');
              return handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response(
                    requestOptions: options,
                    statusCode: 429,
                    data: 'RESOURCE_EXHAUSTED',
                  ),
                ),
              );
            } else if (uri.contains('api.groq.com')) {
              providersCalled.add('groq');
              return handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'choices': [
                      {
                        'message': {
                          'content':
                              '1\n00:00:01,000 --> 00:00:03,000\nBản dịch từ Groq AI\n\n',
                        },
                      },
                    ],
                  },
                ),
              );
            }
            return handler.next(options);
          },
        ),
      );

      final translator = SmartAiTranslator(
        geminiKeys: ['gem-key-1'],
        groqKeys: ['groq-key-1'],
        initialModelId: 'gemini-3.1-flash-lite',
        enableCrossProviderFallback: true,
        dio: dio,
      );

      final doc = SubtitleDocument([
        SubtitleItem(
          id: 1,
          startMs: 1000,
          endMs: 3000,
          originalText: 'Hello world',
        ),
      ]);

      final result = await translator.translateSubtitles(
        document: doc,
        threadCount: 1,
      );

      expect(result.items.first.translatedText, equals('Bản dịch từ Groq AI'));
      expect(providersCalled, contains('gemini'));
      expect(providersCalled, contains('groq'));
    });
  });
}
