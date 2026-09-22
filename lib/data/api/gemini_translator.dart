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
    this.modelId = 'gemini-2.5-flash-lite',
    Dio? dio,
  }) : dio =
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
        'Chưa cấu hình Gemini API Key! Vui lòng nhập ít nhất 1 Key trong Cài đặt.',
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
    String targetLanguage = 'Tiếng Việt',
    int chunkSize = 45,
    int threadCount = 2,
    bool Function()? isCancelled,
    void Function(double progress, String message)? progressCallback,
  }) async {
    if (document.isEmpty) return document;
    if (apiKeys.isEmpty) {
      throw StateError(
        'Chưa có Gemini API Key! Vui lòng vào Cài đặt để thêm Key.',
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
      'Đang chuẩn bị dịch $totalChunks khối phụ đề...',
    );

    var completed = 0;
    var nextChunk = 0;

    Future<void> worker() async {
      while (true) {
        if (isCancelled?.call() == true) throw StateError('Đã huỷ tác vụ');
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
          'Gemini đã dịch xong $completed/$totalChunks khối phụ đề...',
        );
      }
    }

    final workerCount = threadCount.clamp(1, totalChunks);
    await Future.wait(List.generate(workerCount, (_) => worker()));

    progressCallback?.call(1.0, 'Dịch thuật hoàn tất!');
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
  [NỘI DUNG BẮT BUỘC DỊCH 100% CÁC KHỐI PHỤ ĐỀ DƯỚI ĐÂY SANG $targetLanguage. TUYỆT ĐỐI KHÔNG ĐƯỢC NUỐT CÂU]:

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

          // Tầng 1: Khớp chính xác theo ID (1-based index)
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

          // Tầng 2: Khớp tuần tự theo danh sách còn sót lại
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

    throw Exception('Dịch khối thất bại: $lastError');
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
    if (data == null) throw Exception('Phản hồi trống từ Gemini');

    final candidates = data['candidates'] as List<dynamic>?;
    final firstCandidate = candidates?.isNotEmpty == true
        ? candidates![0] as Map<String, dynamic>
        : null;
    final parts = firstCandidate?['content']?['parts'] as List<dynamic>?;
    final text = parts?.isNotEmpty == true
        ? parts![0]['text'] as String?
        : null;

    if (text == null || text.trim().isEmpty) {
      throw Exception('Không tìm thấy text trong candidates của Gemini');
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
      'Zhihu' => 'Phong cách phim ngắn Zhihu/TikTok kịch tính, ngắn gọn, vả mặt, gay cấn, xưng hô sắc bén.',
      'CoTrang' || 'Cổ trang' => 'Phong cách cổ trang kiếm hiệp/tiên hiệp, ngôn từ trang trọng, văn phong nho nhã, xưng hô bổn tọa, tại hạ, cô nương.',
      'ThuanViet' || 'Thuần Việt' => 'Phong cách văn học thuần Việt, tự nhiên, gần gũi, đời thường, trôi chảy như người bản địa trò chuyện.',
      _ => 'Phong cách tự nhiên, chuẩn xác, văn phong hiện đại.',
    };

    final formatInstruction = isSrt
        ? 'BẮT BUỘC giữ nguyên cấu trúc SRT (Số thứ tự, timecode 00:00:00,000 --> 00:00:00,000). Chỉ dịch phần lời thoại.'
        : 'Chỉ trả về nội dung đã dịch, không giải thích thêm.';

    return """
Bạn là dịch giả phim ảnh chuyên nghiệp hàng đầu. Nhiệm vụ của bạn là dịch phụ đề sang $targetLanguage.
$styleInstruction
$formatInstruction
QUY TẮC BẮT BUỘC:
1. Phiên âm 100% họ tên, tên riêng, địa danh, chức vụ tiếng Trung sang âm Hán Việt chuẩn mực (Ví dụ: 余昭昭 -> Dư Chiêu Chiêu, 顾总 -> Cố tổng, 江城 -> Giang Thành).
2. Tuyệt đối không bỏ sót bất kỳ câu nào.
3. Không để lại chữ Hán chưa dịch.
""";
  }
}
