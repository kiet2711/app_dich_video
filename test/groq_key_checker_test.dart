import 'package:capsub_flutter/data/api/groq_key_checker.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GroqKeyChecker Tests', () {
    test('Empty API key returns dead status', () async {
      final result = await GroqKeyChecker.checkKey('   ');
      expect(result.status, GroqKeyStatus.dead);
      expect(result.isAlive, isFalse);
      expect(result.message, contains('trống'));
    });

    test('Masked key formats correctly', () {
      const shortKey = '1234567';
      const longKey = 'gsk_1234567890abcdefg1234';
      expect(
        const GroqKeyCheckResult(
          key: shortKey,
          status: GroqKeyStatus.alive,
          message: '',
        ).maskedKey,
        shortKey,
      );
      expect(
        const GroqKeyCheckResult(
          key: longKey,
          status: GroqKeyStatus.alive,
          message: '',
        ).maskedKey,
        'gsk_12...1234',
      );
    });

    test('HTTP 200 returns alive status with latency', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.headers['Authorization'], 'Bearer gsk_valid');
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'choices': [
                    {
                      'message': {'content': 'Pong'}
                    }
                  ]
                },
              ),
            );
          },
        ),
      );

      final result = await GroqKeyChecker.checkKey(
        'gsk_valid',
        modelId: 'openai/gpt-oss-120b',
        dio: dio,
      );

      expect(result.status, GroqKeyStatus.alive);
      expect(result.isAlive, isTrue);
      expect(result.statusCode, 200);
      expect(result.testedModel, 'openai/gpt-oss-120b');
    });

    test('HTTP 401 returns dead status', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(
                  requestOptions: options,
                  statusCode: 401,
                  data: {
                    'error': {'message': 'Invalid API Key'}
                  },
                ),
              ),
            );
          },
        ),
      );

      final result = await GroqKeyChecker.checkKey(
        'gsk_invalid',
        dio: dio,
      );

      expect(result.status, GroqKeyStatus.dead);
      expect(result.isAlive, isFalse);
      expect(result.statusCode, 401);
      expect(result.message, contains('Invalid API Key'));
    });

    test('HTTP 429 returns quotaExceeded status', () async {
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
                    'error': {'message': 'Rate limit reached'}
                  },
                ),
              ),
            );
          },
        ),
      );

      final result = await GroqKeyChecker.checkKey(
        'gsk_overlimit',
        dio: dio,
      );

      expect(result.status, GroqKeyStatus.quotaExceeded);
      expect(result.isAlive, isFalse);
      expect(result.statusCode, 429);
      expect(result.message, contains('429'));
    });
  });
}
