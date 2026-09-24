import 'package:capsub_flutter/data/api/groq_translator.dart';
import 'package:capsub_flutter/data/model/subtitle_document.dart';
import 'package:capsub_flutter/data/model/subtitle_item.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GroqTranslator prompt & models', () {
    test('keeps the base translation rules when custom prompt is used', () {
      final translator = GroqTranslator(apiKeys: const ['gsk-test-key']);

      final prompt = translator.buildSystemPrompt(
        'custom',
        'vi-VN',
        'Dùng xưng hô đại hiệp/tiểu muội.',
      );

      expect(prompt, contains('NGÔN NGỮ ĐÍCH CẦN DỊCH: vi-VN'));
      expect(prompt, contains('Dùng xưng hô đại hiệp/tiểu muội.'));
      expect(prompt, contains('BẢO TOÀN 100% CẤU TRÚC SRT'));
      expect(prompt, contains('KHÔNG bỏ qua bất kỳ khối nào'));
    });

    test('preserves the requested Groq model id', () {
      final translator = GroqTranslator(
        apiKeys: const ['gsk-test-key'],
        modelId: 'qwen/qwen3.8-27b',
      );

      expect(translator.modelId, 'qwen/qwen3.8-27b');
    });
  });

  test('sends OpenAI format request and parses SRT response cleanly', () async {
    final dio = Dio();
    Map<String, dynamic>? capturedBody;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          capturedBody = Map<String, dynamic>.from(options.data as Map);
          expect(options.headers['Authorization'], 'Bearer gsk-test-key');
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'choices': [
                  {
                    'message': {
                      'role': 'assistant',
                      'content': '''
<think>
Suy luận cách dịch phụ đề...
</think>
1
00:00:00,000 --> 00:00:01,000
Xin chào thế giới

2
00:00:01,000 --> 00:00:02,000
Hẹn gặp lại
''',
                    },
                  },
                ],
              },
            ),
          );
        },
      ),
    );

    final translator = GroqTranslator(
      apiKeys: const ['gsk-test-key'],
      modelId: 'openai/gpt-oss-120b',
      dio: dio,
    );

    final document = SubtitleDocument([
      SubtitleItem(id: 1, startMs: 0, endMs: 1000, originalText: 'Hello world'),
      SubtitleItem(id: 2, startMs: 1000, endMs: 2000, originalText: 'See you again'),
    ]);

    await translator.translateSubtitles(document: document, threadCount: 1);

    expect(document.items[0].translatedText, 'Xin chào thế giới');
    expect(document.items[1].translatedText, 'Hẹn gặp lại');
    expect(capturedBody?['model'], 'openai/gpt-oss-120b');
    expect(capturedBody?['messages'], isA<List>());
    expect(capturedBody?['max_tokens'], 8192);
  });

  test('rotates multiple Groq API keys across requests', () async {
    final keys = ['gsk-key-1', 'gsk-key-2'];
    final translator = GroqTranslator(apiKeys: keys);

    expect(translator.getNextApiKey(), 'gsk-key-1');
    expect(translator.getNextApiKey(), 'gsk-key-2');
    expect(translator.getNextApiKey(), 'gsk-key-1');
  });
}
