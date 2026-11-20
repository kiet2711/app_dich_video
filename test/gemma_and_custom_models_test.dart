import 'dart:convert';
import 'dart:io';

import 'package:capsub_flutter/data/api/gemini_translator.dart';
import 'package:capsub_flutter/data/model/subtitle_document.dart';
import 'package:capsub_flutter/data/model/subtitle_item.dart';
import 'package:capsub_flutter/data/repository/settings_repository.dart';
import 'package:capsub_flutter/domain/ai/ai_model_registry.dart';
import 'package:capsub_flutter/domain/ai/smart_ai_translator.dart';
import 'package:capsub_flutter/ui/settings/settings_screen.dart';
import 'package:capsub_flutter/ui/theme/app_theme.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CapturingAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) handler;

  _CapturingAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => handler(options);

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('capsub_gemma_test_');
    SharedPreferences.setMockInitialValues({});
    AiModelRegistry.updateCustomModels(geminiModels: const [], groqModels: const []);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
          if (call.method == 'readAll') return <String, String>{};
          return '';
        });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          return tempDir.path;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    AiModelRegistry.updateCustomModels(geminiModels: const [], groqModels: const []);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('registry includes Gemma 4 models and routes provider correctly', () {
    final ids = AiModelRegistry.allGeminiModels.map((m) => m.id).toList();
    expect(ids, contains('gemma-4-26b-a4b-it'));
    expect(ids, contains('gemma-4-31b-it'));

    expect(AiModelRegistry.isGemmaModel('gemma-4-26b-a4b-it'), isTrue);
    expect(AiModelRegistry.isGemmaModel('models/gemma-4-31b-it'), isTrue);
    expect(AiModelRegistry.isGeminiFamily('gemma-4-26b-a4b-it'), isTrue);
    expect(AiModelRegistry.detectProvider('gemma-4-31b-it'), AiProvider.gemini);
    expect(
      AiModelRegistry.normalizeModelId('models/gemma-4-26b-a4b-it'),
      'gemma-4-26b-a4b-it',
    );
  });

  test('SettingsRepository persists custom models and notifies registry', () async {
    final settings = await SettingsRepository.getInstance();
    var notifications = 0;
    void listener() => notifications++;
    AiModelRegistry.customModelsRevision.addListener(listener);
    addTearDown(() => AiModelRegistry.customModelsRevision.removeListener(listener));

    settings.addCustomGeminiModel('models/gemini-4.0-flash');
    settings.addCustomGroqModel('llama-4-maverick');

    expect(settings.customGeminiModels, contains('gemini-4.0-flash'));
    expect(
      AiModelRegistry.allGeminiModels.map((m) => m.id),
      contains('gemini-4.0-flash'),
    );
    expect(
      AiModelRegistry.allGroqModels.map((m) => m.id),
      contains('llama-4-maverick'),
    );
    expect(AiModelRegistry.detectProvider('llama-4-maverick'), AiProvider.groq);
    expect(notifications, greaterThanOrEqualTo(2));

    settings.selectedGeminiModel = 'gemini-4.0-flash';
    settings.removeCustomGeminiModel('gemini-4.0-flash');
    settings.removeCustomGroqModel('llama-4-maverick');
    expect(settings.customGeminiModels, isNot(contains('gemini-4.0-flash')));
    expect(settings.selectedGeminiModel, 'gemini-3.1-flash-lite');
  });

  test('GeminiTranslator handles Gemma 4 REST format and filters thought parts', () async {
    final capturedBodies = <Map<String, dynamic>>[];
    final dio = Dio();
    dio.httpClientAdapter = _CapturingAdapter((options) async {
      capturedBodies.add(Map<String, dynamic>.from(options.data as Map));
      return ResponseBody.fromString(
        '{"candidates":[{"content":{"parts":[{"thought":true,"text":"thinking..."},{"text":"{\\"items\\":[{\\"id\\":1,\\"translation\\":\\"Xin chao\\"}]}"}]}}]}',
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });

    final translator = GeminiTranslator(
      apiKeys: ['AIzaTestKey'],
      modelId: 'models/gemma-4-26b-a4b-it',
      dio: dio,
    );

    final raw = await translator.callGeminiRestApi(
      '{"items":[{"id":1,"text":"Hello"}]}',
      'System rules',
      'AIzaTestKey',
      requestJson: true,
    );

    expect(raw, '{"items":[{"id":1,"translation":"Xin chao"}]}');
    expect(capturedBodies, hasLength(1));
    final body = capturedBodies.first;
    expect(body.containsKey('systemInstruction'), isFalse);
    final genConfig = body['generationConfig'] as Map;
    expect(genConfig.containsKey('responseSchema'), isFalse);
    expect(genConfig.containsKey('responseMimeType'), isFalse);
    final userText =
        ((body['contents'] as List).first['parts'] as List).first['text']
            as String;
    expect(userText, contains('System rules'));
    expect(userText, contains('Hello'));
  });

  test('SmartAiTranslator preserves Gemma 4 as primary Gemini candidate', () {
    final coordinator = SmartAiTranslator(
      geminiKeys: ['AIzaTestKey'],
      initialModelId: 'gemma-4-31b-it',
    );
    final candidates = coordinator.getCandidateModels(
      AiProvider.gemini,
      'gemma-4-31b-it',
    );
    expect(candidates.first, 'gemma-4-31b-it');
    expect(candidates, containsAll(['gemini-3.1-flash-lite', 'gemini-3.5-flash-lite']));
  });

  test('SmartAiTranslator rotates model on 429 then rotates key on exhaustion', () async {
    final calls = <String>[];
    final dio = Dio();
    dio.httpClientAdapter = _CapturingAdapter((options) async {
      final path = options.uri.path;
      final key = options.uri.queryParameters['key'] ?? '';
      calls.add('$key|$path');

      // Key1 hits 429 on every model; Key2 hits 429 on first model then succeeds on fallback model.
      if (key == 'KEY_1' || path.contains('gemma-4-31b-it')) {
        return ResponseBody.fromString(
          '{"error":{"code":429,"message":"Rate limit"}}',
          429,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }

      return ResponseBody.fromString(
        '{"candidates":[{"content":{"parts":[{"text":"{\\"items\\":[{\\"id\\":1,\\"translation\\":\\"Da xoay key va model\\"}]}"}]}}]}',
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });

    final translator = SmartAiTranslator(
      geminiKeys: ['KEY_1', 'KEY_2'],
      initialModelId: 'gemma-4-31b-it',
      enableSmartModelFallback: true,
      enableCrossProviderFallback: false,
      enableDualModelBalancing: false,
      dio: dio,
    );

    final doc = SubtitleDocument([
      SubtitleItem(id: 1, startMs: 0, endMs: 1000, originalText: '你好'),
    ]);

    await translator.translateSubtitles(
      document: doc,
      chunkSize: 1,
      threadCount: 1,
      enableCheckpoint: false,
    );

    expect(doc.items.first.translatedText, 'Da xoay key va model');
    expect(
      calls.any((c) => c.startsWith('KEY_1|') && c.contains('gemma-4-31b-it')),
      isTrue,
    );
    expect(
      calls.any((c) => c.startsWith('KEY_1|') && c.contains('gemini-3.1-flash-lite')),
      isTrue,
    );
    expect(
      calls.any((c) => c.startsWith('KEY_2|') && !c.contains('gemma-4-31b-it')),
      isTrue,
    );
  });

  test('getCandidateModels excludes Gemini/Gemma models when crossing to Groq', () {
    final translator = SmartAiTranslator();

    final groqModelsFromGemini = translator.getCandidateModels(
      AiProvider.groq,
      'gemini-3.1-flash-lite',
    );
    expect(groqModelsFromGemini.first, 'openai/gpt-oss-120b');
    expect(groqModelsFromGemini.any((m) => m.contains('gemini')), isFalse);

    final groqModelsFromGemma = translator.getCandidateModels(
      AiProvider.groq,
      'gemma-4-31b-it',
    );
    expect(groqModelsFromGemma.first, 'openai/gpt-oss-120b');
    expect(groqModelsFromGemma.any((m) => m.contains('gemma')), isFalse);

    final geminiModelsFromGroq = translator.getCandidateModels(
      AiProvider.gemini,
      'llama-3.3-70b-versatile',
    );
    expect(geminiModelsFromGroq.first, 'gemini-3.1-flash-lite');
    expect(
      geminiModelsFromGroq.any((m) => m == 'llama-3.3-70b-versatile'),
      isFalse,
    );
  });

  test(
    'SmartAiTranslator trips 503 circuit breaker and jumps straight to Groq with valid Groq model',
    () async {
      final recordedRequests = <String>[];
      final dio = Dio();
      dio.httpClientAdapter = _CapturingAdapter((options) async {
        final uriStr = options.uri.toString();
        final isGroq = uriStr.contains('api.groq.com');
        if (isGroq) {
          final auth = options.headers['Authorization']?.toString() ?? '';
          final bodyMap =
              jsonDecode(jsonEncode(options.data)) as Map<String, dynamic>;
          final model = bodyMap['model']?.toString() ?? '';
          recordedRequests.add('groq|$auth|$model');
          return ResponseBody.fromString(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content':
                        '{"items":[{"id":1,"translation":"Dich bang Groq thanh cong"}]}',
                  },
                },
              ],
            }),
            200,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            },
          );
        }

        final key = options.uri.queryParameters['key'] ?? '';
        final pathParts = options.uri.path.split('/');
        final modelPart = pathParts
            .firstWhere((p) => p.contains(':generateContent'), orElse: () => '')
            .split(':')
            .first;
        recordedRequests.add('gemini|$key|$modelPart');
        return ResponseBody.fromString(
          jsonEncode({
            'error': {'code': 503, 'message': 'Model overloaded at night'},
          }),
          503,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final translator = SmartAiTranslator(
        geminiKeys: const ['G1', 'G2', 'G3', 'G4'],
        groqKeys: const ['GSK_1'],
        initialModelId: 'gemini-3.1-flash-lite',
        enableSmartModelFallback: true,
        enableCrossProviderFallback: true,
        enableDualModelBalancing: false,
        dio: dio,
      );

      final doc1 = SubtitleDocument([
        SubtitleItem(id: 1, startMs: 0, endMs: 2000, originalText: 'Hello world'),
      ]);

      await translator.translateSubtitles(
        document: doc1,
        chunkSize: 1,
        threadCount: 1,
        enableCheckpoint: false,
      );

      expect(doc1.items.first.translatedText, 'Dich bang Groq thanh cong');
      final geminiCalls1 = recordedRequests
          .where((r) => r.startsWith('gemini|'))
          .toList();
      final groqCalls1 = recordedRequests
          .where((r) => r.startsWith('groq|'))
          .toList();

      // Dừng ngay sau 3 lỗi 503 liên tiếp trên Gemini, không lặp hết 4 key x N model
      expect(geminiCalls1.length, 3);
      expect(groqCalls1.length, 1);
      expect(groqCalls1.first, 'groq|Bearer GSK_1|openai/gpt-oss-120b');

      // Chunk thứ 2 khi Gemini đang trong cooldown 45s sẽ đi thẳng sang Groq luôn
      recordedRequests.clear();
      final doc2 = SubtitleDocument([
        SubtitleItem(id: 1, startMs: 2000, endMs: 4000, originalText: 'Second line'),
      ]);
      await translator.translateSubtitles(
        document: doc2,
        chunkSize: 1,
        threadCount: 1,
        enableCheckpoint: false,
      );

      expect(doc2.items.first.translatedText, 'Dich bang Groq thanh cong');
      expect(recordedRequests.where((r) => r.startsWith('gemini|')), isEmpty);
      expect(recordedRequests.where((r) => r.startsWith('groq|')).length, 1);

      // Xác nhận lỗi Dio timeout / 502 sau khi bị GeminiTranslator bọc thành Exception vẫn kích hoạt nhảy provider
      expect(
        SmartAiTranslator.isServerUnavailableError(
          Exception(
            'Gemini API lỗi: The request connection took longer than 0:01:30.000000. It was aborted.',
          ),
        ),
        isTrue,
      );
      expect(
        SmartAiTranslator.isServerUnavailableError(
          Exception('Gemini API lỗi HTTP 502: Bad error'),
        ),
        isTrue,
      );
    },
  );

  testWidgets('SettingsScreen allows hot-adding custom model without rebuild', (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: const SettingsScreen(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('AI Dịch thuật (Gemini & Groq)'));
    await tester.pumpAndSettle();

    final verticalScrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Thêm Model ID mới (không cần build lại app):'),
      200,
      scrollable: verticalScrollable,
    );
    await tester.ensureVisible(
      find.text('Thêm Model ID mới (không cần build lại app):'),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'vd: gemma-4-12b-it, gemini-4-flash...'),
      'gemma-4-custom-it',
    );
    await tester.ensureVisible(find.text('Thêm'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Thêm'));
    await tester.pumpAndSettle();

    final settings = await SettingsRepository.getInstance();
    expect(settings.customGeminiModels, contains('gemma-4-custom-it'));
    expect(settings.selectedGeminiModel, 'gemma-4-custom-it');
  });
}
