import 'package:dio/dio.dart';
import '../../data/repository/settings_repository.dart';
import 'offline_mlkit_translator.dart';

/// Dịch tiêu đề phim/video sang tiếng Việt thông minh:
/// 1. Ưu tiên: Gemini / Groq nếu có cấu hình API Key (dịch chuẩn điện ảnh, bắt tai).
/// 2. Dự phòng: MyMemory Translation API (100% miễn phí, không cần Key).
class TitleTranslator {
  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );

  // Bộ nhớ đệm tạm thời để tránh dịch lại nhiều lần trong cùng phiên chạy
  static final Map<String, String> _cache = {};

  static Future<String?> translateTitle(String rawTitle) async {
    final clean = rawTitle
        .replaceAll(RegExp(r'\.mp4$', caseSensitive: false), '')
        .trim();
    if (clean.isEmpty) return null;

    if (_cache.containsKey(clean)) {
      return _cache[clean];
    }

    // 1. Thử dịch bằng AI (Gemini hoặc Groq) nếu người dùng đã nhập API Key
    try {
      final settings = await SettingsRepository.getInstance();
      final hasGemini = settings.geminiApiKeys.isNotEmpty;
      final hasGroq = settings.groqApiKeys.isNotEmpty;

      if (hasGemini) {
        final key = settings.geminiApiKeys.first.trim();
        final model = settings.selectedModel.startsWith('gemini')
            ? settings.selectedModel
            : 'gemini-3.1-flash-lite';
        final url =
            'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$key';

        final response = await _dio.post(
          url,
          data: {
            'contents': [
              {
                'role': 'user',
                'parts': [
                  {
                    'text':
                        'Dịch tiêu đề phim/video sau đây sang tiếng Việt một cách cuốn hút, tự nhiên theo văn phong phim ngắn/Zhihu. Giữ các ký hiệu tập như - P1, P2 hoặc Tập 1 nếu có. CHỈ trả về đúng 1 dòng là tiêu đề tiếng Việt đã dịch, không thêm giải thích hay ngoặc kép:\n"$clean"',
                  }
                ]
              }
            ],
            'generationConfig': {
              'temperature': 0.3,
              'maxOutputTokens': 150,
            },
          },
        );

        final candidates = response.data['candidates'] as List<dynamic>?;
        if (candidates != null && candidates.isNotEmpty) {
          final text = candidates.first['content']?['parts']?[0]?['text']
              ?.toString()
              .trim();
          if (text != null && text.isNotEmpty) {
            final sanitized = _sanitize(text);
            if (sanitized.isNotEmpty) {
              _cache[clean] = sanitized;
              return sanitized;
            }
          }
        }
      } else if (hasGroq) {
        final key = settings.groqApiKeys.first.trim();
        final model = !settings.selectedModel.startsWith('gemini')
            ? settings.selectedModel
            : 'openai/gpt-oss-20b';
        final url = 'https://api.groq.com/openai/v1/chat/completions';

        final response = await _dio.post(
          url,
          options: Options(headers: {
            'Authorization': 'Bearer $key',
            'Content-Type': 'application/json',
          }),
          data: {
            'model': model,
            'messages': [
              {
                'role': 'user',
                'content':
                    'Dịch tiêu đề phim/video sau đây sang tiếng Việt một cách cuốn hút, tự nhiên theo văn phong phim ngắn/Zhihu. Giữ các ký hiệu tập như - P1, P2 hoặc Tập 1 nếu có. CHỈ trả về đúng 1 dòng là tiêu đề tiếng Việt đã dịch, không thêm giải thích hay ngoặc kép:\n"$clean"',
              }
            ],
            'temperature': 0.3,
            'max_tokens': 150,
          },
        );

        final choices = response.data['choices'] as List<dynamic>?;
        if (choices != null && choices.isNotEmpty) {
          final text = choices.first['message']?['content']?.toString().trim();
          if (text != null && text.isNotEmpty) {
            final sanitized = _sanitize(text);
            if (sanitized.isNotEmpty) {
              _cache[clean] = sanitized;
              return sanitized;
            }
          }
        }
      }
    } catch (_) {}

    // 2. Dự phòng: Dịch offline bằng Google ML Kit (không cần mạng, không cần key)
    try {
      final offlineResult =
          await OfflineMlKitTranslator.translateHongguoTitle(clean);
      if (offlineResult.isNotEmpty && offlineResult != clean) {
        final sanitized = _sanitize(offlineResult);
        if (sanitized.isNotEmpty) {
          _cache[clean] = sanitized;
          return sanitized;
        }
      }
    } catch (_) {}

    // 3. Dự phòng trực tuyến: MyMemory Translation API (miễn phí 100%, không cần API Key)
    try {
      final res = await _dio.get(
        'https://api.mymemory.translated.net/get',
        queryParameters: {
          'q': clean,
          'langpair': 'zh|vi',
        },
      );
      final trans = res.data?['responseData']?['translatedText']?.toString().trim();
      if (trans != null && trans.isNotEmpty && !trans.toLowerCase().contains('mymemory')) {
        final sanitized = _sanitize(trans);
        if (sanitized.isNotEmpty) {
          _cache[clean] = sanitized;
          return sanitized;
        }
      }
    } catch (_) {}

    return null;
  }

  /// Dịch bình luận Bilibili:
  /// - engine: 'local' (Google ML Kit on-device, hoàn toàn miễn phí, 0 token API)
  /// - engine: 'api' (AI Gemini/Groq, hiểu ngữ cảnh và tiếng lóng mạng xã hội)
  static Future<String?> translateComment(
    String rawComment, {
    String engine = 'local',
  }) async {
    final clean = rawComment.trim();
    if (clean.isEmpty) return null;

    final cacheKey = 'comment:$engine:$clean';
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey];
    }

    // 1. Chế độ Local: Luôn chạy ML Kit ngoại tuyến trên máy
    if (engine == 'local') {
      try {
        final localResult =
            await OfflineMlKitTranslator.translateHongguoTitle(clean);
        if (localResult.isNotEmpty && localResult != clean) {
          final sanitized = _sanitize(localResult);
          if (sanitized.isNotEmpty) {
            _cache[cacheKey] = sanitized;
            return sanitized;
          }
        }
      } catch (_) {}

      // Dự phòng miễn phí online (MyMemory) nếu ML Kit máy chưa có model
      try {
        final res = await _dio.get(
          'https://api.mymemory.translated.net/get',
          queryParameters: {
            'q': clean,
            'langpair': 'zh|vi',
          },
        );
        final trans =
            res.data?['responseData']?['translatedText']?.toString().trim();
        if (trans != null &&
            trans.isNotEmpty &&
            !trans.toLowerCase().contains('mymemory')) {
          final sanitized = _sanitize(trans);
          if (sanitized.isNotEmpty) {
            _cache[cacheKey] = sanitized;
            return sanitized;
          }
        }
      } catch (_) {}
      return null;
    }

    // 2. Chế độ API: Ưu tiên Gemini / Groq nếu có API Key
    try {
      final settings = await SettingsRepository.getInstance();
      final hasGemini = settings.geminiApiKeys.isNotEmpty;
      final hasGroq = settings.groqApiKeys.isNotEmpty;

      if (hasGemini) {
        final key = settings.geminiApiKeys.first.trim();
        final model = settings.selectedModel.startsWith('gemini')
            ? settings.selectedModel
            : 'gemini-3.1-flash-lite';
        final url =
            'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$key';

        final response = await _dio.post(
          url,
          data: {
            'contents': [
              {
                'role': 'user',
                'parts': [
                  {
                    'text':
                        'Dịch bình luận mạng sau đây từ tiếng Trung sang tiếng Việt một cách tự nhiên, gần gũi theo ngôn ngữ mạng Việt Nam, giữ nguyên cảm xúc hài hước/châm biếm nếu có. CHỈ trả về đúng 1 dòng là nội dung tiếng Việt đã dịch, không thêm giải thích hay ngoặc kép:\n"$clean"',
                  }
                ]
              }
            ],
            'generationConfig': {
              'temperature': 0.3,
              'maxOutputTokens': 200,
            },
          },
        );

        final candidates = response.data['candidates'] as List<dynamic>?;
        if (candidates != null && candidates.isNotEmpty) {
          final text = candidates.first['content']?['parts']?[0]?['text']
              ?.toString()
              .trim();
          if (text != null && text.isNotEmpty) {
            final sanitized = _sanitize(text);
            if (sanitized.isNotEmpty) {
              _cache[cacheKey] = sanitized;
              return sanitized;
            }
          }
        }
      } else if (hasGroq) {
        final key = settings.groqApiKeys.first.trim();
        final model = !settings.selectedModel.startsWith('gemini')
            ? settings.selectedModel
            : 'openai/gpt-oss-20b';
        final url = 'https://api.groq.com/openai/v1/chat/completions';

        final response = await _dio.post(
          url,
          options: Options(headers: {
            'Authorization': 'Bearer $key',
            'Content-Type': 'application/json',
          }),
          data: {
            'model': model,
            'messages': [
              {
                'role': 'user',
                'content':
                    'Dịch bình luận mạng sau đây từ tiếng Trung sang tiếng Việt một cách tự nhiên, gần gũi theo ngôn ngữ mạng Việt Nam, giữ nguyên cảm xúc hài hước/châm biếm nếu có. CHỈ trả về đúng 1 dòng là nội dung tiếng Việt đã dịch, không thêm giải thích hay ngoặc kép:\n"$clean"',
              }
            ],
            'temperature': 0.3,
            'max_tokens': 200,
          },
        );

        final choices = response.data['choices'] as List<dynamic>?;
        if (choices != null && choices.isNotEmpty) {
          final text = choices.first['message']?['content']?.toString().trim();
          if (text != null && text.isNotEmpty) {
            final sanitized = _sanitize(text);
            if (sanitized.isNotEmpty) {
              _cache[cacheKey] = sanitized;
              return sanitized;
            }
          }
        }
      }
    } catch (_) {}

    // Dự phòng sang Local nếu API gặp lỗi
    try {
      final localResult =
          await OfflineMlKitTranslator.translateHongguoTitle(clean);
      if (localResult.isNotEmpty && localResult != clean) {
        final sanitized = _sanitize(localResult);
        if (sanitized.isNotEmpty) {
          _cache[cacheKey] = sanitized;
          return sanitized;
        }
      }
    } catch (_) {}

    return null;
  }

  static String _sanitize(String raw) {
    var s = raw
        .replaceAll(RegExp(r'^["“”«»]+|["“”«»]+$'), '')
        .replaceAll(RegExp(r'^Tiêu đề:\s*', caseSensitive: false), '')
        .trim();
    return s.replaceAll(RegExp(r'\.mp4$', caseSensitive: false), '').trim();
  }
}
