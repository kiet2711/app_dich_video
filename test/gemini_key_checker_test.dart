import 'dart:convert';
import 'dart:typed_data';

import 'package:capsub_flutter/data/api/gemini_key_checker.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _MockHttpAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) handler;

  _MockHttpAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

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

    test('HTTP 200 returns alive status with available models', () async {
      final dio = Dio();
      dio.httpClientAdapter = _MockHttpAdapter((options) async {
        expect(options.queryParameters['key'], 'valid_key_123');
        final jsonResponse = jsonEncode({
          'models': [
            {'name': 'models/gemini-1.5-flash'},
            {'name': 'models/gemini-2.0-flash'},
          ],
        });
        return ResponseBody.fromString(
          jsonResponse,
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final result = await GeminiKeyChecker.checkKey('valid_key_123', dio: dio);
      expect(result.status, GeminiKeyStatus.alive);
      expect(result.isAlive, isTrue);
      expect(result.statusCode, 200);
      expect(result.availableModels, contains('gemini-1.5-flash'));
      expect(result.availableModels, contains('gemini-2.0-flash'));
    });

    test('HTTP 400 returns dead status (API_KEY_INVALID)', () async {
      final dio = Dio();
      dio.httpClientAdapter = _MockHttpAdapter((options) async {
        final jsonResponse = jsonEncode({
          'error': {
            'code': 400,
            'message': 'API key not valid. Please pass a valid API key.',
            'status': 'INVALID_ARGUMENT',
          },
        });
        return ResponseBody.fromString(
          jsonResponse,
          400,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final result = await GeminiKeyChecker.checkKey('dead_key_456', dio: dio);
      expect(result.status, GeminiKeyStatus.dead);
      expect(result.isAlive, isFalse);
      expect(result.statusCode, 400);
      expect(result.message, contains('API key not valid'));
    });

    test('HTTP 403 returns permissionDenied status', () async {
      final dio = Dio();
      dio.httpClientAdapter = _MockHttpAdapter((options) async {
        final jsonResponse = jsonEncode({
          'error': {
            'code': 403,
            'message': 'Generative Language API has not been used in project.',
            'status': 'PERMISSION_DENIED',
          },
        });
        return ResponseBody.fromString(
          jsonResponse,
          403,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final result = await GeminiKeyChecker.checkKey('forbidden_key_789', dio: dio);
      expect(result.status, GeminiKeyStatus.permissionDenied);
      expect(result.isAlive, isFalse);
      expect(result.statusCode, 403);
    });

    test('HTTP 429 returns quotaExceeded status', () async {
      final dio = Dio();
      dio.httpClientAdapter = _MockHttpAdapter((options) async {
        final jsonResponse = jsonEncode({
          'error': {
            'code': 429,
            'message': 'Resource has been exhausted.',
            'status': 'RESOURCE_EXHAUSTED',
          },
        });
        return ResponseBody.fromString(
          jsonResponse,
          429,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final result = await GeminiKeyChecker.checkKey('rate_limited_key', dio: dio);
      expect(result.status, GeminiKeyStatus.quotaExceeded);
      expect(result.isAlive, isFalse);
      expect(result.statusCode, 429);
    });

    test('checkAllKeys processes multiple keys in parallel', () async {
      final dio = Dio();
      dio.httpClientAdapter = _MockHttpAdapter((options) async {
        final key = options.queryParameters['key'];
        if (key == 'good_key') {
          return ResponseBody.fromString(
            jsonEncode({'models': []}),
            200,
            headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
          );
        } else {
          return ResponseBody.fromString(
            jsonEncode({
              'error': {'code': 400, 'message': 'API_KEY_INVALID'},
            }),
            400,
            headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
          );
        }
      });

      final results = await GeminiKeyChecker.checkAllKeys(
        ['good_key', 'bad_key', '  '],
        dio: dio,
      );

      expect(results.length, 2);
      expect(results[0].key, 'good_key');
      expect(results[0].isAlive, isTrue);
      expect(results[1].key, 'bad_key');
      expect(results[1].isAlive, isFalse);
    });
  });
}
