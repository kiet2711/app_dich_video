import 'package:dio/dio.dart';

enum GroqKeyStatus {
  alive,
  dead,
  permissionDenied,
  quotaExceeded,
  networkError,
  unknown,
}

class GroqKeyCheckResult {
  final String key;
  final GroqKeyStatus status;
  final int? statusCode;
  final int latencyMs;
  final String message;
  final String testedModel;

  const GroqKeyCheckResult({
    required this.key,
    required this.status,
    this.statusCode,
    this.latencyMs = 0,
    required this.message,
    this.testedModel = '',
  });

  bool get isAlive => status == GroqKeyStatus.alive;

  String get maskedKey {
    final trimmed = key.trim();
    if (trimmed.length <= 10) return trimmed;
    final start = trimmed.substring(0, 6);
    final end = trimmed.substring(trimmed.length - 4);
    return '$start...$end';
  }

  String get statusDisplayTitle {
    switch (status) {
      case GroqKeyStatus.alive:
        return 'Hoạt động tốt (Sống)';
      case GroqKeyStatus.dead:
        return 'Key không hợp lệ (Chết / 401)';
      case GroqKeyStatus.permissionDenied:
        return 'Bị từ chối quyền (403)';
      case GroqKeyStatus.quotaExceeded:
        return 'Hết hạn ngạch / Quá tải (429)';
      case GroqKeyStatus.networkError:
        return 'Lỗi kết nối mạng';
      case GroqKeyStatus.unknown:
        return 'Lỗi không xác định';
    }
  }
}

class GroqKeyChecker {
  static Future<GroqKeyCheckResult> checkKey(
    String apiKey, {
    String modelId = 'openai/gpt-oss-120b',
    Dio? dio,
  }) async {
    final cleanKey = apiKey.trim();
    if (cleanKey.isEmpty) {
      return const GroqKeyCheckResult(
        key: '',
        status: GroqKeyStatus.dead,
        message: 'Khóa API Groq trống',
      );
    }

    final targetModel = modelId.trim().isEmpty
        ? 'openai/gpt-oss-120b'
        : modelId.trim();

    final client = dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 25),
          ),
        );

    final stopwatch = Stopwatch()..start();
    try {
      const url = 'https://api.groq.com/openai/v1/chat/completions';

      await client.post<dynamic>(
        url,
        data: {
          'model': targetModel,
          'messages': [
            {'role': 'user', 'content': 'Ping'}
          ],
          'max_tokens': 2,
          'temperature': 0.1,
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $cleanKey',
            'Content-Type': 'application/json',
          },
        ),
      );
      stopwatch.stop();

      final latency = stopwatch.elapsedMilliseconds;
      return GroqKeyCheckResult(
        key: cleanKey,
        status: GroqKeyStatus.alive,
        statusCode: 200,
        latencyMs: latency,
        testedModel: targetModel,
        message: 'Sống & Phản hồi siêu tốc (${latency}ms) - Model: $targetModel',
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
        if (rawMsg != null && rawMsg.trim().isNotEmpty) {
          errorMsg = rawMsg.trim();
        }
      }

      if (statusCode == 401) {
        return GroqKeyCheckResult(
          key: cleanKey,
          status: GroqKeyStatus.dead,
          statusCode: 401,
          latencyMs: latency,
          testedModel: targetModel,
          message: 'Key Groq không hợp lệ hoặc đã bị vô hiệu hóa ($errorMsg)',
        );
      } else if (statusCode == 429) {
        return GroqKeyCheckResult(
          key: cleanKey,
          status: GroqKeyStatus.quotaExceeded,
          statusCode: 429,
          latencyMs: latency,
          testedModel: targetModel,
          message: 'Quá giới hạn RPM/TPM của Groq (Rate limit 429): $errorMsg',
        );
      } else if (statusCode == 403) {
        return GroqKeyCheckResult(
          key: cleanKey,
          status: GroqKeyStatus.permissionDenied,
          statusCode: 403,
          latencyMs: latency,
          testedModel: targetModel,
          message: 'Bị từ chối truy cập (403): $errorMsg',
        );
      } else if (statusCode == 404) {
        return GroqKeyCheckResult(
          key: cleanKey,
          status: GroqKeyStatus.unknown,
          statusCode: 404,
          latencyMs: latency,
          testedModel: targetModel,
          message: 'Model "$targetModel" không tồn tại trên Groq hoặc chưa mở quyền',
        );
      } else if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.connectionError) {
        return GroqKeyCheckResult(
          key: cleanKey,
          status: GroqKeyStatus.networkError,
          statusCode: statusCode,
          latencyMs: latency,
          testedModel: targetModel,
          message: 'Lỗi mạng hoặc timeout kết nối tới máy chủ Groq: ${e.message ?? 'Timeout'}',
        );
      }

      return GroqKeyCheckResult(
        key: cleanKey,
        status: GroqKeyStatus.unknown,
        statusCode: statusCode,
        latencyMs: latency,
        testedModel: targetModel,
        message: 'Lỗi HTTP $statusCode: $errorMsg',
      );
    } catch (e) {
      stopwatch.stop();
      return GroqKeyCheckResult(
        key: cleanKey,
        status: GroqKeyStatus.unknown,
        latencyMs: stopwatch.elapsedMilliseconds,
        testedModel: targetModel,
        message: 'Lỗi ngoại lệ: $e',
      );
    }
  }

  static Future<List<GroqKeyCheckResult>> checkAllKeys(
    List<String> keys, {
    String modelId = 'openai/gpt-oss-120b',
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
}
