import 'package:flutter/foundation.dart';

enum AiProvider {
  capcut,
  gemini,
  groq,
  none,
}

class AiModelInfo {
  final String id;
  final String displayName;
  final String shortDescription;
  final AiProvider provider;
  final bool isRecommended;
  final bool isCustom;

  const AiModelInfo({
    required this.id,
    required this.displayName,
    required this.shortDescription,
    required this.provider,
    this.isRecommended = false,
    this.isCustom = false,
  });
}

class AiModelRegistry {
  static final ValueNotifier<int> customModelsRevision = ValueNotifier<int>(0);
  static List<String> _customGeminiModelIds = const [];
  static List<String> _customGroqModelIds = const [];

  static String normalizeModelId(String raw) {
    var clean = raw.trim();
    if (clean.toLowerCase().startsWith('models/')) {
      clean = clean.substring(7).trim();
    }
    return clean;
  }

  static void updateCustomModels({
    List<String>? geminiModels,
    List<String>? groqModels,
  }) {
    var changed = false;
    if (geminiModels != null) {
      final normalized = geminiModels
          .map(normalizeModelId)
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList(growable: false);
      if (!listEquals(_customGeminiModelIds, normalized)) {
        _customGeminiModelIds = normalized;
        changed = true;
      }
    }
    if (groqModels != null) {
      final normalized = groqModels
          .map(normalizeModelId)
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList(growable: false);
      if (!listEquals(_customGroqModelIds, normalized)) {
        _customGroqModelIds = normalized;
        changed = true;
      }
    }
    if (changed) {
      customModelsRevision.value++;
    }
  }

  static List<String> get customGeminiModelIds => _customGeminiModelIds;
  static List<String> get customGroqModelIds => _customGroqModelIds;

  static const List<AiModelInfo> groqModels = [
    AiModelInfo(
      id: 'openai/gpt-oss-120b',
      displayName: 'GPT-OSS 120B (OpenAI)',
      shortDescription: 'Chất lượng cao, giữ chuẩn SRT, lập luận sâu',
      provider: AiProvider.groq,
      isRecommended: true,
    ),
    AiModelInfo(
      id: 'openai/gpt-oss-20b',
      displayName: 'GPT-OSS 20B (OpenAI)',
      shortDescription: 'Siêu tốc độ, nhẹ tài nguyên, tiết kiệm token',
      provider: AiProvider.groq,
    ),
    AiModelInfo(
      id: 'qwen/qwen3.8-27b',
      displayName: 'Qwen 3.8 27B (Alibaba)',
      shortDescription: 'Đặc trị Trung ➔ Việt, Hán Việt tự nhiên',
      provider: AiProvider.groq,
      isRecommended: true,
    ),
  ];

  static const List<AiModelInfo> geminiModels = [
    AiModelInfo(
      id: 'gemini-3.5-flash-lite',
      displayName: 'Gemini 3.5 Flash-Lite',
      shortDescription: 'RPD cao, ổn định đa luồng',
      provider: AiProvider.gemini,
    ),
    AiModelInfo(
      id: 'gemini-3.1-flash-lite',
      displayName: 'Gemini 3.1 Flash-Lite',
      shortDescription: 'Khuyên dùng cho Gemini',
      provider: AiProvider.gemini,
      isRecommended: true,
    ),
    AiModelInfo(
      id: 'gemma-4-26b-a4b-it',
      displayName: 'Gemma 4 26B A4B IT',
      shortDescription: 'MoE 26B (4B active), nhanh & nhẹ quota',
      provider: AiProvider.gemini,
    ),
    AiModelInfo(
      id: 'gemma-4-31b-it',
      displayName: 'Gemma 4 31B IT',
      shortDescription: 'Gemma 4 31B, hiểu ngữ cảnh sâu',
      provider: AiProvider.gemini,
    ),
  ];

  /// Danh sách model Gemini + Gemma 4 + model do người dùng tự thêm.
  static List<AiModelInfo> get allGeminiModels {
    final builtInIds = geminiModels.map((m) => m.id).toSet();
    return [
      ...geminiModels,
      for (final customId in _customGeminiModelIds)
        if (!builtInIds.contains(customId))
          AiModelInfo(
            id: customId,
            displayName: customId,
            shortDescription: isGemmaModel(customId)
                ? 'Gemma tùy chỉnh (REST generateContent)'
                : 'Model Gemini tùy chỉnh',
            provider: AiProvider.gemini,
            isCustom: true,
          ),
    ];
  }

  /// Danh sách model Groq mặc định + model do người dùng tự thêm.
  static List<AiModelInfo> get allGroqModels {
    final builtInIds = groqModels.map((m) => m.id).toSet();
    return [
      ...groqModels,
      for (final customId in _customGroqModelIds)
        if (!builtInIds.contains(customId))
          AiModelInfo(
            id: customId,
            displayName: customId,
            shortDescription: 'Model Groq tùy chỉnh',
            provider: AiProvider.groq,
            isCustom: true,
          ),
    ];
  }

  /// Model chuyên dụng Live Translate (dịch giọng nói sang giọng nói thời gian thực).
  static const String geminiLiveTranslateModel =
      'gemini-3.5-live-translate-preview';

  /// 3 model Gemini Live API (WebSocket BidiGenerateContent) dùng cho Trợ lý Hồng Quả.
  static const List<AiModelInfo> geminiLiveModels = [
    AiModelInfo(
      id: 'gemini-3.8-live',
      displayName: 'Gemini 3.8 Live',
      shortDescription: 'Nhanh, ổn định nhất cho hỏi đáp & gọi hàm tìm phim',
      provider: AiProvider.gemini,
      isRecommended: true,
    ),
    AiModelInfo(
      id: 'gemini-3.8-live-extended-thinking',
      displayName: 'Gemini 3.8 Live Extended Thinking',
      shortDescription: 'Suy luận sâu, đối chiếu cốt truyện danh sách phức tạp',
      provider: AiProvider.gemini,
    ),
    AiModelInfo(
      id: 'gemini-3.1-flash-live-preview',
      displayName: 'Gemini 3 Flash Live',
      shortDescription: 'Siêu nhẹ, phản hồi nhanh cho tìm kiếm & thoại liên tục',
      provider: AiProvider.gemini,
    ),
  ];

  /// Thứ tự alias dự phòng khi dò tên model thật trong `/v1beta/models`.
  static const Map<String, List<String>> liveModelCandidateIds = {
    'gemini-3.8-live': [
      'gemini-3.8-live',
      'gemini-3.8-live-preview',
    ],
    'gemini-3.8-live-extended-thinking': [
      'gemini-3.8-live-extended-thinking',
      'gemini-3.8-live-extended-thinking-preview',
      'gemini-3.8-live',
    ],
    'gemini-3.1-flash-live-preview': [
      'gemini-3.1-flash-live-preview',
      'gemini-3-flash-live',
      'gemini-3-flash-live-preview',
      'gemini-3.0-flash-live-preview',
      'gemini-live-2.5-flash-preview',
      'gemini-2.5-flash-native-audio-preview-12-2025',
    ],
    'gemini-3.5-live-translate-preview': [
      'gemini-3.5-live-translate-preview',
      'gemini-3.5-live-translate',
    ],
  };

  static bool isGemmaModel(String modelId) {
    final clean = normalizeModelId(modelId).toLowerCase();
    return clean.startsWith('gemma');
  }

  static bool isGeminiFamily(String modelId) {
    final clean = normalizeModelId(modelId);
    final lower = clean.toLowerCase();
    if (lower.startsWith('gemini') || lower.startsWith('gemma')) return true;
    return _customGeminiModelIds.contains(clean);
  }

  static AiProvider detectProvider(String modelId) {
    final normalized = normalizeModelId(modelId);
    final clean = normalized.toLowerCase();
    if (clean == 'capcut') return AiProvider.capcut;
    if (clean == 'none' || clean.isEmpty) return AiProvider.none;
    if (_customGeminiModelIds.contains(normalized) ||
        clean.startsWith('gemini') ||
        clean.startsWith('gemma')) {
      return AiProvider.gemini;
    }
    if (_customGroqModelIds.contains(normalized) ||
        clean.startsWith('openai/') ||
        clean.startsWith('qwen/') ||
        clean.startsWith('groq') ||
        clean.startsWith('llama') ||
        clean.startsWith('meta-llama') ||
        clean.startsWith('mixtral') ||
        clean.startsWith('deepseek')) {
      return AiProvider.groq;
    }
    return AiProvider.gemini;
  }

  static bool isAiTranslationModel(String modelId) {
    final p = detectProvider(modelId);
    return p == AiProvider.gemini || p == AiProvider.groq;
  }
}
