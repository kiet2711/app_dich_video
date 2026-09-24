import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../model/subtitle_document.dart';
import '../model/subtitle_item.dart';

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
    bool Function()? isCancelled,
    void Function(double progress, String message)? progressCallback,
  }) async {
    if (document.isEmpty) return document;
    if (apiKeys.isEmpty) {
      throw StateError(
        'Chưa có Groq API Key! Vui lòng vào Cài đặt để thêm Key.',
      );
    }

    final safeChunkSize = chunkSize.clamp(1, 100);
    final items = document.items;
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

    final workerCount = threadCount.clamp(1, 10).clamp(1, totalChunks);
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
        final translatedTexts = await _translateChunkWithRetry(
          chunkItems,
          systemPrompt,
          targetLanguage,
          isCancelled: isCancelled,
        );

        for (var i = 0; i < chunkItems.length; i++) {
          final translated = translatedTexts[i].trim();
          chunkItems[i].translatedText = translated.isEmpty
              ? chunkItems[i].originalText
              : translated;
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
    final workerCount = threadCount.clamp(1, 10).clamp(1, items.length);
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

  Future<List<String>> _translateChunkWithRetry(
    List<SubtitleItem> items,
    String systemPrompt,
    String targetLanguage, {
    bool Function()? isCancelled,
  }) async {
    final attempts = math.max(3, apiKeys.length * 2);
    Object? lastError;

    for (var attempt = 0; attempt < attempts; attempt++) {
      if (isCancelled?.call() == true) {
        throw StateError('Đã huỷ tác vụ');
      }

      final key = getNextApiKey();
      final userPrompt = _buildSrtPromptChunk(items, targetLanguage);

      try {
        final rawResponse = await callGroqRestApi(userPrompt, systemPrompt, key);
        final cleanedResponse = _cleanThinkingContent(rawResponse);
        final parsedItems = _parseSrtResponse(cleanedResponse);

        if (parsedItems.isNotEmpty) {
          final translatedResults = List<String>.filled(items.length, '');
          final usedParsedIndices = <int>{};

          // Tầng 1: khớp chính xác theo ID (1-based relative chunk ID).
          for (var idx = 0; idx < items.length; idx++) {
            final expectedId = idx + 1;
            final parsedIndex = _findUnusedParsedIndex(
              parsedItems,
              usedParsedIndices,
              (parsed) => parsed.id == expectedId,
            );
            if (parsedIndex != -1) {
              usedParsedIndices.add(parsedIndex);
              translatedResults[idx] = parsedItems[parsedIndex].originalText;
            }
          }

          // Tầng 2: khớp theo timecode.
          for (var idx = 0; idx < items.length; idx++) {
            if (translatedResults[idx].trim().isNotEmpty) continue;
            final expectedTimecode = _normalizeTimecode(
              items[idx].formatSrtTimecode(),
            );
            final parsedIndex = _findUnusedParsedIndex(
              parsedItems,
              usedParsedIndices,
              (parsed) =>
                  _normalizeTimecode(parsed.formatSrtTimecode()) ==
                  expectedTimecode,
            );
            if (parsedIndex != -1) {
              usedParsedIndices.add(parsedIndex);
              translatedResults[idx] = parsedItems[parsedIndex].originalText;
            }
          }

          // Tầng 3: ghép tuần tự các câu còn lại.
          var unusedIndex = 0;
          for (var idx = 0; idx < items.length; idx++) {
            if (translatedResults[idx].trim().isNotEmpty) continue;
            while (unusedIndex < parsedItems.length &&
                usedParsedIndices.contains(unusedIndex)) {
              unusedIndex++;
            }
            if (unusedIndex < parsedItems.length) {
              usedParsedIndices.add(unusedIndex);
              translatedResults[idx] = parsedItems[unusedIndex].originalText;
              unusedIndex++;
            }
          }

          // Tầng 4: dịch riêng câu bị rỗng hoặc thiếu nội dung chữ.
          for (var idx = 0; idx < items.length; idx++) {
            final original = items[idx].originalText.trim();
            final translated = translatedResults[idx].trim();
            final originalHasContent = _containsLetterOrNumber(original);
            final translationHasContent = _containsLetterOrNumber(translated);
            if (originalHasContent && !translationHasContent) {
              try {
                final single = await _translateSingleTextInternal(
                  original,
                  systemPrompt,
                  isCancelled: isCancelled,
                );
                translatedResults[idx] = _containsLetterOrNumber(single)
                    ? single
                    : original;
              } catch (_) {
                translatedResults[idx] = original;
              }
            } else if (translated.isEmpty) {
              translatedResults[idx] = original;
            }
          }

          return translatedResults;
        }
        lastError = const FormatException(
          'Groq không trả về phụ đề theo định dạng SRT hợp lệ.',
        );
      } catch (error) {
        lastError = error;
      }
    }

    throw Exception(
      'Dịch phụ đề thất bại sau $attempts lần thử: ${_readableError(lastError)}',
    );
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
    String apiKey,
  ) async {
    const url = 'https://api.groq.com/openai/v1/chat/completions';

    final body = <String, dynamic>{
      'model': modelId,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userPrompt},
      ],
      'temperature': 0.2,
      'max_tokens': 8192,
    };

    try {
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
    } on DioException catch (error) {
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
    // Bỏ qua các markdown code block ```srt ... ```
    if (cleaned.startsWith('```')) {
      cleaned = cleaned.replaceFirst(RegExp(r'^```[a-zA-Z]*\n?'), '');
      cleaned = cleaned.replaceFirst(RegExp(r'\n?```$'), '');
    }
    return cleaned.trim();
  }

  String _buildSrtPromptChunk(
    List<SubtitleItem> items,
    String targetLanguage,
  ) {
    final buffer = StringBuffer();
    buffer.writeln(
      'Dưới đây là các khối phụ đề SRT cần dịch sang $targetLanguage. '
      'Hãy dịch toàn bộ nội dung sang $targetLanguage, bảo toàn đúng 100% số khối, '
      'thứ tự ID và timecode SRT:',
    );
    buffer.writeln();

    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      buffer.writeln(i + 1);
      buffer.writeln(item.formatSrtTimecode());
      buffer.writeln(item.originalText);
      buffer.writeln();
    }
    return buffer.toString().trim();
  }

  List<SubtitleItem> _parseSrtResponse(String srtText) {
    final items = <SubtitleItem>[];
    final normalized = srtText.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final blocks = normalized.split(RegExp(r'\n\s*\n'));

    for (final block in blocks) {
      final lines = block
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      if (lines.length < 2) continue;

      int? id;
      String? timecodeLine;
      var textStartIndex = 0;

      if (RegExp(r'^\d+$').hasMatch(lines[0])) {
        id = int.tryParse(lines[0]);
        if (lines.length > 1 && lines[1].contains('-->')) {
          timecodeLine = lines[1];
          textStartIndex = 2;
        }
      } else if (lines[0].contains('-->')) {
        timecodeLine = lines[0];
        textStartIndex = 1;
      }

      if (timecodeLine == null) continue;

      final parts = timecodeLine.split('-->');
      if (parts.length != 2) continue;

      final startMs = _parseTimecodeToMs(parts[0].trim());
      final endMs = _parseTimecodeToMs(parts[1].trim());
      if (startMs == null || endMs == null) continue;

      final text = lines.sublist(textStartIndex).join('\n').trim();
      items.add(
        SubtitleItem(
          id: id ?? items.length + 1,
          startMs: startMs,
          endMs: endMs,
          originalText: text,
        ),
      );
    }
    return items;
  }

  int? _parseTimecodeToMs(String timecode) {
    final match = RegExp(
      r'^(?:(\d+):)?(\d{1,2}):(\d{2})[,.](\d{1,3})$',
    ).firstMatch(timecode.replaceAll(' ', ''));
    if (match == null) return null;

    final hours = int.tryParse(match.group(1) ?? '0') ?? 0;
    final minutes = int.tryParse(match.group(2) ?? '0') ?? 0;
    final seconds = int.tryParse(match.group(3) ?? '0') ?? 0;
    var millisStr = match.group(4) ?? '0';
    while (millisStr.length < 3) {
      millisStr += '0';
    }
    if (millisStr.length > 3) {
      millisStr = millisStr.substring(0, 3);
    }
    final millis = int.tryParse(millisStr) ?? 0;

    return (hours * 3600 + minutes * 60 + seconds) * 1000 + millis;
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

    final srtRules = isSrt
        ? '''

QUY TẮC BẮT BUỘC ĐỂ KHÔNG BỊ DỊCH THIẾU HOẶC MẤT DÒNG PHỤ ĐỀ:
1. TUYỆT ĐỐI BẢO TOÀN 100% CẤU TRÚC SRT: đầu vào có bao nhiêu khối phụ đề (ID từ 1 đến N), đầu ra BẮT BUỘC PHẢI CÓ ĐỦ CHÍNH XÁC bấy nhiêu khối.
2. Giữ nguyên số thứ tự ID và dòng timecode (00:00:00,000 --> 00:00:00,000). Dưới mỗi timecode là ĐÚNG 1 bản dịch tương ứng bằng $targetLanguage.
3. TUYỆT ĐỐI KHÔNG thay câu thoại bằng dấu chấm, dấu hỏi hoặc dấu ba chấm. Câu ngắn và thán từ vẫn BẮT BUỘC PHẢI DỊCH ĐẦY ĐỦ; không được nuốt câu.
4. KHÔNG gộp hai khối phụ đề thành một và KHÔNG bỏ qua bất kỳ khối nào.
5. KHÔNG thêm lời chào, nhãn "bản gốc/bản dịch", Markdown hoặc giải thích ngoài định dạng SRT chuẩn.
'''
        : '';

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
$srtRules
'''
        .trim();
  }

  static int _findUnusedParsedIndex(
    List<SubtitleItem> parsedItems,
    Set<int> usedIndices,
    bool Function(SubtitleItem item) predicate,
  ) {
    for (var index = 0; index < parsedItems.length; index++) {
      if (!usedIndices.contains(index) && predicate(parsedItems[index])) {
        return index;
      }
    }
    return -1;
  }

  static String _normalizeTimecode(String value) =>
      value.replaceAll(' ', '').replaceAll('.', ',');

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
