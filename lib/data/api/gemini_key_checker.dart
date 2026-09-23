import 'package:dio/dio.dart';

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
  final List<String> availableModels;

  const GeminiKeyCheckResult({
    required this.key,
    required this.status,
    this.statusCode,
    this.latencyMs = 0,
    required this.message,
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

    final client = dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 12),
            receiveTimeout: const Duration(seconds: 15),
          ),
        );

    final stopwatch = Stopwatch()..start();
    try {
      final response = await client.get<Map<String, dynamic>>(
        'https://generativelanguage.googleapis.com/v1beta/models',
        queryParameters: {'key': cleanKey},
      );
      stopwatch.stop();

      final modelsList = <String>[];
      final data = response.data;
      if (data != null && data['models'] is List) {
        for (final m in data['models'] as List) {
          if (m is Map && m['name'] != null) {
            final name = m['name'].toString().replaceFirst('models/', '');
            modelsList.add(name);
          }
        }
      }

      final latency = stopwatch.elapsedMilliseconds;
      return GeminiKeyCheckResult(
        key: cleanKey,
        status: GeminiKeyStatus.alive,
        statusCode: 200,
        latencyMs: latency,
        message: 'Phản hồi thành công (${latency}ms)',
        availableModels: modelsList,
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

      if (statusCode == 400) {
        return GeminiKeyCheckResult(
          key: cleanKey,
          status: GeminiKeyStatus.dead,
          statusCode: 400,
          latencyMs: latency,
          message: 'Key không tồn tại hoặc đã bị Google thu hồi ($errorMsg)',
        );
      } else if (statusCode == 403) {
        return GeminiKeyCheckResult(
          key: cleanKey,
          status: GeminiKeyStatus.permissionDenied,
          statusCode: 403,
          latencyMs: latency,
          message: 'Bị từ chối truy cập (Kiểm tra API đã bật chưa): $errorMsg',
        );
      } else if (statusCode == 429) {
        return GeminiKeyCheckResult(
          key: cleanKey,
          status: GeminiKeyStatus.quotaExceeded,
          statusCode: 429,
          latencyMs: latency,
          message: 'Hết hạn ngạch hoặc bị giới hạn tần suất (Rate limit 429): $errorMsg',
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
          message: 'Lỗi mạng hoặc không thể kết nối tới máy chủ Google: ${e.message ?? 'Timeout'}',
        );
      }

      return GeminiKeyCheckResult(
        key: cleanKey,
        status: GeminiKeyStatus.unknown,
        statusCode: statusCode,
        latencyMs: latency,
        message: 'Lỗi HTTP $statusCode: $errorMsg',
      );
    } catch (e) {
      stopwatch.stop();
      return GeminiKeyCheckResult(
        key: cleanKey,
        status: GeminiKeyStatus.unknown,
        latencyMs: stopwatch.elapsedMilliseconds,
        message: 'Lỗi ngoại lệ: $e',
      );
    }
  }

  static Future<List<GeminiKeyCheckResult>> checkAllKeys(
    List<String> keys, {
    Dio? dio,
  }) async {
    final cleanKeys = keys
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .toList();

    if (cleanKeys.isEmpty) return const [];

    final futures = cleanKeys.map((k) => checkKey(k, dio: dio));
    return Future.wait(futures);
  }
}
