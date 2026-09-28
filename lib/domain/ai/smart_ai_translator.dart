import 'dart:async';
import 'dart:math' as math;
import 'package:dio/dio.dart';
import 'package:capsub_flutter/data/api/gemini_translator.dart';
import 'package:capsub_flutter/data/api/groq_translator.dart';
import 'package:capsub_flutter/data/model/subtitle_document.dart';
import 'package:capsub_flutter/data/model/subtitle_item.dart';
import 'package:capsub_flutter/domain/ai/ai_model_registry.dart';
import 'package:capsub_flutter/domain/ai/translation_checkpoint_manager.dart';

/// Mục tiêu điều phối gồm: Nhà cung cấp, API Key và Model ID
class TranslationTarget {
  final AiProvider provider;
  final String apiKey;
  final String modelId;

  const TranslationTarget({
    required this.provider,
    required this.apiKey,
    required this.modelId,
  });

  String get id => '${provider.name}:$apiKey:$modelId';

  @override
  String toString() => '[$provider | $modelId | ${apiKey.length > 8 ? "${apiKey.substring(0, 4)}...${apiKey.substring(apiKey.length - 4)}" : apiKey}]';
}

/// Bộ điều phối xoay API & Model đa tầng thông minh (Smart AI Translator)
///
/// Các tầng bảo vệ & tối ưu:
/// - Tầng 1: Đổi model fallback trên CÙNG 1 API Key khi gặp lỗi 429 Quota
///   (Ví dụ: Gemini 3.1 Flash-Lite ➔ Gemini 3.5 Flash-Lite).
/// - Tầng 2: Xoay vòng giữa các API Key trong cùng Provider khi tất cả model trên Key đó cạn Quota.
/// - Tầng 3: Cross-Provider Failover (Gemini ➔ Groq hoặc ngược lại) khi cạn toàn bộ Key.
/// - Tầng 4: Cân bằng tải song song đa model (Dual-model load balancing) khi chạy nhiều luồng.
class SmartAiTranslator {
  final List<String> geminiKeys;
  final List<String> groqKeys;
  final String initialModelId;
  final bool enableSmartModelFallback;
  final bool enableCrossProviderFallback;
  final bool enableDualModelBalancing;
  final Dio _dio;

  late final GeminiTranslator _geminiTranslator;
  late final GroqTranslator _groqTranslator;

  // Quản lý trạng thái Quota và Key Dead
  final Set<String> _deadKeys = {};
  final Map<String, DateTime> _cooldowns = {};

  SmartAiTranslator({
    List<String>? geminiKeys,
    List<String>? groqKeys,
    String? initialModelId,
    this.enableSmartModelFallback = true,
    this.enableCrossProviderFallback = true,
    this.enableDualModelBalancing = true,
    Dio? dio,
  })  : geminiKeys = (geminiKeys ?? const []).map((k) => k.trim()).where((k) => k.isNotEmpty).toList(),
        groqKeys = (groqKeys ?? const []).map((k) => k.trim()).where((k) => k.isNotEmpty).toList(),
        initialModelId = (initialModelId ?? 'gemini-3.1-flash-lite').trim(),
        _dio = dio ?? Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 30),
            receiveTimeout: const Duration(seconds: 90),
            sendTimeout: const Duration(seconds: 30),
          ),
        ) {
    _geminiTranslator = GeminiTranslator(
      apiKeys: this.geminiKeys.isNotEmpty ? this.geminiKeys : ['dummy'],
      modelId: this.initialModelId.startsWith('gemini') ? this.initialModelId : 'gemini-3.1-flash-lite',
      dio: _dio,
    );
    _groqTranslator = GroqTranslator(
      apiKeys: this.groqKeys.isNotEmpty ? this.groqKeys : ['dummy'],
      modelId: !this.initialModelId.startsWith('gemini') ? this.initialModelId : 'openai/gpt-oss-120b',
      dio: _dio,
    );
  }

  /// Danh sách các model fallback theo thứ tự ưu tiên cho từng Provider
  List<String> getCandidateModels(AiProvider provider, String requestedModel) {
    if (provider == AiProvider.gemini) {
      final defaultList = ['gemini-3.1-flash-lite', 'gemini-3.5-flash-lite'];
      if (!defaultList.contains(requestedModel)) {
        return [requestedModel, ...defaultList];
      }
      return [requestedModel, ...defaultList.where((m) => m != requestedModel)];
    } else if (provider == AiProvider.groq) {
      final defaultList = [
        'openai/gpt-oss-120b',
        'openai/gpt-oss-20b',
        'qwen/qwen3.8-27b',
      ];
      if (!defaultList.contains(requestedModel)) {
        return [requestedModel, ...defaultList];
      }
      return [requestedModel, ...defaultList.where((m) => m != requestedModel)];
    }
    return [requestedModel];
  }

  /// Kiểm tra xem một Target có sẵn sàng sử dụng (không Dead và không trong Cooldown)
  bool isTargetAvailable(TranslationTarget target) {
    if (_deadKeys.contains(target.apiKey)) return false;
    final exp = _cooldowns[target.id];
    if (exp != null) {
      if (DateTime.now().isBefore(exp)) {
        return false;
      } else {
        _cooldowns.remove(target.id);
      }
    }
    return true;
  }

  void markCooldown(TranslationTarget target, {Duration duration = const Duration(seconds: 60)}) {
    _cooldowns[target.id] = DateTime.now().add(duration);
  }

  void markDeadKey(String key) {
    _deadKeys.add(key);
  }

  /// Phân biệt lỗi Rate Limit (429 / Quota)
  static bool isRateLimitError(Object error) {
    if (error is DioException) {
      if (error.response?.statusCode == 429) return true;
    }
    final msg = error.toString().toLowerCase();
    return msg.contains('429') ||
        msg.contains('resource_exhausted') ||
        msg.contains('rate_limit') ||
        msg.contains('quota');
  }

  /// Phân biệt lỗi Key Chết vĩnh viễn (400 Invalid Key, 401 Unauthorized, 403 Forbidden)
  static bool isDeadKeyError(Object error) {
    if (error is DioException) {
      final code = error.response?.statusCode;
      if (code == 401 || code == 403) return true;
      if (code == 400) {
        final data = error.response?.data?.toString().toLowerCase() ?? '';
        if (data.contains('api_key_invalid') || data.contains('invalid_argument')) {
          return true;
        }
      }
      return false;
    }
    final msg = error.toString().toLowerCase();
    return msg.contains('api_key_invalid') ||
        msg.contains('invalid_api_key') ||
        msg.contains('permission_denied') ||
        msg.contains('http 401') ||
        msg.contains('http 403');
  }

  /// Phân biệt lỗi máy chủ tạm thời (500, 502, 503, 504 - Service Unavailable / Server Overload)
  static bool isServerUnavailableError(Object error) {
    if (error is DioException) {
      final code = error.response?.statusCode;
      if (code == 500 || code == 502 || code == 503 || code == 504) return true;
    }
    final msg = error.toString().toLowerCase();
    return msg.contains('503') ||
        msg.contains('service unavailable') ||
        msg.contains('bad gateway') ||
        msg.contains('gateway timeout') ||
        msg.contains('server error');
  }

  /// Dịch phụ đề toàn diện cho [SubtitleDocument] với cơ chế xoay đa tầng thông minh
  Future<SubtitleDocument> translateSubtitles({
    required SubtitleDocument document,
    String stylePreset = 'Zhihu',
    String customPrompt = '',
    String targetLanguage = 'vi-VN',
    int chunkSize = 45,
    int threadCount = 3,
    String? checkpointSessionId,
    bool enableCheckpoint = true,
    bool Function()? isCancelled,
    void Function(double progress, String message)? progressCallback,
  }) async {
    if (document.isEmpty) return document;

    if (geminiKeys.isEmpty && groqKeys.isEmpty) {
      throw StateError(
        'Chưa có API Key nào được cấu hình! Vui lòng vào Cài đặt để thêm Gemini hoặc Groq Key.',
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
          // Nếu tất cả các câu đã được dịch hoàn tất từ checkpoint
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

    final workerCount = threadCount.clamp(1, 20).clamp(1, totalChunks);
    progressCallback?.call(
      0.05,
      'Khởi chạy $workerCount luồng AI thông minh dịch $totalChunks khối phụ đề...',
    );

    var completed = 0;
    var nextChunk = 0;

    Future<void> worker(int workerId) async {
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

          final translatedMap = await _translateChunkWithSmartRotation(
            items: pendingInChunk,
            contextItems: contextItems,
            stylePreset: stylePreset,
            customPrompt: customPrompt,
            targetLanguage: targetLanguage,
            workerId: workerId,
            isCancelled: isCancelled,
            progressCallback: progressCallback,
          );

          // GHÉP THEO ID ĐỘC LẬP - KHÔNG DÙNG POSITION
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
          'Đã dịch xong $completed/$totalChunks khối phụ đề...',
        );
      }
    }

    await Future.wait(List.generate(workerCount, (id) => worker(id)));

    // Dịch hoàn tất 100% -> Tự động dọn dẹp Checkpoint tạm
    if (enableCheckpoint) {
      await TranslationCheckpointManager.clearCheckpoint(sessionKey);
    }

    progressCallback?.call(1.0, 'Dịch thuật hoàn tất!');
    return document;
  }

  /// Dịch danh sách các câu đơn lẻ có ID (dành cho bảng sửa lỗi TTS hoặc các câu lỗi)
  Future<Map<int, String>> translateItems({
    required Map<int, String> items,
    String stylePreset = 'Zhihu',
    String customPrompt = '',
    String targetLanguage = 'vi-VN',
    int chunkSize = 15,
    int threadCount = 2,
    bool Function()? isCancelled,
    void Function(double progress, String message)? progressCallback,
  }) async {
    if (items.isEmpty) return const {};

    final subItems = items.entries
        .map((e) => SubtitleItem(
              id: e.key,
              startMs: 0,
              endMs: 1000,
              originalText: e.value,
            ))
        .toList();
    final doc = SubtitleDocument(subItems);

    final translatedDoc = await translateSubtitles(
      document: doc,
      stylePreset: stylePreset,
      customPrompt: customPrompt,
      targetLanguage: targetLanguage,
      chunkSize: chunkSize,
      threadCount: threadCount,
      isCancelled: isCancelled,
      progressCallback: progressCallback,
    );

    final result = <int, String>{};
    for (final item in translatedDoc.items) {
      result[item.id] = item.translatedText;
    }
    return result;
  }

  /// Dịch một câu đơn lẻ với cơ chế xoay thông minh
  Future<String> translateSingleText({
    required String text,
    String stylePreset = 'Zhihu',
    String customPrompt = '',
    String targetLanguage = 'vi-VN',
    bool Function()? isCancelled,
  }) async {
    if (text.trim().isEmpty) return text;
    final interjection = resolveInterjection(text);
    if (interjection != null) return interjection;

    final doc = SubtitleDocument([
      SubtitleItem(id: 1, startMs: 0, endMs: 1000, originalText: text),
    ]);

    final translatedDoc = await translateSubtitles(
      document: doc,
      stylePreset: stylePreset,
      customPrompt: customPrompt,
      targetLanguage: targetLanguage,
      chunkSize: 1,
      threadCount: 1,
      isCancelled: isCancelled,
    );

    final translated = translatedDoc.items.first.translatedText.trim();
    if (translated.isNotEmpty && containsLetterOrNumber(translated)) {
      return translated;
    }
    return text;
  }

  /// Thực hiện dịch 1 chunk có xoay model trên cùng key, xoay key, và nhảy cross-provider
  Future<Map<int, String>> _translateChunkWithSmartRotation({
    required List<SubtitleItem> items,
    List<SubtitleItem>? contextItems,
    required String stylePreset,
    required String customPrompt,
    required String targetLanguage,
    required int workerId,
    bool Function()? isCancelled,
    void Function(double progress, String message)? progressCallback,
  }) async {
    final startProvider = AiModelRegistry.detectProvider(initialModelId);
    final providerOrder = <AiProvider>[
      if (startProvider == AiProvider.gemini) ...[AiProvider.gemini, AiProvider.groq]
      else ...[AiProvider.groq, AiProvider.gemini],
    ];

    final resolvedMap = <int, String>{};
    var pendingItems = List<SubtitleItem>.from(items);
    Object? lastError;

    // Vòng lặp tối đa 3 chu kỳ tổng để đợi hồi phục cooldown nếu tất cả tạm thời bị 429 hoặc 503
    for (var cycle = 0; cycle < 3; cycle++) {
      for (final provider in providerOrder) {
        if (isCancelled?.call() == true) throw StateError('Đã huỷ tác vụ');

        final keys = provider == AiProvider.gemini ? geminiKeys : groqKeys;
        if (keys.isEmpty) continue;

        final candidateModels = getCandidateModels(provider, initialModelId);

        // Duyệt qua các Key (bắt đầu theo workerId để cân bằng tải)
        final keyCount = keys.length;
        for (var kIdx = 0; kIdx < keyCount; kIdx++) {
          final currentKey = keys[(workerId + kIdx) % keyCount];
          if (_deadKeys.contains(currentKey)) continue;

          // Duyệt qua các Model trên cùng Key đó
          // Nếu enableDualModelBalancing: luồng chẵn ưu tiên model 0, luồng lẻ ưu tiên model 1
          final orderedModels = <String>[];
          if (enableDualModelBalancing && candidateModels.length >= 2) {
            final primaryIdx = workerId % candidateModels.length;
            orderedModels.add(candidateModels[primaryIdx]);
            if (enableSmartModelFallback) {
              orderedModels.addAll(candidateModels.where((m) => m != candidateModels[primaryIdx]));
            }
          } else {
            orderedModels.add(candidateModels.first);
            if (enableSmartModelFallback) {
              orderedModels.addAll(candidateModels.skip(1));
            }
          }

          for (final model in orderedModels) {
            if (isCancelled?.call() == true) throw StateError('Đã huỷ tác vụ');

            final target = TranslationTarget(
              provider: provider,
              apiKey: currentKey,
              modelId: model,
            );

            if (!isTargetAvailable(target)) continue;

            try {
              // CHỈ GỬI CÁC CÂU CHƯA ĐƯỢC DỊCH THÀNH CÔNG (MISSING IDS RETRY)
              final rawResponse = await _executeRawApiCall(
                target: target,
                items: pendingItems,
                contextItems: contextItems,
                stylePreset: stylePreset,
                customPrompt: customPrompt,
                targetLanguage: targetLanguage,
              );

              final parsedResults = _parseAndAlignResponse(
                rawResponse: rawResponse,
                items: pendingItems,
              );

              for (final entry in parsedResults.entries) {
                if (entry.value.trim().isNotEmpty) {
                  resolvedMap[entry.key] = entry.value.trim();
                }
              }

              // Cập nhật danh sách các câu còn thiếu ID
              pendingItems = items.where((it) {
                final trans = resolvedMap[it.id]?.trim() ?? '';
                final orig = it.originalText.trim();
                final origHasText = containsLetterOrNumber(orig);
                final transHasText = containsLetterOrNumber(trans);
                return trans.isEmpty || (origHasText && !transHasText);
              }).toList();

              // Nếu tất cả các ID đã được phân giải xong -> Hoàn thành batch!
              if (pendingItems.isEmpty) {
                return resolvedMap;
              }
            } catch (err) {
              lastError = err;

              if (isDeadKeyError(err)) {
                markDeadKey(currentKey);
                progressCallback?.call(
                  0.05,
                  'Phát hiện Key $provider không hợp lệ ➔ Đã tự động loại bỏ.',
                );
                // Bỏ qua các model khác trên cùng key này, nhảy sang key khác
                break;
              } else if (isServerUnavailableError(err)) {
                // 500, 502, 503, 504 - LỖI MÁY CHỦ TẠM THỜI: KHÔNG ĐƯỢC COI LÀ DEAD KEY!
                markCooldown(target, duration: const Duration(seconds: 20));
                progressCallback?.call(
                  0.05,
                  'Server $provider (${target.modelId}) quá tải (503/5xx) ➔ Cooldown 20s và chuyển sang slot khác...',
                );
                // Chuyển sang model/key tiếp theo
                continue;
              } else if (isRateLimitError(err)) {
                markCooldown(target);
                // Tầng 1: Nếu còn model khác trên cùng key, tiếp tục vòng lặp model
                if (enableSmartModelFallback && orderedModels.indexOf(model) < orderedModels.length - 1) {
                  final nextModel = orderedModels[orderedModels.indexOf(model) + 1];
                  progressCallback?.call(
                    0.05,
                    'Model $model đầy Quota ➔ Đổi sang $nextModel trên cùng Key...',
                  );
                  continue;
                }
                // Nếu cả model fallback đều dính 429 trên key này, chuyển sang key khác
                break;
              } else {
                // Lỗi mạng hoặc lỗi định dạng, thử lại hoặc chuyển slot
                continue;
              }
            }
          }
        }
      }

      // Nếu tất cả các Key & Provider đều trong Cooldown, tạm nghỉ một khoảng ngắn rồi thử lại
      if (cycle < 2 && pendingItems.isNotEmpty) {
        progressCallback?.call(
          0.05,
          'Các API Key đang đợi hồi hạn mức (cooldown 15s) ➔ Đang tự động thử lại...',
        );
        for (var s = 0; s < 15; s++) {
          if (isCancelled?.call() == true) throw StateError('Đã huỷ tác vụ');
          await Future.delayed(const Duration(seconds: 1));
        }
      }
    }

    // Nếu sau tất cả các chu kỳ vẫn còn item thiếu: giải cứu an toàn bằng interjection hoặc câu gốc
    for (final item in items) {
      if (!resolvedMap.containsKey(item.id) || resolvedMap[item.id]!.trim().isEmpty) {
        final interjection = resolveInterjection(item.originalText);
        resolvedMap[item.id] = interjection ?? item.originalText;
      }
    }

    if (resolvedMap.isNotEmpty) {
      return resolvedMap;
    }

    throw Exception(
      'Dịch khối phụ đề thất bại sau khi đã thử tất cả Model & API Key: $lastError',
    );
  }

  /// Thực thi gọi trực tiếp REST API tương ứng với Target
  Future<String> _executeRawApiCall({
    required TranslationTarget target,
    required List<SubtitleItem> items,
    List<SubtitleItem>? contextItems,
    required String stylePreset,
    required String customPrompt,
    required String targetLanguage,
  }) async {
    final payloadJson = GeminiTranslator.buildBatchPayload(
      items: items,
      contextItems: contextItems,
    );

    if (target.provider == AiProvider.gemini) {
      final systemPrompt = _geminiTranslator.buildSystemPrompt(
        stylePreset,
        targetLanguage,
        customPrompt,
      );
      final userPrompt = '''
[NỘI DUNG BẮT BUỘC DỊCH SANG $targetLanguage 100% CÁC KHỐI PHỤ ĐỀ DƯỚI ĐÂY. PHIÊN ÂM TẤT CẢ HỌ TÊN NHÂN VẬT SANG HÁN VIỆT KHI NGÔN NGỮ ĐÍCH LÀ TIẾNG VIỆT. TUYỆT ĐỐI KHÔNG ĐỂ SÓT CÂU]:

$payloadJson
''';
      return await _geminiTranslator.callGeminiRestApi(
        userPrompt,
        systemPrompt,
        target.apiKey,
        overrideModelId: target.modelId,
        requestJson: true,
      );
    } else {
      final systemPrompt = _groqTranslator.buildSystemPrompt(
        stylePreset,
        targetLanguage,
        customPrompt,
      );
      final userPrompt = '''
Translate the following subtitles into $targetLanguage.
Return ONLY valid JSON according to instructions.
INPUT:
$payloadJson
''';
      final raw = await _groqTranslator.callGroqRestApi(
        userPrompt,
        systemPrompt,
        target.apiKey,
        overrideModelId: target.modelId,
        requestJson: true,
      );
      // Làm sạch thẻ <think>...</think> nếu có từ Qwen/DeepSeek/GPT-OSS
      return raw.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
    }
  }

  /// Phân tích kết quả dịch JSON hoặc fallback SRT và căn chỉnh hoàn thiện
  Map<int, String> _parseAndAlignResponse({
    required String rawResponse,
    required List<SubtitleItem> items,
  }) {
    final results = GeminiTranslator.parseBatchResponse(rawResponse, items);

    // Xử lý các câu bị rỗng hoặc chỉ toàn dấu câu trơ trọi (. ? , ...)
    for (final item in items) {
      final original = item.originalText.trim();
      final translated = (results[item.id] ?? '').trim();
      final originalHasContent = containsLetterOrNumber(original);
      final translationHasContent = containsLetterOrNumber(translated);

      if (translated.isEmpty || (originalHasContent && !translationHasContent)) {
        final interjection = resolveInterjection(original);
        if (interjection != null) {
          results[item.id] = interjection;
        } else if (translated.isEmpty) {
          // Chưa có bản dịch, giữ rỗng để retry missing IDs
        } else {
          // Lấy câu gốc từ SRT thay vì để lại dấu câu trơ trọi!
          results[item.id] = original;
        }
      }
    }

    return results;
  }

  static final Map<String, String> _interjectionMap = {
    '啊': 'A!',
    '啊？': 'Hả?',
    '啊!': 'A!',
    '啊...': 'A...',
    '呃': 'Ừm...',
    '呃...': 'Ơ...',
    '哦': 'Ồ!',
    '哦！': 'Ồ!',
    '哦...': 'Ra vậy...',
    '嗯': 'Ừm',
    '嗯！': 'Ừm!',
    '嗯嗯': 'Vâng vâng',
    '哎': 'Ai chà',
    '哎呀': 'Trời ơi',
    '哎哟': 'Ối chao',
    '咦': 'Ủa?',
    '咦？': 'Ủa sao?',
    '哈': 'Haha',
    '哈哈': 'Haha',
    '哈哈哈': 'Hahaha',
    '嘿': 'Này',
    '嘿嘿': 'Hehe',
    '哇': 'Woa!',
    '哇塞': 'Woa trời!',
  };

  static String? resolveInterjection(String text) {
    final clean = text.trim();
    return _interjectionMap[clean];
  }

  static bool containsLetterOrNumber(String value) =>
      RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(value);
}
