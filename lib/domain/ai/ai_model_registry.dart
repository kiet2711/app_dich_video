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
