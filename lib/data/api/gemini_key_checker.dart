import 'package:dio/dio.dart';

import '../../domain/ai/ai_model_registry.dart';

enum GeminiKeyStatus {
  alive,
  dead,
  permissionDenied,
  quotaExceeded,
  networkError,
  unknown,
}

class GeminiKeyCheckResult {
  final String key;
  final GeminiKeyStatus status;
  final int? statusCode;
  final int latencyMs;
  final String message;
  final String testedModel;
  final List<String> availableModels;

  const GeminiKeyCheckResult({
    required this.key,
    required this.status,
    this.statusCode,
    this.latencyMs = 0,
    required this.message,
    this.testedModel = '',
    this.availableModels = const [],
  });

  bool get isAlive => status == GeminiKeyStatus.alive;

  String get maskedKey {
    final trimmed = key.trim();
    if (trimmed.length <= 10) return trimmed;
    final start = trimmed.substring(0, 6);
    final end = trimmed.substring(trimmed.length - 4);
    return '$start...$end';
  }

  String get statusDisplayTitle {
    switch (status) {
      case GeminiKeyStatus.alive:
        return 'Hoạt động tốt (Sống)';
      case GeminiKeyStatus.dead:
        return 'Key không hợp lệ (Chết)';
      case GeminiKeyStatus.permissionDenied:
        return 'Bị từ chối quyền (403)';
      case GeminiKeyStatus.quotaExceeded:
        return 'Hết hạn ngạch / Quá tải (429)';
      case GeminiKeyStatus.networkError:
        return 'Lỗi kết nối mạng';
      case GeminiKeyStatus.unknown:
        return 'Lỗi không xác định';
    }
  }
}

class GeminiKeyChecker {
  static Future<GeminiKeyCheckResult> checkKey(
    String apiKey, {
    String modelId = 'gemini-3.5-flash-lite',
    Dio? dio,
  }) async {
    final cleanKey = apiKey.trim();
    if (cleanKey.isEmpty) {
      return const GeminiKeyCheckResult(
        key: '',
        status: GeminiKeyStatus.dead,
        message: 'Khóa API trống',
      );
    }

    final normalizedModel = AiModelRegistry.normalizeModelId(modelId);
    final targetModel = normalizedModel.isEmpty
        ? 'gemini-3.5-flash-lite'
        : normalizedModel;

    final client = dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 25),
          ),
        );

    final stopwatch = Stopwatch()..start();
    try {
      // Gửi request inference thực tế (ping 1 token) vào chính model được chọn để phát hiện lỗi 429
      final url =
          'https://generativelanguage.googleapis.com/v1beta/models/$targetModel:generateContent';

      await client.post<dynamic>(
        url,
        queryParameters: {'key': cleanKey},
        data: {
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': 'Ping'}
              ]
            }
          ],
          'generationConfig': {
            'maxOutputTokens': 2,
            'temperature': 0.1,
          }
        },
        options: Options(headers: {'Content-Type': 'application/json'}),
      );
      stopwatch.stop();

      final latency = stopwatch.elapsedMilliseconds;
      return GeminiKeyCheckResult(
        key: cleanKey,
        status: GeminiKeyStatus.alive,
        statusCode: 200,
        latencyMs: latency,
        testedModel: targetModel,
        message: 'Sống & Sẵn sàng dịch (${latency}ms) - Model: $targetModel',
      );
    } on DioException catch (e) {
      stopwatch.stop();
      final latency = stopwatch.elapsedMilliseconds;
      final statusCode = e.response?.statusCode;
      final data = e.response?.data;

      String errorMsg = e.message ?? 'Lỗi không xác định';
      if (data is Map && data['error'] is Map) {
        final err = data['error'] as Map;
        final rawMsg = err['message']?.toString();
        final statusStr = err['status']?.toString();
        if (rawMsg != null && rawMsg.trim().isNotEmpty) {
          errorMsg = rawMsg.trim();
        } else if (statusStr != null && statusStr.trim().isNotEmpty) {
          errorMsg = statusStr.trim();
        }
      }

      if (statusCode == 429) {
        return GeminiKeyCheckResult(
          key: cleanKey,
          status: GeminiKeyStatus.quotaExceeded,
          statusCode: 429,
          latencyMs: latency,
          testedModel: targetModel,
          message: 'Hết hạn ngạch hoặc bị giới hạn tốc độ (Rate limit 429): $errorMsg',
        );
      } else if (statusCode == 400) {
        return GeminiKeyCheckResult(
          key: cleanKey,
          status: GeminiKeyStatus.dead,
          statusCode: 400,
          latencyMs: latency,
          testedModel: targetModel,
          message: 'Key không tồn tại hoặc đã bị Google thu hồi ($errorMsg)',
        );
      } else if (statusCode == 403) {
        return GeminiKeyCheckResult(
          key: cleanKey,
          status: GeminiKeyStatus.permissionDenied,
          statusCode: 403,
          latencyMs: latency,
          testedModel: targetModel,
          message: 'Bị từ chối truy cập (Kiểm tra API đã bật chưa): $errorMsg',
        );
      } else if (statusCode == 404) {
        return GeminiKeyCheckResult(
          key: cleanKey,
          status: GeminiKeyStatus.unknown,
          statusCode: 404,
          latencyMs: latency,
          testedModel: targetModel,
          message: 'Model "$targetModel" không tồn tại hoặc tài khoản không có quyền truy cập',
        );
      } else if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.connectionError) {
        return GeminiKeyCheckResult(
          key: cleanKey,
          status: GeminiKeyStatus.networkError,
          statusCode: statusCode,
          latencyMs: latency,
          testedModel: targetModel,
          message: 'Lỗi mạng hoặc timeout kết nối tới máy chủ Google: ${e.message ?? 'Timeout'}',
        );
      }

      return GeminiKeyCheckResult(
        key: cleanKey,
        status: GeminiKeyStatus.unknown,
        statusCode: statusCode,
        latencyMs: latency,
        testedModel: targetModel,
        message: 'Lỗi HTTP $statusCode: $errorMsg',
      );
    } catch (e) {
      stopwatch.stop();
      return GeminiKeyCheckResult(
        key: cleanKey,
        status: GeminiKeyStatus.unknown,
        latencyMs: stopwatch.elapsedMilliseconds,
        testedModel: targetModel,
        message: 'Lỗi ngoại lệ: $e',
      );
    }
  }

  static Future<List<GeminiKeyCheckResult>> checkAllKeys(
    List<String> keys, {
    String modelId = 'gemini-3.5-flash-lite',
    Dio? dio,
  }) async {
    final cleanKeys = keys
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .toList();

    if (cleanKeys.isEmpty) return const [];

    final futures = cleanKeys.map(
      (k) => checkKey(k, modelId: modelId, dio: dio),
    );
    return Future.wait(futures);
  }

  /// Quét danh sách model hỗ trợ `generateContent` khả dụng trên API Key (Gemini & Gemma).
  static Future<List<String>> fetchGenerateContentModels(
    String apiKey, {
    Dio? dio,
  }) async {
    final cleanKey = apiKey.trim();
    if (cleanKey.isEmpty) {
      throw ArgumentError('API Key trống');
    }

    final client =
        dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 12),
            receiveTimeout: const Duration(seconds: 20),
          ),
        );

    final response = await client.get<Map<String, dynamic>>(
      'https://generativelanguage.googleapis.com/v1beta/models',
      queryParameters: {'pageSize': 200},
      options: Options(headers: {'x-goog-api-key': cleanKey}),
    );

    final models = response.data?['models'];
    if (models is! List) return const [];

    final result = <String>[];
    for (final raw in models) {
      if (raw is! Map) continue;
      final methods = raw['supportedGenerationMethods'];
      final supportsGen =
          methods is List &&
          methods.any((m) => m.toString().toLowerCase() == 'generatecontent');
      if (!supportsGen) continue;

      final id = AiModelRegistry.normalizeModelId(raw['name']?.toString() ?? '');
      if (id.isEmpty) continue;
      final lower = id.toLowerCase();
      if (lower.contains('embedding') ||
          lower.contains('imagen') ||
          lower.contains('veo') ||
          lower.contains('aqa') ||
          lower.contains('tts')) {
        continue;
      }
      if (lower.startsWith('gemini') || lower.startsWith('gemma')) {
        result.add(id);
      }
    }
    return result;
  }
}
