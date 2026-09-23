import 'package:capsub_flutter/data/api/gemini_translator.dart';
import 'package:capsub_flutter/data/model/subtitle_document.dart';
import 'package:capsub_flutter/data/model/subtitle_item.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GeminiTranslator prompt', () {
    test('keeps the base translation rules when custom prompt is used', () {
      final translator = GeminiTranslator(apiKeys: const ['test-key']);

      final prompt = translator.buildSystemPrompt(
        'custom',
        'vi-VN',
        'Dùng cách xưng hô anh/em.',
      );

      expect(prompt, contains('NGÔN NGỮ ĐÍCH CẦN DỊCH: vi-VN'));
      expect(prompt, contains('Dùng cách xưng hô anh/em.'));
      expect(prompt, contains('BẢO TOÀN 100% CẤU TRÚC SRT'));
      expect(prompt, contains('KHÔNG bỏ qua bất kỳ khối nào'));
    });

    test('preserves the requested model id', () {
      final translator = GeminiTranslator(
        apiKeys: const ['test-key'],
        modelId: 'gemini-3.8-flash',
      );

      expect(translator.modelId, 'gemini-3.8-flash');
    });
  });

  test('sends original request limits and maps an SRT response', () async {
    final dio = Dio();
    Map<String, dynamic>? capturedBody;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          capturedBody = Map<String, dynamic>.from(options.data as Map);
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {
                          'text': '''
1
00:00:00,000 --> 00:00:01,000
Xin chào

2
00:00:01,000 --> 00:00:02,000
Tạm biệt
''',
                        },
                      ],
                    },
                  },
                ],
              },
            ),
          );
        },
      ),
    );
    final translator = GeminiTranslator(apiKeys: const ['test-key'], dio: dio);
    final document = SubtitleDocument([
      SubtitleItem(id: 1, startMs: 0, endMs: 1000, originalText: '你好'),
      SubtitleItem(id: 2, startMs: 1000, endMs: 2000, originalText: '再见'),
    ]);

    await translator.translateSubtitles(document: document, threadCount: 1);

    expect(document.items[0].translatedText, 'Xin chào');
    expect(document.items[1].translatedText, 'Tạm biệt');
    expect(
      capturedBody?['generationConfig'],
      containsPair('maxOutputTokens', 8192),
    );
    expect(capturedBody?['generationConfig'], containsPair('temperature', 0.2));
  });

  test('retranslates an omitted subtitle as a single sentence', () async {
    final dio = Dio();
    var requestCount = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requestCount++;
          final data = Map<String, dynamic>.from(options.data as Map);
          final contents = data['contents'] as List<dynamic>;
          final user = contents.first as Map<String, dynamic>;
          final parts = user['parts'] as List<dynamic>;
          final userPrompt =
              (parts.first as Map<String, dynamic>)['text'] as String;
          final isSingleSentence = userPrompt.startsWith('Hãy dịch câu thoại');
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {
                          'text': isSingleSentence
                              ? 'Tạm biệt'
                              : '''
1
00:00:00,000 --> 00:00:01,000
Xin chào
''',
                        },
                      ],
                    },
                  },
                ],
              },
            ),
          );
        },
      ),
    );
    final translator = GeminiTranslator(apiKeys: const ['test-key'], dio: dio);
    final document = SubtitleDocument([
      SubtitleItem(id: 1, startMs: 0, endMs: 1000, originalText: '你好'),
      SubtitleItem(id: 2, startMs: 1000, endMs: 2000, originalText: '再见'),
    ]);

    await translator.translateSubtitles(document: document, threadCount: 1);

    expect(requestCount, 2);
    expect(document.items[0].translatedText, 'Xin chào');
    expect(document.items[1].translatedText, 'Tạm biệt');
  });

  test('translates failed items by their stable IDs', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': '[7]: Xin chào\n[12]: Tạm biệt'},
                      ],
                    },
                  },
                ],
              },
            ),
          );
        },
      ),
    );
    final translator = GeminiTranslator(apiKeys: const ['test-key'], dio: dio);

    final translated = await translator.translateItems(
      items: const {7: '你好', 12: '再见'},
      threadCount: 1,
    );

    expect(translated, {7: 'Xin chào', 12: 'Tạm biệt'});
  });

  test('verifies that translateSubtitles runs concurrent requests according to threadCount', () async {
    final dio = Dio();
    var currentConcurrent = 0;
    var maxConcurrent = 0;

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          currentConcurrent++;
          if (currentConcurrent > maxConcurrent) {
            maxConcurrent = currentConcurrent;
          }
          // Giả lập thời gian Gemini xử lý 50ms
          await Future.delayed(const Duration(milliseconds: 50));
          currentConcurrent--;

          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {
                          'text': '''1\n00:00:00,000 --> 00:00:01,000\nĐã dịch''',
                        },
                      ],
                    },
                  },
                ],
              },
            ),
          );
        },
      ),
    );

    final translator = GeminiTranslator(apiKeys: const ['key1', 'key2', 'key3'], dio: dio);

    // Tạo document có 10 câu, chunkSize = 1 -> 10 chunks
    final items = List.generate(
      10,
      (i) => SubtitleItem(
        id: i + 1,
        startMs: i * 1000,
        endMs: (i + 1) * 1000,
        originalText: 'Câu $i',
      ),
    );
    final doc = SubtitleDocument(items);

    await translator.translateSubtitles(
      document: doc,
      chunkSize: 1,
      threadCount: 5,
    );

    // Kiểm tra xem số luồng tối đa thực tế đạt được có phải là 5 không
    expect(maxConcurrent, 5);
  });
}
