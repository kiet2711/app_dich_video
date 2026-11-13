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

  const AiModelInfo({
    required this.id,
    required this.displayName,
    required this.shortDescription,
    required this.provider,
    this.isRecommended = false,
  });
}

class AiModelRegistry {
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
  ];

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
  };

  static AiProvider detectProvider(String modelId) {
    final clean = modelId.trim().toLowerCase();
    if (clean == 'capcut') return AiProvider.capcut;
    if (clean == 'none' || clean.isEmpty) return AiProvider.none;
    if (clean.startsWith('gemini')) return AiProvider.gemini;
    if (clean.startsWith('openai/') ||
        clean.startsWith('qwen/') ||
        clean.startsWith('groq')) {
      return AiProvider.groq;
    }
    return AiProvider.gemini;
  }

  static bool isAiTranslationModel(String modelId) {
    final p = detectProvider(modelId);
    return p == AiProvider.gemini || p == AiProvider.groq;
  }
}
