import 'package:capsub_flutter/data/api/gemini_key_checker.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GeminiKeyChecker Tests', () {
    test('Empty API key returns dead status', () async {
      final result = await GeminiKeyChecker.checkKey('   ');
      expect(result.status, GeminiKeyStatus.dead);
      expect(result.isAlive, isFalse);
      expect(result.message, contains('trống'));
    });

    test('Masked key formats correctly', () {
      const shortKey = '1234567';
      const longKey = 'AIzaSyBNm123456789XyZ';
      expect(
        const GeminiKeyCheckResult(
          key: shortKey,
          status: GeminiKeyStatus.alive,
          message: '',
        ).maskedKey,
        shortKey,
      );
      expect(
        const GeminiKeyCheckResult(
          key: longKey,
          status: GeminiKeyStatus.alive,
          message: '',
        ).maskedKey,
        'AIzaSy...9XyZ',
      );
    });

    test('HTTP 200 returns alive status with tested model info', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.queryParameters['key'], 'valid_key_123');
            expect(options.path, contains('gemini-3.5-flash-lite:generateContent'));
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'candidates': [
                    {
                      'content': {
                        'parts': [
                          {'text': 'Hello'}
                        ]
                      }
                    }
                  ]
                },
              ),
            );
          },
        ),
      );

      final result = await GeminiKeyChecker.checkKey(
        'valid_key_123',
        modelId: 'gemini-3.5-flash-lite',
        dio: dio,
      );
      expect(result.status, GeminiKeyStatus.alive);
      expect(result.isAlive, isTrue);
      expect(result.statusCode, 200);
      expect(result.testedModel, 'gemini-3.5-flash-lite');
      expect(result.message, contains('Sống & Sẵn sàng dịch'));
    });

    test('HTTP 400 returns dead status (API_KEY_INVALID)', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(
                  requestOptions: options,
                  statusCode: 400,
                  data: {
                    'error': {
                      'code': 400,
                      'message': 'API key not valid. Please pass a valid API key.',
                      'status': 'INVALID_ARGUMENT',
                    },
                  },
                ),
              ),
            );
          },
        ),
      );

      final result = await GeminiKeyChecker.checkKey('dead_key_456', dio: dio);
      expect(result.status, GeminiKeyStatus.dead);
      expect(result.isAlive, isFalse);
      expect(result.statusCode, 400);
      expect(result.message, contains('API key not valid'));
    });

    test('HTTP 403 returns permissionDenied status', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(
                  requestOptions: options,
                  statusCode: 403,
                  data: {
                    'error': {
                      'code': 403,
                      'message': 'Generative Language API has not been used in project.',
                      'status': 'PERMISSION_DENIED',
                    },
                  },
                ),
              ),
            );
          },
        ),
      );

      final result = await GeminiKeyChecker.checkKey('forbidden_key_789', dio: dio);
      expect(result.status, GeminiKeyStatus.permissionDenied);
      expect(result.isAlive, isFalse);
      expect(result.statusCode, 403);
    });

    test('HTTP 429 returns quotaExceeded status with helpful message', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(
                  requestOptions: options,
                  statusCode: 429,
                  data: {
                    'error': {
                      'code': 429,
                      'message': 'Resource has been exhausted (e.g. check quota).',
                      'status': 'RESOURCE_EXHAUSTED',
                    },
                  },
                ),
              ),
            );
          },
        ),
      );

      final result = await GeminiKeyChecker.checkKey('rate_limited_key', dio: dio);
      expect(result.status, GeminiKeyStatus.quotaExceeded);
      expect(result.isAlive, isFalse);
      expect(result.statusCode, 429);
      expect(result.message, contains('Rate limit 429'));
    });

    test('checkAllKeys processes multiple keys in parallel with chosen model', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.path, contains('gemini-3.1-flash-lite:generateContent'));
            final key = options.queryParameters['key'];
            if (key == 'good_key') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {'candidates': []},
                ),
              );
            } else {
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response(
                    requestOptions: options,
                    statusCode: 429,
                    data: {
                      'error': {'code': 429, 'message': 'RESOURCE_EXHAUSTED'},
                    },
                  ),
                ),
              );
            }
          },
        ),
      );

      final results = await GeminiKeyChecker.checkAllKeys(
        ['good_key', 'exhausted_key', '  '],
        modelId: 'gemini-3.1-flash-lite',
        dio: dio,
      );

      expect(results.length, 2);
      expect(results[0].key, 'good_key');
      expect(results[0].isAlive, isTrue);
      expect(results[0].testedModel, 'gemini-3.1-flash-lite');

      expect(results[1].key, 'exhausted_key');
      expect(results[1].isAlive, isFalse);
      expect(results[1].status, GeminiKeyStatus.quotaExceeded);
    });
  });
}
