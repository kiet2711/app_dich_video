import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../model/subtitle_document.dart';
import '../model/subtitle_item.dart';
import '../../domain/ai/translation_checkpoint_manager.dart';

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
    String? checkpointSessionId,
    bool enableCheckpoint = true,
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
        final pct = 0.05 + (completed / totalChunks) * 0.90;
        progressCallback?.call(
          pct,
          'Gemini đã dịch xong $completed/$totalChunks khối phụ đề...',
        );
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));

    // Dịch hoàn tất 100% -> Tự động dọn dẹp Checkpoint tạm
    if (enableCheckpoint) {
      await TranslationCheckpointManager.clearCheckpoint(sessionKey);
    }

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
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? StateError('Dịch numbered chunk thất bại');
  }

  /// Tạo payload JSON nhỏ gọn, tiết kiệm token tối đa (chỉ gửi id, duration_ms, text)
  static String buildBatchPayload({
    required List<SubtitleItem> items,
    List<SubtitleItem>? contextItems,
  }) {
    final contextList = <Map<String, String>>[];
    if (contextItems != null && contextItems.isNotEmpty) {
      for (final ctx in contextItems) {
        final trans = ctx.translatedText.trim();
        final orig = ctx.originalText.trim();
        if (trans.isNotEmpty && trans != orig) {
          contextList.add({
            'original': orig,
            'translation': trans,
          });
        }
      }
    }

    final itemList = items.map((it) => {
      'id': it.id,
      'duration_ms': it.durationMs,
      'text': it.originalText.trim(),
    }).toList();

    return jsonEncode({
      if (contextList.isNotEmpty) 'context': contextList,
      'items': itemList,
    });
  }

  /// Phân tích kết quả dịch từ JSON có cấu trúc (hoặc fallback SRT) và map theo ID
  static Map<int, String> parseBatchResponse(
    String rawResponse,
    List<SubtitleItem> expectedItems,
  ) {
    final expectedIds = expectedItems.map((e) => e.id).toSet();
    final results = <int, String>{};

    if (rawResponse.trim().isEmpty) return results;

    // 1. Thử phân tích theo JSON trước
    try {
      var text = rawResponse.trim();
      if (text.contains('```')) {
        final match = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```').firstMatch(text);
        if (match != null) {
          text = match.group(1)?.trim() ?? text;
        }
      }

      final firstBrace = text.indexOf('{');
      final lastBrace = text.lastIndexOf('}');
      if (firstBrace != -1 && lastBrace > firstBrace) {
        text = text.substring(firstBrace, lastBrace + 1);
      }

      final decoded = jsonDecode(text);
      List<dynamic>? itemsList;
      if (decoded is Map<String, dynamic>) {
        if (decoded['items'] is List) {
          itemsList = decoded['items'] as List<dynamic>;
        }
      } else if (decoded is List<dynamic>) {
        itemsList = decoded;
      }

      if (itemsList != null) {
        for (final entry in itemsList) {
          if (entry is! Map) continue;
          final rawId = entry['id'];
          final id = rawId is int ? rawId : int.tryParse(rawId?.toString() ?? '');
          if (id == null || !expectedIds.contains(id)) continue;

          final trans = entry['translation']?.toString().trim() ?? '';
          if (trans.isEmpty) continue;

          // Chống duplicate: lưu bản dịch đầu tiên không rỗng
          if (!results.containsKey(id)) {
            results[id] = trans;
          }
        }
      }
    } catch (_) {}

    if (results.isNotEmpty) return results;

    // 2. Fallback sang SRT parser nếu response là SRT (tương thích ngược với test cũ hoặc model cũ)
    try {
      final parsedItems = SubtitleDocument.parseSrt(rawResponse).items;
      if (parsedItems.isNotEmpty) {
        final usedParsedIndices = <int>{};

        // Khớp theo ID cục bộ (1..N) hoặc ID thực tế
        for (var idx = 0; idx < expectedItems.length; idx++) {
          final expectedItem = expectedItems[idx];
          final localId = idx + 1;
          for (var p = 0; p < parsedItems.length; p++) {
            if (!usedParsedIndices.contains(p) &&
                (parsedItems[p].id == expectedItem.id || parsedItems[p].id == localId)) {
              usedParsedIndices.add(p);
              final trans = parsedItems[p].originalText.trim();
              if (trans.isNotEmpty) results[expectedItem.id] = trans;
              break;
            }
          }
        }

        // Khớp theo Timecode
        for (var idx = 0; idx < expectedItems.length; idx++) {
          final expectedItem = expectedItems[idx];
          if (results.containsKey(expectedItem.id)) continue;
          final expectedTc = _normalizeTimecode(expectedItem.formatSrtTimecode());
          for (var p = 0; p < parsedItems.length; p++) {
            if (!usedParsedIndices.contains(p) &&
                _normalizeTimecode(parsedItems[p].formatSrtTimecode()) == expectedTc) {
              usedParsedIndices.add(p);
              final trans = parsedItems[p].originalText.trim();
              if (trans.isNotEmpty) results[expectedItem.id] = trans;
              break;
            }
          }
        }

        // Ghép tuần tự các câu còn lại
        var unused = 0;
        for (var idx = 0; idx < expectedItems.length; idx++) {
          final expectedItem = expectedItems[idx];
          if (results.containsKey(expectedItem.id)) continue;
          while (unused < parsedItems.length && usedParsedIndices.contains(unused)) {
            unused++;
          }
          if (unused < parsedItems.length) {
            usedParsedIndices.add(unused);
            final trans = parsedItems[unused].originalText.trim();
            if (trans.isNotEmpty) results[expectedItem.id] = trans;
            unused++;
          }
        }
      }
    } catch (_) {}

    return results;
  }

  Future<Map<int, String>> _translateChunkWithRetry(
    List<SubtitleItem> items,
    String systemPrompt,
    String targetLanguage, {
    List<SubtitleItem>? contextItems,
    int maxRetries = 3,
    bool Function()? isCancelled,
  }) async {
    if (items.isEmpty) return const {};

    final expectedIds = items.map((e) => e.id).toSet();
    final collectedResults = <int, String>{};

    var currentItemsToTranslate = List<SubtitleItem>.from(items);
    final attempts = math.max(maxRetries, apiKeys.length);

    for (var attempt = 0; attempt < attempts; attempt++) {
      if (isCancelled?.call() == true) throw StateError('Đã huỷ tác vụ');
      if (currentItemsToTranslate.isEmpty) break;

      final key = getNextApiKey();
      final payload = buildBatchPayload(
        items: currentItemsToTranslate,
        contextItems: contextItems,
      );

      try {
        final rawResponse = await callGeminiRestApi(
          payload,
          systemPrompt,
          key,
          requestJson: true,
        );

        final parsed = parseBatchResponse(rawResponse, currentItemsToTranslate);
        collectedResults.addAll(parsed);

        // Tìm danh sách ID còn thiếu sau lượt gọi này
        final missingIds = expectedIds
            .where((id) => !collectedResults.containsKey(id))
            .toSet();

        if (missingIds.isEmpty) {
          // Đã đủ 100% ID
          break;
        }

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

        // CHỈ RETRY CÁC ID BỊ THIẾU
        currentItemsToTranslate = items
            .where((it) => missingIds.contains(it.id))
            .toList();

        // Exponential backoff
        await Future.delayed(Duration(milliseconds: 150 * (attempt + 1)));
      } catch (_) {
        await Future.delayed(Duration(milliseconds: 250 * (attempt + 1)));
      }
    }

    // Tầng cứu câu: Nếu câu nào bị rỗng hoặc chỉ có dấu câu, dịch đơn lẻ để bảo đảm chất lượng
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
        // Fallback an toàn về originalText, tuyệt đối không làm mất ID hay lệch timing
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
        final response = (await callGeminiRestApi(
          prompt,
          systemPrompt,
          key,
          requestJson: false,
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
    bool requestJson = false,
  }) async {
    final effectiveModel = overrideModelId ?? modelId;
    final url =
        'https://generativelanguage.googleapis.com/v1beta/models/'
        '$effectiveModel:generateContent?key=$apiKey';

    Map<String, dynamic> buildBody({
      required bool withSchema,
      required bool withMimeType,
    }) {
      final genConfig = <String, dynamic>{
        'temperature': 0.2,
        'maxOutputTokens': 8192,
      };
      if (withMimeType) {
        genConfig['responseMimeType'] = 'application/json';
      }
      if (withSchema) {
        genConfig['responseSchema'] = {
          'type': 'OBJECT',
          'properties': {
            'items': {
              'type': 'ARRAY',
              'items': {
                'type': 'OBJECT',
                'properties': {
                  'id': {'type': 'INTEGER'},
                  'translation': {'type': 'STRING'},
                },
                'required': ['id', 'translation'],
              },
            },
          },
          'required': ['items'],
        };
      }

      return <String, dynamic>{
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
        'generationConfig': genConfig,
        'safetySettings': [
          {'category': 'HARM_CATEGORY_HARASSMENT', 'threshold': 'BLOCK_NONE'},
          {'category': 'HARM_CATEGORY_HATE_SPEECH', 'threshold': 'BLOCK_NONE'},
          {'category': 'HARM_CATEGORY_SEXUALLY_EXPLICIT', 'threshold': 'BLOCK_NONE'},
          {'category': 'HARM_CATEGORY_DANGEROUS_CONTENT', 'threshold': 'BLOCK_NONE'},
        ],
      };
    }

    Future<String> send(Map<String, dynamic> body) async {
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
    }

    try {
      return await send(buildBody(withSchema: requestJson, withMimeType: requestJson));
    } on DioException catch (error) {
      // Nếu 400 do model không hỗ trợ responseSchema, tự động thử lại chỉ với responseMimeType
      if (requestJson && error.response?.statusCode == 400) {
        try {
          return await send(buildBody(withSchema: false, withMimeType: true));
        } catch (_) {}
      }

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
$structuralRules
'''
        .trim();
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
