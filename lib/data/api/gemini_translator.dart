import 'package:dio/dio.dart';

import '../model/subtitle_document.dart';
import '../model/subtitle_item.dart';

class GeminiTranslator {
  final List<String> apiKeys;
  final String modelId;
  final Dio dio;
  int _keyIndex = 0;

  GeminiTranslator({
    required this.apiKeys,
    String modelId = 'gemini-3.5-flash-lite',
    Dio? dio,
  }) : modelId = (modelId.contains('3.1') ? 'gemini-3.1-flash-lite' : 'gemini-3.5-flash-lite'), dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 30),
               receiveTimeout: const Duration(seconds: 90),
             ),
           );

  String getNextApiKey() {
    if (apiKeys.isEmpty) {
      throw StateError(
        'ChÆ°a cáº¥u hÃ¬nh Gemini API Key! Vui lÃ²ng nháº­p Ã­t nháº¥t 1 Key trong CÃ i Ä‘áº·t.',
      );
    }
    final key = apiKeys[_keyIndex % apiKeys.length].trim();
    _keyIndex++;
    return key;
  }

  Future<SubtitleDocument> translateSubtitles({
    required SubtitleDocument document,
    String stylePreset = 'Zhihu',
    String customPrompt = '',
    String targetLanguage = 'Tiáº¿ng Viá»‡t',
    int chunkSize = 45,
    int threadCount = 2,
    bool Function()? isCancelled,
    void Function(double progress, String message)? progressCallback,
  }) async {
    if (document.isEmpty) return document;
    if (apiKeys.isEmpty) {
      throw StateError(
        'ChÆ°a cÃ³ Gemini API Key! Vui lÃ²ng vÃ o CÃ i Ä‘áº·t Ä‘á»ƒ thÃªm Key.',
      );
    }

    final items = document.items;
    final chunks = <List<SubtitleItem>>[];
    for (var i = 0; i < items.length; i += chunkSize) {
      chunks.add(items.sublist(i, (i + chunkSize).clamp(0, items.length)));
    }
    final totalChunks = chunks.length;
    final systemPrompt = buildSystemPrompt(
      stylePreset,
      targetLanguage,
      customPrompt,
    );

    progressCallback?.call(
      0.05,
      'Äang chuáº©n bá»‹ dá»‹ch $totalChunks khá»‘i phá»¥ Ä‘á»...',
    );

    var completed = 0;
    var nextChunk = 0;

    Future<void> worker() async {
      while (true) {
        if (isCancelled?.call() == true) throw StateError('ÄÃ£ huá»· tÃ¡c vá»¥');
        final chunkIdx = nextChunk++;
        if (chunkIdx >= chunks.length) return;
        final chunkItems = chunks[chunkIdx];
        final translatedTexts = await _translateChunkWithRetry(
          chunkItems,
          systemPrompt,
          targetLanguage,
        );

        for (var itemIdx = 0; itemIdx < chunkItems.length; itemIdx++) {
          final originalItem = chunkItems[itemIdx];
          final trans =
              (itemIdx < translatedTexts.length &&
                  translatedTexts[itemIdx].isNotEmpty)
              ? translatedTexts[itemIdx]
              : originalItem.originalText;
          originalItem.translatedText = trans;
          originalItem.normalizeTranslation();
        }

        completed++;
        final pct = 0.05 + (completed / totalChunks) * 0.90;
        progressCallback?.call(
          pct,
          'Gemini Ä‘Ã£ dá»‹ch xong $completed/$totalChunks khá»‘i phá»¥ Ä‘á»...',
        );
      }
    }

    final workerCount = threadCount.clamp(1, totalChunks);
    await Future.wait(List.generate(workerCount, (_) => worker()));

    progressCallback?.call(1.0, 'Dá»‹ch thuáº­t hoÃ n táº¥t!');
    return document;
  }

  Future<List<String>> _translateChunkWithRetry(
    List<SubtitleItem> items,
    String systemPrompt,
    String targetLanguage, {
    int maxRetries = 3,
  }) async {
    final srtInput = StringBuffer();
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      srtInput.writeln(i + 1);
      srtInput.writeln(it.formatSrtTimecode());
      srtInput.writeln(it.originalText);
      srtInput.writeln();
    }

    final prompt =
        """
  [Ná»˜I DUNG Báº®T BUá»˜C Dá»ŠCH 100% CÃC KHá»I PHá»¤ Äá»€ DÆ¯á»šI ÄÃ‚Y SANG $targetLanguage. TUYá»†T Äá»I KHÃ”NG ÄÆ¯á»¢C NUá»T CÃ‚U]:

${srtInput.toString()}
""";

    Object? lastError;
    final attempts = maxRetries.clamp(apiKeys.length, 10);
    for (var attempt = 0; attempt < attempts; attempt++) {
      final key = getNextApiKey();
      try {
        final rawResponse = await callGeminiRestApi(prompt, systemPrompt, key);
        final parsedItems = SubtitleDocument.parseSrt(rawResponse).items;

        if (parsedItems.isNotEmpty) {
          final translatedResults = List<String>.filled(items.length, '');
          final usedParsedIndices = <int>{};

          // Táº§ng 1: Khá»›p chÃ­nh xÃ¡c theo ID (1-based index)
          for (var idx = 0; idx < items.length; idx++) {
            final targetLocalId = idx + 1;
            final pIdx = parsedItems.indexWhere(
              (p) =>
                  p.id == targetLocalId &&
                  !usedParsedIndices.contains(parsedItems.indexOf(p)),
            );
            if (pIdx != -1) {
              usedParsedIndices.add(pIdx);
              translatedResults[idx] = parsedItems[pIdx].originalText;
            }
          }

          // Táº§ng 2: Khá»›p tuáº§n tá»± theo danh sÃ¡ch cÃ²n sÃ³t láº¡i
          var unusedIdx = 0;
          for (var idx = 0; idx < items.length; idx++) {
            if (translatedResults[idx].isNotEmpty) continue;
            while (unusedIdx < parsedItems.length &&
                usedParsedIndices.contains(unusedIdx)) {
              unusedIdx++;
            }
            if (unusedIdx < parsedItems.length) {
              usedParsedIndices.add(unusedIdx);
              translatedResults[idx] = parsedItems[unusedIdx].originalText;
              unusedIdx++;
            }
          }

          return translatedResults;
        }
      } catch (e) {
        lastError = e;
      }
    }

    throw Exception('Dá»‹ch khá»‘i tháº¥t báº¡i: $lastError');
  }

  Future<String> callGeminiRestApi(
    String userPrompt,
    String systemPrompt,
    String apiKey,
  ) async {
    final url =
        'https://generativelanguage.googleapis.com/v1beta/models/$modelId:generateContent?key=$apiKey';

    final body = {
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': userPrompt},
          ],
        },
      ],
      'systemInstruction': {
        'parts': [
          {'text': systemPrompt},
        ],
      },
      'generationConfig': {'temperature': 0.3, 'topP': 0.95},
    };

    final resp = await dio.post<Map<String, dynamic>>(
      url,
      data: body,
      options: Options(headers: {'Content-Type': 'application/json'}),
    );

    final data = resp.data;
    if (data == null) throw Exception('Pháº£n há»“i trá»‘ng tá»« Gemini');

    final candidates = data['candidates'] as List<dynamic>?;
    final firstCandidate = candidates?.isNotEmpty == true
        ? candidates![0] as Map<String, dynamic>
        : null;
    final parts = firstCandidate?['content']?['parts'] as List<dynamic>?;
    final text = parts?.isNotEmpty == true
        ? parts![0]['text'] as String?
        : null;

    if (text == null || text.trim().isEmpty) {
      throw Exception('KhÃ´ng tÃ¬m tháº¥y text trong candidates cá»§a Gemini');
    }
    return text;
  }

  String buildSystemPrompt(
    String stylePreset,
    String targetLanguage,
    String customPrompt, {
    bool isSrt = true,
  }) {
    if (customPrompt.trim().isNotEmpty) {
      return customPrompt.trim();
    }

    final styleInstruction = switch (stylePreset) {
      'Zhihu' => 'Phong cÃ¡ch phim ngáº¯n Zhihu/TikTok ká»‹ch tÃ­nh, ngáº¯n gá»n, váº£ máº·t, gay cáº¥n, xÆ°ng hÃ´ sáº¯c bÃ©n.',
      'CoTrang' || 'Cá»• trang' => 'Phong cÃ¡ch cá»• trang kiáº¿m hiá»‡p/tiÃªn hiá»‡p, ngÃ´n tá»« trang trá»ng, vÄƒn phong nho nhÃ£, xÆ°ng hÃ´ bá»•n tá»a, táº¡i háº¡, cÃ´ nÆ°Æ¡ng.',
      'ThuanViet' || 'Thuáº§n Viá»‡t' => 'Phong cÃ¡ch vÄƒn há»c thuáº§n Viá»‡t, tá»± nhiÃªn, gáº§n gÅ©i, Ä‘á»i thÆ°á»ng, trÃ´i cháº£y nhÆ° ngÆ°á»i báº£n Ä‘á»‹a trÃ² chuyá»‡n.',
      _ => 'Phong cÃ¡ch tá»± nhiÃªn, chuáº©n xÃ¡c, vÄƒn phong hiá»‡n Ä‘áº¡i.',
    };

    final formatInstruction = isSrt
        ? 'Báº®T BUá»˜C giá»¯ nguyÃªn cáº¥u trÃºc SRT (Sá»‘ thá»© tá»±, timecode 00:00:00,000 --> 00:00:00,000). Chá»‰ dá»‹ch pháº§n lá»i thoáº¡i.'
        : 'Chá»‰ tráº£ vá» ná»™i dung Ä‘Ã£ dá»‹ch, khÃ´ng giáº£i thÃ­ch thÃªm.';

    return """
Báº¡n lÃ  dá»‹ch giáº£ phim áº£nh chuyÃªn nghiá»‡p hÃ ng Ä‘áº§u. Nhiá»‡m vá»¥ cá»§a báº¡n lÃ  dá»‹ch phá»¥ Ä‘á» sang $targetLanguage.
$styleInstruction
$formatInstruction
QUY Táº®C Báº®T BUá»˜C:
1. PhiÃªn Ã¢m 100% há» tÃªn, tÃªn riÃªng, Ä‘á»‹a danh, chá»©c vá»¥ tiáº¿ng Trung sang Ã¢m HÃ¡n Viá»‡t chuáº©n má»±c (VÃ­ dá»¥: ä½™æ˜­æ˜­ -> DÆ° ChiÃªu ChiÃªu, é¡¾æ€» -> Cá»‘ tá»•ng, æ±ŸåŸŽ -> Giang ThÃ nh).
2. Tuyá»‡t Ä‘á»‘i khÃ´ng bá» sÃ³t báº¥t ká»³ cÃ¢u nÃ o.
3. KhÃ´ng Ä‘á»ƒ láº¡i chá»¯ HÃ¡n chÆ°a dá»‹ch.
""";
  }
}
