import 'package:flutter/material.dart';

import '../../data/model/subtitle_document.dart';
import '../../data/repository/settings_repository.dart';
import '../../domain/ai/ai_model_registry.dart';
import '../../domain/ai/smart_ai_translator.dart';
import '../settings/settings_screen.dart';
import '../theme/app_theme.dart';

class GeminiTranslateSubtitleDialog extends StatefulWidget {
  final SubtitleDocument subtitleDoc;
  final ValueChanged<SubtitleDocument> onTranslationCompleted;

  const GeminiTranslateSubtitleDialog({
    super.key,
    required this.subtitleDoc,
    required this.onTranslationCompleted,
  });

  @override
  State<GeminiTranslateSubtitleDialog> createState() =>
      _GeminiTranslateSubtitleDialogState();
}

class _GeminiTranslateSubtitleDialogState
    extends State<GeminiTranslateSubtitleDialog> {
  SettingsRepository? _settings;
  List<String> _apiKeys = [];
  bool _isLoadingSettings = true;

  final List<MapEntry<String, String>> _langOptions = const [
    MapEntry('Tiếng Việt', '🇻🇳 Tiếng Việt'),
    MapEntry('Tiếng Anh', '🇺🇸 Tiếng Anh (English)'),
    MapEntry('Tiếng Trung', '🇨🇳 Tiếng Trung (Chinese)'),
    MapEntry('Tiếng Nhật', '🇯🇵 Tiếng Nhật (Japanese)'),
    MapEntry('Tiếng Hàn', '🇰🇷 Tiếng Hàn (Korean)'),
  ];

  final List<MapEntry<String, String>> _modelOptions = const [
    MapEntry('gemini-3.1-flash-lite', '🌐 Gemini 3.1 Flash-Lite (Khuyên dùng)'),
    MapEntry('gemini-3.5-flash-lite', '🌐 Gemini 3.5 Flash-Lite (RPD cao)'),
    MapEntry('openai/gpt-oss-120b', '⚡ Groq: GPT-OSS 120B (OpenAI - SRT đỉnh)'),
    MapEntry('openai/gpt-oss-20b', '⚡ Groq: GPT-OSS 20B (OpenAI - Siêu tốc)'),
    MapEntry('qwen/qwen3.8-27b', '🇨🇳 Groq: Qwen 3.8 27B (Trung ➔ Việt)'),
  ];

  String _selectedTargetLang = 'Tiếng Việt';
  String _selectedModel = 'gemini-3.1-flash-lite';
  final TextEditingController _contextPromptController = TextEditingController();

  bool _isTranslating = false;
  double _progress = 0.0;
  String _progressMessage = '';
  bool _isCancelled = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final s = await SettingsRepository.getInstance();
    if (!mounted) return;
    setState(() {
      _settings = s;
      _apiKeys = s.geminiApiKeys;
      if (_modelOptions.any((e) => e.key == s.selectedModel)) {
        _selectedModel = s.selectedModel;
      } else {
        _selectedModel = 'gemini-3.1-flash-lite';
      }
      if (_langOptions.any((e) => e.key == s.targetLanguage)) {
        _selectedTargetLang = s.targetLanguage;
      }
      _contextPromptController.text = s.geminiCustomPrompt;
      _isLoadingSettings = false;
    });
  }

  @override
  void dispose() {
    _contextPromptController.dispose();
    super.dispose();
  }

  Future<void> _startTranslation() async {
    final provider = AiModelRegistry.detectProvider(_selectedModel);
    final hasGemini = _apiKeys.isNotEmpty;
    final hasGroq = _settings?.groqApiKeys.isNotEmpty ?? false;
    final canFallback = _settings?.enableCrossProviderFallback ?? true;

    if (provider == AiProvider.groq) {
      if (!hasGroq && (!canFallback || !hasGemini)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Vui lòng nhập Groq API Key trong Cài Đặt!'),
          ),
        );
        return;
      }
    } else {
      if (!hasGemini && (!canFallback || !hasGroq)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Vui lòng nhập Gemini API Key trong Cài Đặt!'),
          ),
        );
        return;
      }
    }

    setState(() {
      _isTranslating = true;
      _isCancelled = false;
      _progress = 0.05;
      _progressMessage = 'Đang chuẩn bị dịch...';
    });

    try {
      final promptToUse = _contextPromptController.text.trim().isNotEmpty
          ? _contextPromptController.text.trim()
          : (_settings?.geminiCustomPrompt ?? '');

      final smartTranslator = SmartAiTranslator(
        geminiKeys: _apiKeys,
        groqKeys: _settings?.groqApiKeys ?? const [],
        initialModelId: _selectedModel,
        enableSmartModelFallback: _settings?.enableSmartModelFallback ?? true,
        enableCrossProviderFallback: _settings?.enableCrossProviderFallback ?? true,
        enableDualModelBalancing: _settings?.enableDualModelBalancing ?? true,
      );
      final effectiveThreadCount = _selectedModel.startsWith('gemini')
          ? (_settings?.geminiThreadCount ?? 2)
          : (_settings?.groqThreadCount ?? 3);
      final effectiveBatchSize = _selectedModel.startsWith('gemini')
          ? (_settings?.geminiBatchSize ?? 45)
          : (_settings?.groqBatchSize ?? 45);

      final SubtitleDocument resultDoc = await smartTranslator.translateSubtitles(
        document: widget.subtitleDoc,
        stylePreset: _settings?.selectedStyle ?? 'Zhihu',
        customPrompt: promptToUse,
        targetLanguage: _selectedTargetLang,
        chunkSize: effectiveBatchSize,
        threadCount: effectiveThreadCount,
        isCancelled: () => _isCancelled,
        progressCallback: (pct, msg) {
          if (mounted && !_isCancelled) {
            setState(() {
              _progress = pct;
              _progressMessage = msg;
            });
          }
        },
      );

      if (mounted) {
        widget.onTranslationCompleted(resultDoc);
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Đã dịch xong ${resultDoc.items.length} câu phụ đề!',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isTranslating = false;
          _progressMessage = 'Lỗi dịch: $e';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi dịch: $e')),
        );
      }
    }
  }

  void _cancelTranslation() {
    setState(() {
      _isCancelled = true;
      _isTranslating = false;
      _progressMessage = 'Đã huỷ dịch.';
    });
  }

  Widget _buildDropdownContainer({
    required String value,
    required List<MapEntry<String, String>> items,
    required bool enabled,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF14151B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          icon: const Icon(Icons.arrow_drop_down, color: Colors.grey),
          dropdownColor: const Color(0xFF1E1F28),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
          items: items.map((e) {
            return DropdownMenuItem<String>(
              value: e.key,
              child: Text(
                e.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            );
          }).toList(),
          onChanged: enabled ? onChanged : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.darkCard,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title
              Row(
                children: const [
                  Icon(Icons.translate, color: AppColors.primaryEmerald, size: 22),
                  SizedBox(width: 8),
                  Text(
                    'Dịch Phụ Đề AI (Gemini / Groq)',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Dịch ${widget.subtitleDoc.items.length} câu phụ đề sang ngôn ngữ đích để lồng tiếng hoặc xem Vietsub:',
                style: const TextStyle(color: Color(0xFFCCCCCC), fontSize: 13),
              ),
              const SizedBox(height: 14),

              // 1. Ngôn ngữ dịch sang
              const Text(
                '🔵 Ngôn ngữ dịch sang:',
                style: TextStyle(
                  color: Color(0xFFB0B0B8),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
              _buildDropdownContainer(
                value: _selectedTargetLang,
                items: _langOptions,
                enabled: !_isTranslating,
                onChanged: (val) {
                  if (val != null) setState(() => _selectedTargetLang = val);
                },
              ),
              const SizedBox(height: 12),

              // 2. Model AI
              const Text(
                '🤖 Model AI (Gemini / Groq):',
                style: TextStyle(
                  color: Color(0xFFB0B0B8),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
              _buildDropdownContainer(
                value: _selectedModel,
                items: _modelOptions,
                enabled: !_isTranslating,
                onChanged: (val) {
                  if (val != null) setState(() => _selectedModel = val);
                },
              ),
              const SizedBox(height: 12),

              // 3. Ngữ cảnh / Gợi ý dịch
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: const [
                  Text(
                    '✍️ Ngữ cảnh / Gợi ý dịch:',
                    style: TextStyle(
                      color: Color(0xFFB0B0B8),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    'Có thể bỏ trống',
                    style: TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _contextPromptController,
                enabled: !_isTranslating,
                minLines: 2,
                maxLines: 3,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF14151B),
                  hintText:
                      'Ví dụ: Phim cổ trang, xưng hô huynh - đệ; video review công nghệ; văn phong vui vẻ...',
                  hintStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.cardBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.cardBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide:
                        const BorderSide(color: AppColors.primaryEmerald),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // 4. Trạng thái API Key
              if (_isLoadingSettings)
                const SizedBox.shrink()
              else ...[
                () {
                  final provider = AiModelRegistry.detectProvider(_selectedModel);
                  final isGroq = provider == AiProvider.groq;
                  final activeKeys = isGroq
                      ? (_settings?.groqApiKeys ?? const [])
                      : _apiKeys;
                  final providerName = isGroq ? 'Groq' : 'Gemini';
                  final hasBackup = isGroq
                      ? _apiKeys.isNotEmpty
                      : (_settings?.groqApiKeys.isNotEmpty ?? false);
                  final backupCount = isGroq
                      ? _apiKeys.length
                      : (_settings?.groqApiKeys.length ?? 0);
                  final backupName = isGroq ? 'Gemini' : 'Groq';

                  if (activeKeys.isNotEmpty) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.check_circle,
                              color: AppColors.primaryEmerald,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Đã cấu hình ${activeKeys.length} $providerName API Key',
                              style: const TextStyle(
                                color: AppColors.primaryEmerald,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        if ((_settings?.enableCrossProviderFallback ?? true) &&
                            hasBackup) ...[
                          const SizedBox(height: 3),
                          Padding(
                            padding: const EdgeInsets.only(left: 22),
                            child: Text(
                              '🔄 Dự phòng chéo: $backupCount $backupName Key',
                              style: const TextStyle(
                                color: Color(0xFF64B5F6),
                                fontSize: 11,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ),
                        ],
                      ],
                    );
                  } else {
                    return Row(
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          color: Color(0xFFFFB74D),
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            hasBackup
                                ? 'Chưa có $providerName Key (sẽ tự động dùng $backupCount $backupName Key)'
                                : 'Chưa có $providerName API Key!',
                            style: const TextStyle(
                              color: Color(0xFFFFB74D),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            Navigator.pop(context);
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const SettingsScreen(),
                              ),
                            );
                          },
                          child: const Text(
                            'Cài đặt',
                            style: TextStyle(
                              color: AppColors.primaryEmerald,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    );
                  }
                }(),
              ],

              // 5. Thanh tiến trình khi đang dịch
              if (_isTranslating) ...[
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: _progress,
                    minHeight: 6,
                    color: AppColors.primaryEmerald,
                    backgroundColor: const Color(0xFF2A2B36),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _progressMessage,
                  style: const TextStyle(
                    color: AppColors.primaryEmerald,
                    fontSize: 12,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],

              const SizedBox(height: 16),

              // Action buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (_isTranslating)
                    TextButton(
                      onPressed: _cancelTranslation,
                      child: const Text(
                        'Huỷ dịch',
                        style: TextStyle(color: Color(0xFFFF6B6B)),
                      ),
                    )
                  else ...[
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text(
                        'Đóng',
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: _apiKeys.isNotEmpty ? _startTranslation : null,
                      icon: Icon(
                        Icons.translate,
                        size: 16,
                        color: _apiKeys.isNotEmpty ? Colors.black : Colors.grey,
                      ),
                      label: Text(
                        'Bắt Đầu Dịch',
                        style: TextStyle(
                          color: _apiKeys.isNotEmpty ? Colors.black : Colors.grey,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryEmerald,
                        disabledBackgroundColor: const Color(0xFF2A2B36),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
