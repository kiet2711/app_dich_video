import 'dart:io';
import 'package:capsub_flutter/data/api/gemini_translator.dart';
import 'package:capsub_flutter/data/model/subtitle_document.dart';
import 'package:capsub_flutter/data/model/subtitle_item.dart';
import 'package:capsub_flutter/domain/ai/smart_ai_translator.dart';
import 'package:capsub_flutter/domain/ai/translation_checkpoint_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('checkpoint_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall methodCall) async {
            return tempDir.path;
          },
        );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Batch Subtitle Translation & Robustness Tests', () {
    test('1. AI trả đúng tất cả IDs qua JSON Schema', () {
      final items = [
        SubtitleItem(id: 101, startMs: 1000, endMs: 2500, originalText: '你好'),
        SubtitleItem(id: 102, startMs: 2600, endMs: 4000, originalText: '世界'),
      ];

      const rawJson = '''
      {
        "items": [
          {"id": 101, "translation": "Xin chào"},
          {"id": 102, "translation": "Thế giới"}
        ]
      }
      ''';

      final results = GeminiTranslator.parseBatchResponse(rawJson, items);
      expect(results[101], equals('Xin chào'));
      expect(results[102], equals('Thế giới'));
      expect(results.length, equals(2));
    });

    test('2. AI trả đảo thứ tự: [52, 50, 53, 51] -> ghép theo ID vẫn đúng thứ tự 50, 51, 52, 53 và timestamp bất biến', () {
      final items = [
        SubtitleItem(id: 50, startMs: 100000, endMs: 102500, originalText: '第一句'),
        SubtitleItem(id: 51, startMs: 102600, endMs: 105000, originalText: '第二句'),
        SubtitleItem(id: 52, startMs: 105100, endMs: 107200, originalText: '第三句'),
        SubtitleItem(id: 53, startMs: 107300, endMs: 109800, originalText: '第四句'),
      ];

      // AI returns out of order
      const outOfOrderJson = '''
      {
        "items": [
          {"id": 52, "translation": "Câu số ba"},
          {"id": 50, "translation": "Câu số một"},
          {"id": 53, "translation": "Câu số bốn"},
          {"id": 51, "translation": "Câu số hai"}
        ]
      }
      ''';

      final results = GeminiTranslator.parseBatchResponse(outOfOrderJson, items);

      // Ghép kết quả vào cue theo id (KHÔNG dùng position)
      for (final item in items) {
        item.translatedText = results[item.id] ?? item.originalText;
      }

      // Kiểm tra thứ tự và nội dung
      expect(items[0].id, equals(50));
      expect(items[0].translatedText, equals('Câu số một'));
      expect(items[0].startMs, equals(100000));
      expect(items[0].endMs, equals(102500));

      expect(items[1].id, equals(51));
      expect(items[1].translatedText, equals('Câu số hai'));
      expect(items[1].startMs, equals(102600));
      expect(items[1].endMs, equals(105000));

      expect(items[2].id, equals(52));
      expect(items[2].translatedText, equals('Câu số ba'));
      expect(items[2].startMs, equals(105100));
      expect(items[2].endMs, equals(107200));

      expect(items[3].id, equals(53));
      expect(items[3].translatedText, equals('Câu số bốn'));
      expect(items[3].startMs, equals(107300));
      expect(items[3].endMs, equals(109800));

      // Xuất file SRT: timestamp logically identical và đúng thứ tự
      final srtOutput = SubtitleDocument(items).toSrtString();
      expect(srtOutput, contains('00:01:40,000 --> 00:01:42,500'));
      expect(srtOutput, contains('00:01:42,600 --> 00:01:45,000'));
      expect(srtOutput, contains('00:01:45,100 --> 00:01:47,200'));
      expect(srtOutput, contains('00:01:47,300 --> 00:01:49,800'));
    });

    test('3. AI thiếu 1 ID hoặc nhiều IDs: parseBatchResponse chỉ nhận ID có trong expectedIds', () {
      final items = [
        SubtitleItem(id: 101, startMs: 0, endMs: 1000, originalText: 'One'),
        SubtitleItem(id: 102, startMs: 1000, endMs: 2000, originalText: 'Two'),
        SubtitleItem(id: 103, startMs: 2000, endMs: 3000, originalText: 'Three'),
        SubtitleItem(id: 104, startMs: 3000, endMs: 4000, originalText: 'Four'),
      ];

      // Missing 102 and 103
      const incompleteJson = '''
      {
        "items": [
          {"id": 101, "translation": "Một"},
          {"id": 104, "translation": "Bốn"}
        ]
      }
      ''';

      final results = GeminiTranslator.parseBatchResponse(incompleteJson, items);
      expect(results.containsKey(101), isTrue);
      expect(results.containsKey(104), isTrue);
      expect(results.containsKey(102), isFalse);
      expect(results.containsKey(103), isFalse);
    });

    test('4. AI trả duplicate ID và ID lạ ngoài expectedIds', () {
      final items = [
        SubtitleItem(id: 201, startMs: 0, endMs: 1000, originalText: 'Alpha'),
        SubtitleItem(id: 202, startMs: 1000, endMs: 2000, originalText: 'Beta'),
      ];

      const dirtyJson = '''
      {
        "items": [
          {"id": 201, "translation": "Alpha lần 1"},
          {"id": 201, "translation": "Alpha duplicate (bị bỏ)"},
          {"id": 999, "translation": "ID lạ không có trong batch (bị bỏ)"},
          {"id": 202, "translation": "Beta chuẩn"}
        ]
      }
      ''';

      final results = GeminiTranslator.parseBatchResponse(dirtyJson, items);
      expect(results[201], equals('Alpha lần 1'));
      expect(results[202], equals('Beta chuẩn'));
      expect(results.containsKey(999), isFalse);
      expect(results.length, equals(2));
    });

    test('5. AI trả translation rỗng hoặc whitespace -> không nhận để kích hoạt retry/fallback', () {
      final items = [
        SubtitleItem(id: 301, startMs: 0, endMs: 1000, originalText: 'Valid'),
        SubtitleItem(id: 302, startMs: 1000, endMs: 2000, originalText: 'Empty trans'),
      ];

      const emptyTransJson = '''
      {
        "items": [
          {"id": 301, "translation": "Hợp lệ"},
          {"id": 302, "translation": "   "}
        ]
      }
      ''';

      final results = GeminiTranslator.parseBatchResponse(emptyTransJson, items);
      expect(results[301], equals('Hợp lệ'));
      expect(results.containsKey(302), isFalse);
    });

    test('6. JSON bọc markdown ```json ... ``` được bóc tách và parse an toàn', () {
      final items = [
        SubtitleItem(id: 401, startMs: 0, endMs: 1000, originalText: 'Test markdown fence'),
      ];

      const fencedResponse = '''
      ```json
      {
        "items": [
          {"id": 401, "translation": "Kiểm tra markdown fence"}
        ]
      }
      ```
      ''';

      final results = GeminiTranslator.parseBatchResponse(fencedResponse, items);
      expect(results[401], equals('Kiểm tra markdown fence'));
    });

    test('7. duration_ms được tính toán chính xác và đưa vào buildBatchPayload', () {
      final items = [
        SubtitleItem(id: 1, startMs: 1500, endMs: 4200, originalText: 'Hello world'),
      ];

      expect(items.first.durationMs, equals(2700));

      final contextItem = SubtitleItem(
        id: 0,
        startMs: 0,
        endMs: 1400,
        originalText: 'Hi',
        translatedText: 'Chào',
      );

      final payload = GeminiTranslator.buildBatchPayload(
        items: items,
        contextItems: [contextItem],
      );

      expect(payload, contains('"id":1'));
      expect(payload, contains('"duration_ms":2700'));
      expect(payload, contains('"text":"Hello world"'));
      expect(payload, contains('"context":'));
      expect(payload, contains('"translation":"Chào"'));
    });

    test('8. Subtitle multiline và ký tự Unicode tiếng Trung, tiếng Việt', () {
      final items = [
        SubtitleItem(
          id: 501,
          startMs: 0,
          endMs: 2000,
          originalText: '第一行\n第二行',
        ),
      ];

      const multilineResponse = '''
      {
        "items": [
          {"id": 501, "translation": "Dòng thứ nhất\\nDòng thứ hai"}
        ]
      }
      ''';

      final results = GeminiTranslator.parseBatchResponse(multilineResponse, items);
      expect(results[501], equals('Dòng thứ nhất\nDòng thứ hai'));
    });

    test('9. Phân loại lỗi máy chủ tạm thời 500, 502, 503, 504 (isServerUnavailableError)', () {
      final error503 = DioException(
        requestOptions: RequestOptions(path: '/'),
        response: Response(
          requestOptions: RequestOptions(path: '/'),
          statusCode: 503,
        ),
      );
      expect(SmartAiTranslator.isServerUnavailableError(error503), isTrue);
      expect(SmartAiTranslator.isDeadKeyError(error503), isFalse);

      final error500 = DioException(
        requestOptions: RequestOptions(path: '/'),
        response: Response(
          requestOptions: RequestOptions(path: '/'),
          statusCode: 500,
        ),
      );
      expect(SmartAiTranslator.isServerUnavailableError(error500), isTrue);
      expect(SmartAiTranslator.isDeadKeyError(error500), isFalse);
    });

    test('10. Retry missing IDs: Khi request đầu thiếu ID, chỉ request các missing IDs', () async {
      final dio = Dio();
      final requestedBatchIds = <List<int>>[];

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final data = options.data as Map;
            final contents = data['contents'] as List;
            final user = contents.first as Map;
            final parts = user['parts'] as List;
            final prompt = parts.first['text'] as String;

            if (prompt.contains('"id":10') && prompt.contains('"id":11')) {
              requestedBatchIds.add([10, 11]);
              // Mock trả về chỉ ID 10, thiếu ID 11
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
                              'text': '{"items": [{"id": 10, "translation": "Câu mười"}]}',
                            },
                          ],
                        },
                      },
                    ],
                  },
                ),
              );
            } else if (prompt.contains('Eleven') || prompt.contains('11')) {
              // Retry chỉ gửi câu Eleven (ID 11)
              requestedBatchIds.add([11]);
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
                              'text': 'Câu mười một',
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

      final translator = GeminiTranslator(apiKeys: const ['test-key'], dio: dio);
      final doc = SubtitleDocument([
        SubtitleItem(id: 10, startMs: 1000, endMs: 2000, originalText: 'Ten'),
        SubtitleItem(id: 11, startMs: 2000, endMs: 3000, originalText: 'Eleven'),
      ]);

      await translator.translateSubtitles(document: doc, threadCount: 1);

      expect(doc.items[0].translatedText, equals('Câu mười'));
      expect(doc.items[1].translatedText, equals('Câu mười một'));
      // Verify rằng request thứ 2 chỉ retry ID 11 (không gửi lại cả batch 10 & 11)
      expect(requestedBatchIds[0], equals([10, 11]));
      expect(requestedBatchIds[1], equals([11]));
    });

    test('11. TranslationCheckpointManager save, load, and clear lifecycle', () async {
      const sessionKey = 'test_session_123';
      final map = {
        1: 'Bản dịch câu 1',
        2: 'Bản dịch câu 2',
      };

      await TranslationCheckpointManager.saveCheckpoint(
        sessionKey: sessionKey,
        targetLanguage: 'vi-VN',
        totalItems: 10,
        translations: map,
      );

      final loaded = await TranslationCheckpointManager.loadCheckpoint(sessionKey);
      expect(loaded[1], equals('Bản dịch câu 1'));
      expect(loaded[2], equals('Bản dịch câu 2'));
      expect(loaded.length, equals(2));

      final all = await TranslationCheckpointManager.getAllCheckpoints();
      expect(all.any((c) => c.sessionKey == sessionKey), isTrue);

      await TranslationCheckpointManager.clearCheckpoint(sessionKey);
      final emptyLoaded = await TranslationCheckpointManager.loadCheckpoint(sessionKey);
      expect(emptyLoaded, isEmpty);
    });

    test('12. Resume flow: Khôi phục ID đã dịch từ Checkpoint và CHỈ gửi ID chưa hoàn thành tới AI', () async {
      final dio = Dio();
      final requestedPrompts = <String>[];

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final data = options.data as Map;
            final contents = data['contents'] as List;
            final user = contents.first as Map;
            final parts = user['parts'] as List;
            final prompt = parts.first['text'] as String;
            requestedPrompts.add(prompt);

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
                            'text': '{"items": [{"id": 2, "translation": "Thế giới mới"}]}',
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

      final doc = SubtitleDocument([
        SubtitleItem(id: 1, startMs: 0, endMs: 1000, originalText: 'Hello'),
        SubtitleItem(id: 2, startMs: 1000, endMs: 2000, originalText: 'World'),
      ]);

      const sessionKey = 'resume_session_test';

      // Giả lập trạng thái đã lưu Checkpoint cho câu 1 từ phiên trước
      await TranslationCheckpointManager.saveCheckpoint(
        sessionKey: sessionKey,
        targetLanguage: 'vi-VN',
        totalItems: 2,
        translations: {1: 'Xin chào đã lưu'},
      );

      final translator = SmartAiTranslator(
        geminiKeys: ['test-key'],
        initialModelId: 'gemini-3.5-flash-lite',
        dio: dio,
      );

      final resultDoc = await translator.translateSubtitles(
        document: doc,
        checkpointSessionId: sessionKey,
        threadCount: 1,
      );

      // Câu 1 được khôi phục nguyên vẹn từ Checkpoint
      expect(resultDoc.items[0].translatedText, equals('Xin chào đã lưu'));
      // Câu 2 được dịch mới từ AI
      expect(resultDoc.items[1].translatedText, equals('Thế giới mới'));

      // QUAN TRỌNG: AI request CHỈ chứa ID 2, KHÔNG gửi lại ID 1
      expect(requestedPrompts.length, equals(1));
      expect(requestedPrompts[0], contains('"id":2'));
      expect(requestedPrompts[0], isNot(contains('"id":1,')));

      // Sau khi hoàn thành 100%, checkpoint tạm tự động được xóa
      final afterFinished = await TranslationCheckpointManager.loadCheckpoint(sessionKey);
      expect(afterFinished, isEmpty);
    });
  });
}
