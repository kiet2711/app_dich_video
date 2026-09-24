import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../model/subtitle_document.dart';
import '../model/subtitle_item.dart';

class GeminiTranslator {
  final List<String> apiKeys;
  final String modelId;
  final Dio dio;
  int _keyIndex = 0;

  GeminiTranslator({
    required List<String> apiKeys,
    String modelId = 'gemini-3.5-flash-lite',
    Dio? dio,
  }) : apiKeys = apiKeys
           .map((key) => key.trim())
           .where((key) => key.isNotEmpty)
           .toList(growable: false),
       modelId = modelId.trim().isEmpty
           ? 'gemini-3.5-flash-lite'
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
        'Chưa cấu hình Gemini API Key! Vui lòng nhập ít nhất 1 Key trong Cài đặt.',
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

    final workerCount = threadCount.clamp(1, 20).clamp(1, totalChunks);
    progressCallback?.call(
      0.05,
      workerCount > 1
          ? 'Đang khởi chạy $workerCount luồng Gemini dịch $totalChunks khối phụ đề...'
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

        for (var itemIdx = 0; itemIdx < chunkItems.length; itemIdx++) {
          final originalItem = chunkItems[itemIdx];
          final trans = itemIdx < translatedTexts.length
              ? translatedTexts[itemIdx].trim()
              : '';
          originalItem.translatedText = trans.isNotEmpty
              ? trans
              : originalItem.originalText;
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

    await Future.wait(List.generate(workerCount, (_) => worker()));

    progressCallback?.call(1.0, 'Dịch thuật hoàn tất!');
    return document;
  }

  Future<Map<int, String>> translateItems({
    required Map<int, String> items,
    String stylePreset = 'Zhihu',
    String customPrompt = '',
    String targetLanguage = 'Tiếng Việt',
    int chunkSize = 15,
    int threadCount = 2,
    void Function(double progress, String message)? progressCallback,
  }) async {
    final validItems = items.entries
        .where((entry) => entry.value.trim().isNotEmpty)
        .toList(growable: false);
    if (validItems.isEmpty) return const {};
    if (apiKeys.isEmpty) {
      throw StateError(
        'Chưa có Gemini API Key! Vui lòng vào Cài đặt để thêm Key.',
      );
    }

    final safeChunkSize = chunkSize.clamp(5, 20);
    final chunks = <List<MapEntry<int, String>>>[];
    for (var index = 0; index < validItems.length; index += safeChunkSize) {
      chunks.add(
        validItems.sublist(
          index,
          math.min(index + safeChunkSize, validItems.length),
        ),
      );
    }

    final systemPrompt = buildSystemPrompt(
      stylePreset,
      targetLanguage,
      customPrompt,
      isSrt: false,
    );
    final result = <int, String>{};
    var nextChunk = 0;
    var completed = 0;
    final workerCount = threadCount.clamp(1, 20).clamp(1, chunks.length);

    progressCallback?.call(
      0.05,
      workerCount > 1
          ? 'Đang chạy $workerCount luồng Gemini dịch ${chunks.length} nhóm câu lỗi...'
          : 'Đang chuẩn bị dịch ${validItems.length} câu lỗi...',
    );

    Future<void> worker() async {
      while (true) {
        final chunkIndex = nextChunk++;
        if (chunkIndex >= chunks.length) return;
        final chunk = chunks[chunkIndex];
        try {
          final translated = await _translateNumberedChunk(chunk, systemPrompt);
          result.addAll(translated);
          for (final entry in chunk) {
            if (result.containsKey(entry.key)) continue;
            try {
              result[entry.key] = await _translateSingleTextInternal(
                entry.value,
                systemPrompt,
              );
            } catch (_) {}
          }
        } catch (_) {
          for (final entry in chunk) {
            try {
              result[entry.key] = await _translateSingleTextInternal(
                entry.value,
                systemPrompt,
              );
            } catch (_) {}
          }
        }

        completed++;
        progressCallback?.call(
          0.05 + (completed / chunks.length) * 0.90,
          'Gemini đã dịch xong $completed/${chunks.length} nhóm '
          '(${result.length} câu thành công)...',
        );
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
    progressCallback?.call(
      1,
      'Dịch xong ${result.length}/${validItems.length} câu!',
    );
    return result;
  }

  Future<String> translateSingleText({
    required String text,
    String stylePreset = 'Zhihu',
    String customPrompt = '',
    String targetLanguage = 'Tiếng Việt',
  }) async {
    if (text.trim().isEmpty) return text;
    if (apiKeys.isEmpty) {
      throw StateError(
        'Chưa có Gemini API Key! Vui lòng vào Cài đặt để thêm Key.',
      );
    }
    final systemPrompt = buildSystemPrompt(
      stylePreset,
      targetLanguage,
      customPrompt,
      isSrt: false,
    );
    return _translateSingleTextInternal(text, systemPrompt);
  }

  Future<Map<int, String>> _translateNumberedChunk(
    List<MapEntry<int, String>> items,
    String systemPrompt, {
    int maxRetries = 3,
  }) async {
    final prompt = StringBuffer()
      ..writeln(
        'Hãy dịch chính xác các câu thoại sau sang ngôn ngữ đích theo ID.',
      )
      ..writeln('QUY TẮC BẮT BUỘC:')
      ..writeln('1. Giữ nguyên [ID] ở đầu mỗi câu.')
      ..writeln('2. Không bỏ sót câu và không để bản dịch chỉ có dấu câu.')
      ..writeln('3. Mỗi câu đúng một dòng: [ID]: <bản dịch>.')
      ..writeln()
      ..writeln('DANH SÁCH CÂU CẦN DỊCH:');
    for (final entry in items) {
      prompt.writeln('[${entry.key}]: ${entry.value.trim()}');
    }

    final linePattern = RegExp(
      r'^[ \t\-*•]*(?:\*\*)?(?:\[|#)?(\d+)(?:\]|\.|:|\))?(?:\*\*)?[:\s\-–—]+(.+)$',
    );
    Object? lastError;
    final attempts = math.max(maxRetries, apiKeys.length);
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        final response = await callGeminiRestApi(
          prompt.toString(),
          systemPrompt,
          getNextApiKey(),
        );
        final translated = <int, String>{};
        for (final line in response.split(RegExp(r'\r?\n'))) {
          final trimmed = line.trim();
          if (trimmed.startsWith('```')) continue;
          final match = linePattern.firstMatch(trimmed);
          if (match == null) continue;
          final id = int.tryParse(match.group(1) ?? '');
          var text = (match.group(2) ?? '').trim();
          if (text.startsWith('**') && text.endsWith('**')) {
            text = text.substring(2, text.length - 2).trim();
          }
          text = text.replaceFirst(RegExp("^[\"']"), '');
          text = text.replaceFirst(RegExp("[\"']\$"), '').trim();
          if (id != null && text.isNotEmpty) translated[id] = text;
        }
        if (translated.isNotEmpty) return translated;
        lastError = const FormatException(
          'Gemini không trả về danh sách [ID] hợp lệ.',
        );
      } catch (error) {
        lastError = error;
      }
    }
    throw Exception('Dịch nhóm câu thất bại: ${_readableError(lastError)}');
  }

  Future<List<String>> _translateChunkWithRetry(
    List<SubtitleItem> items,
    String systemPrompt,
    String targetLanguage, {
    int maxRetries = 3,
    bool Function()? isCancelled,
  }) async {
    final srtInput = StringBuffer();
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      srtInput.writeln(i + 1);
      srtInput.writeln(item.formatSrtTimecode());
      srtInput.writeln(item.originalText);
      srtInput.writeln();
    }

    final prompt =
        '''
[NỘI DUNG BẮT BUỘC DỊCH SANG $targetLanguage 100% CÁC KHỐI PHỤ ĐỀ DƯỚI ĐÂY. PHIÊN ÂM TẤT CẢ HỌ TÊN NHÂN VẬT SANG HÁN VIỆT KHI NGÔN NGỮ ĐÍCH LÀ TIẾNG VIỆT. TUYỆT ĐỐI KHÔNG ĐỂ SÓT CÂU]:

$srtInput
''';

    Object? lastError;
    final attempts = math.max(maxRetries, apiKeys.length);
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (isCancelled?.call() == true) {
        throw StateError('Đã huỷ tác vụ');
      }
      final key = getNextApiKey();
      try {
        final rawResponse = await callGeminiRestApi(prompt, systemPrompt, key);
        final parsedItems = SubtitleDocument.parseSrt(rawResponse).items;

        if (parsedItems.isNotEmpty) {
          final translatedResults = List<String>.filled(items.length, '');
          final usedParsedIndices = <int>{};

          // Tầng 1: khớp chính xác theo ID cục bộ (1..N).
          for (var idx = 0; idx < items.length; idx++) {
            final targetLocalId = idx + 1;
            final parsedIndex = _findUnusedParsedIndex(
              parsedItems,
              usedParsedIndices,
              (parsed) => parsed.id == targetLocalId,
            );
            if (parsedIndex != -1) {
              usedParsedIndices.add(parsedIndex);
              translatedResults[idx] = parsedItems[parsedIndex].originalText;
            }
          }

          // Tầng 2: Gemini đôi khi đổi ID nhưng vẫn giữ đúng timecode.
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

          // Tầng 4: dịch riêng câu bị rỗng hoặc bị Gemini thay bằng dấu câu.
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
          'Gemini không trả về phụ đề theo định dạng SRT.',
        );
      } catch (error) {
        lastError = error;
      }
    }

    throw Exception(
      'Dịch phụ đề thất bại sau $attempts lần thử: '
      '${_readableError(lastError)}',
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
        final response = (await callGeminiRestApi(
          prompt,
          systemPrompt,
          key,
        )).trim();
        final cleaned = response
            .replaceFirst(RegExp(r'^\[\d+\][\s:\-]+'), '')
            .trim();
        if (cleaned.isNotEmpty) return cleaned;
      } catch (error) {
        lastError = error;
      }
    }

    throw Exception('Dịch câu thất bại: ${_readableError(lastError)}');
  }

  Future<String> callGeminiRestApi(
    String userPrompt,
    String systemPrompt,
    String apiKey, {
    String? overrideModelId,
  }) async {
    final effectiveModel = overrideModelId ?? modelId;
    final url =
        'https://generativelanguage.googleapis.com/v1beta/models/'
        '$effectiveModel:generateContent?key=$apiKey';

    final body = <String, dynamic>{
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
      'generationConfig': {'temperature': 0.2, 'maxOutputTokens': 8192},
      'safetySettings': [
        {'category': 'HARM_CATEGORY_HARASSMENT', 'threshold': 'BLOCK_NONE'},
        {'category': 'HARM_CATEGORY_HATE_SPEECH', 'threshold': 'BLOCK_NONE'},
        {'category': 'HARM_CATEGORY_SEXUALLY_EXPLICIT', 'threshold': 'BLOCK_NONE'},
        {'category': 'HARM_CATEGORY_DANGEROUS_CONTENT', 'threshold': 'BLOCK_NONE'},
      ],
    };

    try {
      final response = await dio.post<Map<String, dynamic>>(
        url,
        data: body,
        options: Options(headers: {'Content-Type': 'application/json'}),
      );

      final data = response.data;
      if (data == null) {
        throw const FormatException('Phản hồi trống từ Gemini.');
      }

      final candidates = data['candidates'];
      if (candidates is! List || candidates.isEmpty) {
        final blockReason = data['promptFeedback'] is Map
            ? (data['promptFeedback'] as Map)['blockReason']
            : null;
        throw FormatException(
          blockReason == null
              ? 'Gemini không trả về candidates.'
              : 'Gemini đã chặn prompt: $blockReason.',
        );
      }

      final firstCandidate = candidates.first;
      final content = firstCandidate is Map ? firstCandidate['content'] : null;
      final parts = content is Map ? content['parts'] : null;
      final text = parts is List
          ? parts
                .whereType<Map>()
                .map((part) => part['text'])
                .whereType<String>()
                .join()
                .trim()
          : '';

      if (text.isEmpty) {
        final finishReason = firstCandidate is Map
            ? firstCandidate['finishReason']
            : null;
        throw FormatException(
          finishReason == null
              ? 'Gemini không trả về nội dung hợp lệ.'
              : 'Gemini không trả về text (finishReason: $finishReason).',
        );
      }
      return text;
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      final responseData = error.response?.data;
      final detail = responseData ?? error.message;
      throw Exception(
        'Gemini API lỗi${status == null ? '' : ' HTTP $status'}: $detail',
      );
    }
  }

  String buildSystemPrompt(
    String stylePreset,
    String targetLanguage,
    String customPrompt, {
    bool isSrt = true,
  }) {
    final styleGuide = switch (stylePreset.trim().toLowerCase()) {
      'zhihu' => 'Phong cách phim ngắn Zhihu vả mặt kịch tính, nhịp điệu dồn dập, sắc bén, gãy gọn, gay cấn.',
      'thuanviet' || 'thuần việt' => 'Phong cách văn học trau chuốt, mượt mà, giàu cảm xúc, thoát ý tự nhiên.',
      'cotrang' || 'cổ trang' => 'Phong cách cổ trang tiên hiệp huyền huyễn, bảo lưu chuẩn mực danh xưng, đại từ xưng hô và pháp bảo môn phái.',
      _ => 'Tự động nhận diện thể loại câu chuyện để dịch thoát nghĩa, tự nhiên và lôi cuốn nhất.',
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
BỐI CẢNH TÁC PHẨM:
Toàn bộ nội dung là kịch bản phim ảnh nghệ thuật hư cấu (fictional creative drama). Hãy dịch trung thực, tự nhiên và trọn vẹn toàn bộ lời thoại, bao gồm cả những phân đoạn kịch tính hay tình cảm. TUYỆT ĐỐI không kiểm duyệt làm mất nội dung và không được thay câu thoại bằng dấu chấm.
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
    if (error == null) return 'Không nhận được phản hồi hợp lệ từ Gemini.';
    return error.toString().replaceFirst(
      RegExp(r'^(Exception|FormatException):\s*'),
      '',
    );
  }
}
