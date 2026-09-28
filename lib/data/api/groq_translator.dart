import 'dart:math' as math;

import 'package:dio/dio.dart';

import 'gemini_translator.dart';

import '../model/subtitle_document.dart';
import '../model/subtitle_item.dart';
import '../../domain/ai/translation_checkpoint_manager.dart';

class GroqTranslator {
  final List<String> apiKeys;
  final String modelId;
  final Dio dio;
  int _keyIndex = 0;

  GroqTranslator({
    required List<String> apiKeys,
    String modelId = 'openai/gpt-oss-120b',
    Dio? dio,
  }) : apiKeys = apiKeys
           .map((key) => key.trim())
           .where((key) => key.isNotEmpty)
           .toList(growable: false),
       modelId = modelId.trim().isEmpty
           ? 'openai/gpt-oss-120b'
           : modelId.trim(),
       dio =
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
        'Chưa cấu hình Groq API Key! Vui lòng nhập ít nhất 1 Key trong Cài đặt.',
      );
    }
    final key = apiKeys[_keyIndex % apiKeys.length];
    _keyIndex++;
    return key;
  }

  Future<SubtitleDocument> translateSubtitles({
    required SubtitleDocument document,
    String stylePreset = 'Zhihu',
    String customPrompt = '',
    String targetLanguage = 'Tiếng Việt',
    int chunkSize = 45,
    int threadCount = 3,
    String? checkpointSessionId,
    bool enableCheckpoint = true,
    bool Function()? isCancelled,
    void Function(double progress, String message)? progressCallback,
  }) async {
    if (document.isEmpty) return document;
    if (apiKeys.isEmpty) {
      throw StateError(
        'Chưa có Groq API Key! Vui lòng vào Cài đặt để thêm Key.',
      );
    }

    final items = document.items;
    final sessionKey = checkpointSessionId ??
        TranslationCheckpointManager.generateSessionKey(
          document: document,
          targetLanguage: targetLanguage,
        );

    // 1. Phục hồi trạng thái đã dịch từ Checkpoint nếu có
    if (enableCheckpoint) {
      final cachedTranslations =
          await TranslationCheckpointManager.loadCheckpoint(sessionKey);
      if (cachedTranslations.isNotEmpty) {
        var restored = 0;
        for (final item in items) {
          final trans = cachedTranslations[item.id]?.trim();
          if (trans != null && trans.isNotEmpty) {
            item.translatedText = trans;
            item.normalizeTranslation();
            restored++;
          }
        }
        if (restored > 0) {
          progressCallback?.call(
            0.05,
            'Đã khôi phục $restored/${items.length} câu từ Checkpoint!',
          );
          final remaining = items.where((it) =>
              it.translatedText.trim().isEmpty ||
              it.translatedText.trim() == it.originalText.trim());
          if (remaining.isEmpty) {
            progressCallback?.call(1.0, 'Đã hoàn tất toàn bộ phụ đề từ Checkpoint!');
            await TranslationCheckpointManager.clearCheckpoint(sessionKey);
            return document;
          }
        }
      }
    }

    final safeChunkSize = chunkSize.clamp(1, 100);
    final chunks = <List<SubtitleItem>>[];
    for (var i = 0; i < items.length; i += safeChunkSize) {
      chunks.add(items.sublist(i, math.min(i + safeChunkSize, items.length)));
    }
    final totalChunks = chunks.length;
    final systemPrompt = buildSystemPrompt(
      stylePreset,
      targetLanguage,
      customPrompt,
    );

    final workerCount = threadCount.clamp(1, 20).clamp(1, totalChunks);
    progressCallback?.call(
      0.05,
      workerCount > 1
          ? 'Đang khởi chạy $workerCount luồng Groq dịch $totalChunks khối phụ đề...'
          : 'Đang chuẩn bị dịch $totalChunks khối phụ đề...',
    );

    var completed = 0;
    var nextChunk = 0;

    Future<void> worker() async {
      while (true) {
        if (isCancelled?.call() == true) {
          throw StateError('Đã huỷ tác vụ');
        }
        final chunkIdx = nextChunk++;
        if (chunkIdx >= chunks.length) return;
        final chunkItems = chunks[chunkIdx];

        // Lọc các câu chưa có bản dịch trong chunk này
        final pendingInChunk = chunkItems.where((it) {
          final trans = it.translatedText.trim();
          final orig = it.originalText.trim();
          return trans.isEmpty || trans == orig;
        }).toList();

        if (pendingInChunk.isNotEmpty) {
          // Lấy sliding context (tối đa 4 câu trước batch này đã có bản dịch)
          final chunkStartIdx = chunkIdx * safeChunkSize;
          final contextItems = <SubtitleItem>[];
          for (var c = math.max(0, chunkStartIdx - 4); c < chunkStartIdx; c++) {
            final prevItem = items[c];
            if (prevItem.translatedText.trim().isNotEmpty &&
                prevItem.translatedText.trim() != prevItem.originalText.trim()) {
              contextItems.add(prevItem);
            }
          }

          final translatedMap = await _translateChunkWithRetry(
            pendingInChunk,
            systemPrompt,
            targetLanguage,
            contextItems: contextItems,
            isCancelled: isCancelled,
          );

          // Map theo ID trực tiếp vào cue gốc, không bao giờ dùng index/position
          for (final originalItem in pendingInChunk) {
            final trans = translatedMap[originalItem.id]?.trim() ?? '';
            originalItem.translatedText = trans.isNotEmpty
                ? trans
                : originalItem.originalText;
            originalItem.normalizeTranslation();
          }

          // LƯU CHECKPOINT NGAY SAU KHI DỊCH XONG BATCH
          if (enableCheckpoint) {
            final currentMap = <int, String>{};
            for (final it in items) {
              final tr = it.translatedText.trim();
              if (tr.isNotEmpty && tr != it.originalText.trim()) {
                currentMap[it.id] = tr;
              }
            }
            await TranslationCheckpointManager.saveCheckpoint(
              sessionKey: sessionKey,
              targetLanguage: targetLanguage,
              totalItems: items.length,
              translations: currentMap,
            );
          }
        }

        completed++;
        final progress = (completed / totalChunks).clamp(0.0, 1.0);
        progressCallback?.call(
          progress,
          'Groq: Đã hoàn tất $completed/$totalChunks khối (${(progress * 100).round()}%)...',
        );
      }
    }

    final workers = List.generate(workerCount, (_) => worker());
    await Future.wait(workers);

    // Dịch hoàn tất 100% -> Tự động dọn dẹp Checkpoint tạm
    if (enableCheckpoint) {
      await TranslationCheckpointManager.clearCheckpoint(sessionKey);
    }

    return document;
  }

  Future<List<String>> translateItemsByStableId({
    required List<SubtitleItem> items,
    String stylePreset = 'Zhihu',
    String customPrompt = '',
    String targetLanguage = 'Tiếng Việt',
    int threadCount = 3,
    bool Function()? isCancelled,
    void Function(double progress, String message)? progressCallback,
  }) async {
    if (items.isEmpty) return const [];
    if (apiKeys.isEmpty) {
      throw StateError(
        'Chưa có Groq API Key! Vui lòng vào Cài đặt để thêm Key.',
      );
    }

    final systemPrompt = buildSystemPrompt(
      stylePreset,
      targetLanguage,
      customPrompt,
    );
    final results = List<String>.filled(items.length, '');
    final workerCount = threadCount.clamp(1, 20).clamp(1, items.length);
    var nextIndex = 0;
    var completed = 0;

    Future<void> worker() async {
      while (true) {
        if (isCancelled?.call() == true) {
          throw StateError('Đã huỷ tác vụ');
        }
        final idx = nextIndex++;
        if (idx >= items.length) return;
        final item = items[idx];
        final original = item.originalText.trim();
        if (original.isEmpty) {
          results[idx] = '';
        } else {
          try {
            final translated = await _translateSingleTextInternal(
              original,
              systemPrompt,
              isCancelled: isCancelled,
            );
            results[idx] = translated.isNotEmpty ? translated : original;
          } catch (_) {
            results[idx] = original;
          }
        }
        completed++;
        final progress = (completed / items.length).clamp(0.0, 1.0);
        progressCallback?.call(
          progress,
          'Dịch từng câu: $completed/${items.length}...',
        );
      }
    }

    final workers = List.generate(workerCount, (_) => worker());
    await Future.wait(workers);
    return results;
  }

  Future<Map<int, String>> _translateChunkWithRetry(
    List<SubtitleItem> items,
    String systemPrompt,
    String targetLanguage, {
    List<SubtitleItem>? contextItems,
    bool Function()? isCancelled,
  }) async {
    final attempts = math.max(3, apiKeys.length * 2);
    final expectedIds = items.map((e) => e.id).toSet();
    final collectedResults = <int, String>{};

    var currentItemsToTranslate = List<SubtitleItem>.from(items);

    for (var attempt = 0; attempt < attempts; attempt++) {
      if (isCancelled?.call() == true) {
        throw StateError('Đã huỷ tác vụ');
      }
      if (currentItemsToTranslate.isEmpty) break;

      final key = getNextApiKey();
      final userPrompt = GeminiTranslator.buildBatchPayload(
        items: currentItemsToTranslate,
        contextItems: contextItems,
      );

      try {
        final rawResponse = await callGroqRestApi(
          userPrompt,
          systemPrompt,
          key,
          requestJson: true,
        );
        final cleanedResponse = _cleanThinkingContent(rawResponse);
        final parsed = GeminiTranslator.parseBatchResponse(
          cleanedResponse,
          currentItemsToTranslate,
        );
        collectedResults.addAll(parsed);

        final missingIds = expectedIds
            .where((id) => !collectedResults.containsKey(id))
            .toSet();

        if (missingIds.isEmpty) break;

        // Nếu chỉ thiếu đúng 1 ID: dịch đơn lẻ để cứu ngay câu đó với độ ưu tiên cao nhất
        if (missingIds.length == 1) {
          final missingItem = items.firstWhere((it) => missingIds.contains(it.id));
          try {
            final single = await _translateSingleTextInternal(
              missingItem.originalText,
              systemPrompt,
              isCancelled: isCancelled,
            );
            if (_containsLetterOrNumber(single)) {
              collectedResults[missingItem.id] = single;
              break;
            }
          } catch (_) {}
        }

        // Chỉ retry các ID còn thiếu
        currentItemsToTranslate = items
            .where((it) => missingIds.contains(it.id))
            .toList();

        await Future.delayed(Duration(milliseconds: 150 * (attempt + 1)));
      } catch (_) {
        await Future.delayed(Duration(milliseconds: 250 * (attempt + 1)));
      }
    }

    // Tầng cứu câu: Nếu câu nào bị rỗng hoặc chỉ có dấu câu
    for (final item in items) {
      final existing = collectedResults[item.id]?.trim() ?? '';
      final original = item.originalText.trim();
      final origHasText = _containsLetterOrNumber(original);
      final transHasText = _containsLetterOrNumber(existing);

      if (origHasText && !transHasText) {
        try {
          final single = await _translateSingleTextInternal(
            original,
            systemPrompt,
            isCancelled: isCancelled,
          );
          collectedResults[item.id] = _containsLetterOrNumber(single)
              ? single
              : original;
        } catch (_) {
          collectedResults[item.id] = original;
        }
      } else if (existing.isEmpty) {
        collectedResults[item.id] = original;
      }
    }

    return collectedResults;
  }

  Future<String> _translateSingleTextInternal(
    String text,
    String systemPrompt, {
    bool Function()? isCancelled,
  }) async {
    final prompt =
        'Hãy dịch câu thoại sau đây sang ngôn ngữ đích. Chỉ trả về duy nhất '
        'nội dung bản dịch, không giải thích; nếu dịch sang tiếng Việt, phiên âm '
        'toàn bộ tên riêng tiếng Trung sang Hán Việt:\n$text';
    final attempts = math.max(3, apiKeys.length);
    Object? lastError;

    for (var attempt = 0; attempt < attempts; attempt++) {
      if (isCancelled?.call() == true) {
        throw StateError('Đã huỷ tác vụ');
      }
      final key = getNextApiKey();
      try {
        final response = (await callGroqRestApi(
          prompt,
          systemPrompt,
          key,
        )).trim();
        final cleanedThinking = _cleanThinkingContent(response);
        final cleaned = cleanedThinking
            .replaceFirst(RegExp(r'^\[\d+\][\s:\-]+'), '')
            .trim();
        if (cleaned.isNotEmpty) return cleaned;
      } catch (error) {
        lastError = error;
      }
    }

    throw Exception('Dịch câu thất bại: ${_readableError(lastError)}');
  }

  Future<String> callGroqRestApi(
    String userPrompt,
    String systemPrompt,
    String apiKey, {
    String? overrideModelId,
    bool requestJson = false,
  }) async {
    const url = 'https://api.groq.com/openai/v1/chat/completions';

    Map<String, dynamic> buildBody({required bool withJsonFormat}) => {
      'model': overrideModelId ?? modelId,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userPrompt},
      ],
      'temperature': 0.2,
      'max_tokens': 8192,
      if (withJsonFormat) 'response_format': {'type': 'json_object'},
    };

    Future<String> send(Map<String, dynamic> body) async {
      final response = await dio.post<Map<String, dynamic>>(
        url,
        data: body,
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
        ),
      );

      final data = response.data;
      if (data == null) {
        throw const FormatException('Phản hồi trống từ Groq.');
      }

      final choices = data['choices'];
      if (choices is! List || choices.isEmpty) {
        throw const FormatException('Groq không trả về choices nào.');
      }

      final firstChoice = choices.first;
      final message = firstChoice is Map ? firstChoice['message'] : null;
      final content = message is Map ? message['content'] : null;
      final text = content is String ? content.trim() : '';

      if (text.isEmpty) {
        throw const FormatException('Groq trả về nội dung rỗng.');
      }
      return text;
    }

    try {
      return await send(buildBody(withJsonFormat: requestJson));
    } on DioException catch (error) {
      if (requestJson && error.response?.statusCode == 400) {
        try {
          return await send(buildBody(withJsonFormat: false));
        } catch (_) {}
      }

      final status = error.response?.statusCode;
      final responseData = error.response?.data;
      final detail = responseData ?? error.message;
      throw Exception(
        'Groq API lỗi${status == null ? '' : ' HTTP $status'}: $detail',
      );
    }
  }

  String _cleanThinkingContent(String raw) {
    // Loại bỏ khối <think>...</think> nếu có từ các model suy luận (Qwen hoặc GPT-OSS)
    var cleaned = raw.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
    // Bỏ qua các markdown code block ```srt ... ``` hoặc ```json ... ```
    if (cleaned.startsWith('```')) {
      cleaned = cleaned.replaceFirst(RegExp(r'^```[a-zA-Z]*\n?'), '');
      cleaned = cleaned.replaceFirst(RegExp(r'\n?```$'), '');
    }
    return cleaned.trim();
  }

  String buildSystemPrompt(
    String stylePreset,
    String targetLanguage,
    String customPrompt, {
    bool isSrt = true,
  }) {
    final styleGuide = switch (stylePreset.trim().toLowerCase()) {
      'zhihu' =>
        'Phong cách phim ngắn Zhihu vả mặt kịch tính, nhịp điệu dồn dập, sắc bén, gãy gọn, gay cấn.',
      'thuanviet' || 'thuần việt' =>
        'Phong cách văn học trau chuốt, mượt mà, giàu cảm xúc, thoát ý tự nhiên.',
      'cotrang' || 'cổ trang' =>
        'Phong cách cổ trang tiên hiệp huyền huyễn, bảo lưu chuẩn mực danh xưng, đại từ xưng hô và pháp bảo môn phái.',
      _ =>
        'Tự động nhận diện thể loại câu chuyện để dịch thoát nghĩa, tự nhiên và lôi cuốn nhất.',
    };

    final userCustomSection = customPrompt.trim().isNotEmpty
        ? '''
HƯỚNG DẪN BỔ SUNG ĐẶC BIỆT TỪ NGƯỜI DÙNG:
${customPrompt.trim()}
'''
        : '';

    final structuralRules = '''

QUY TẮC BẮT BUỘC ĐỂ KHÔNG BỊ DỊCH THIẾU HOẶC MẤT DÒNG PHỤ ĐỀ (BẢO TOÀN 100% CẤU TRÚC SRT VÀ ID):
1. BẢO TOÀN 100% CẤU TRÚC SRT và ID: Mỗi input ID trong "items" phải có đúng 1 bản dịch trong output items. KHÔNG bỏ qua bất kỳ khối nào.
2. TUYỆT ĐỐI không tạo, xóa, gộp (merge), tách (split) hoặc đổi số ID.
3. Chỉ xuất định dạng JSON hợp lệ: {"items": [{"id": ..., "translation": "..."}]}.
4. duration_ms là thời lượng hiển thị phụ đề tính bằng mili-giây. Với câu có duration_ms rất ngắn, ưu tiên câu văn ngắn gọn, súc tích tự nhiên mà vẫn giữ trọn ý nghĩa cốt lõi.
5. "context" (nếu có) CHỈ DÙNG ĐỂ THAM KHẢO NGỮ CẢNH (xưng hô, diễn biến câu chuyện), TUYỆT ĐỐI KHÔNG dịch lại các câu trong context và không đưa context vào danh sách output IDs.
6. TUYỆT ĐỐI KHÔNG thay câu thoại bằng dấu chấm, dấu hỏi hoặc dấu ba chấm. Câu ngắn và thán từ vẫn BẮT BUỘC PHẢI DỊCH ĐẦY ĐỦ; không được nuốt câu.
7. TUYỆT ĐỐI KHÔNG xuất timestamp, timecode, markdown hay bất kỳ lời giải thích nào ngoài JSON.
''';

    return '''
Bạn là chuyên gia dịch thuật phụ đề video và lời thoại phim chuyên nghiệp hàng đầu.
NGÔN NGỮ ĐÍCH CẦN DỊCH: $targetLanguage.

YÊU CẦU PHONG CÁCH:
$styleGuide

$userCustomSection
QUY TẮC BẮT BUỘC VỀ TÊN NHÂN VẬT VÀ TỪ NGỮ:
1. Khi dịch sang tiếng Việt, toàn bộ họ tên nhân vật, tên riêng, biệt danh và chức vụ tiếng Trung phải được chuyển sang âm Hán Việt chuẩn mực (ví dụ: 余昭昭 -> Dư Chiêu Chiêu, 顾总 -> Cố tổng, 陆爷 -> Lục gia).
2. Không dịch nửa vời và không để lẫn chữ Hán trong kết quả khi ngôn ngữ đích không phải tiếng Trung.
3. Kết quả phải dùng 100% ngôn ngữ đích: $targetLanguage.
$structuralRules
'''
        .trim();
  }

  static bool _containsLetterOrNumber(String value) =>
      RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(value);

  static String _readableError(Object? error) {
    if (error == null) return 'Không nhận được phản hồi hợp lệ từ Groq.';
    return error.toString().replaceFirst(
      RegExp(r'^(Exception|FormatException):\s*'),
      '',
    );
  }
}
