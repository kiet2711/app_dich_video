import 'package:flutter/material.dart';

import '../../data/api/gemini_translator.dart';
import '../../data/model/subtitle_document.dart';
import '../../data/repository/settings_repository.dart';
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
  String _selectedModel = 'gemini-3.5-flash-lite';
  String _selectedTargetLang = 'Tiếng Việt';
  String _selectedStyle = 'Zhihu';
  final TextEditingController _customPromptController = TextEditingController();

  bool _isTranslating = false;
  double _progress = 0.0;
  String _progressMessage = '';

  static const List<MapEntry<String, String>> _modelOptions = [
    MapEntry('gemini-3.5-flash-lite', 'Gemini 3.5 Flash-Lite (RPD cao)'),
    MapEntry('gemini-3.1-flash-lite', 'Gemini 3.1 Flash-Lite (Khuyên dùng)'),
  ];

  static const List<String> _langOptions = [
    'Tiếng Việt',
    'Tiếng Anh',
    'Tiếng Trung',
    'Tiếng Nhật',
    'Tiếng Hàn',
  ];

  static const List<MapEntry<String, String>> _styleOptions = [
    MapEntry('Zhihu', 'Phong cách Zhihu (Kịch tính, dồn dập, gay cấn)'),
    MapEntry('thuanviet', 'Thuần Việt (Mượt mà, văn học, giàu cảm xúc)'),
    MapEntry('cotrang', 'Cổ trang (Tiên hiệp, kiếm hiệp, chuẩn danh xưng)'),
    MapEntry('standard', 'Tự nhiên (Phim tài liệu, vlog đời sống)'),
  ];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final s = await SettingsRepository.getInstance();
    setState(() {
      _settings = s;
      if (s.selectedModel == 'gemini-3.1-flash-lite') {
        _selectedModel = 'gemini-3.1-flash-lite';
      } else {
        _selectedModel = 'gemini-3.5-flash-lite';
      }
      _customPromptController.text = s.geminiCustomPrompt;
    });
  }

  @override
  void dispose() {
    _customPromptController.dispose();
    super.dispose();
  }

  Future<void> _startTranslation() async {
    final s = _settings;
    if (s == null) return;
    if (s.geminiApiKeys.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Vui lòng cấu hình ít nhất 1 API Key trong Cài Đặt!'),
        ),
      );
      return;
    }

    setState(() {
      _isTranslating = true;
      _progress = 0.05;
      _progressMessage = 'Bắt đầu kết nối Gemini AI...';
    });

    try {
      final translator = GeminiTranslator(
        apiKeys: s.geminiApiKeys,
        modelId: _selectedModel,
      );

      final resultDoc = await translator.translateSubtitles(
        document: widget.subtitleDoc,
        stylePreset: _selectedStyle,
        customPrompt: _customPromptController.text,
        targetLanguage: _selectedTargetLang,
        threadCount: s.geminiThreadCount,
        progressCallback: (pct, msg) {
          if (mounted) {
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
            content: Text('Đã dịch thành công ${resultDoc.size} câu phụ đề!'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isTranslating = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi dịch: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.darkCard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 500),
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.translate, color: AppTheme.primaryEmerald, size: 22),
                  SizedBox(width: 8),
                  Text(
                    'Dịch Phụ Đề Bằng Gemini AI',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // 1. Model Gemini
              const Text(
                'Mô hình dịch (Chỉ 2 model hỗ trợ):',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                initialValue: _selectedModel,
                isExpanded: true,
                dropdownColor: AppTheme.darkSurface,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: AppTheme.darkSurface,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppTheme.cardBorder),
                  ),
                ),
                style: const TextStyle(color: Colors.white, fontSize: 13),
                items: _modelOptions.map((e) {
                  return DropdownMenuItem(value: e.key, child: Text(e.value));
                }).toList(),
                onChanged: _isTranslating ? null : (v) => setState(() => _selectedModel = v!),
              ),
              const SizedBox(height: 12),

              // 2. Ngôn ngữ đích
              const Text(
                'Ngôn ngữ đích:',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                initialValue: _selectedTargetLang,
                isExpanded: true,
                dropdownColor: AppTheme.darkSurface,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: AppTheme.darkSurface,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppTheme.cardBorder),
                  ),
                ),
                style: const TextStyle(color: Colors.white, fontSize: 13),
                items: _langOptions.map((l) {
                  return DropdownMenuItem(value: l, child: Text(l));
                }).toList(),
                onChanged: _isTranslating ? null : (v) => setState(() => _selectedTargetLang = v!),
              ),
              const SizedBox(height: 12),

              // 3. Phong cách dịch
              const Text(
                'Phong cách dịch:',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                initialValue: _selectedStyle,
                isExpanded: true,
                dropdownColor: AppTheme.darkSurface,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: AppTheme.darkSurface,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppTheme.cardBorder),
                  ),
                ),
                style: const TextStyle(color: Colors.white, fontSize: 13),
                items: _styleOptions.map((s) {
                  return DropdownMenuItem(value: s.key, child: Text(s.value));
                }).toList(),
                onChanged: _isTranslating ? null : (v) => setState(() => _selectedStyle = v!),
              ),
              const SizedBox(height: 12),

              // 4. Custom prompt
              const Text(
                'Hướng dẫn bổ sung (Tùy chọn):',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _customPromptController,
                maxLines: 2,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: AppTheme.darkSurface,
                  hintText: 'Nhập hướng dẫn prompt thêm (vd: dịch xưng hô huynh/muội...)',
                  hintStyle: const TextStyle(color: Colors.grey, fontSize: 11),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppTheme.cardBorder),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              if (_isTranslating) ...[
                LinearProgressIndicator(
                  value: _progress,
                  backgroundColor: Colors.white12,
                  color: AppTheme.primaryEmerald,
                ),
                const SizedBox(height: 8),
                Text(
                  _progressMessage,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 12),
              ],

              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _isTranslating ? null : () => Navigator.pop(context),
                    child: const Text('Hủy', style: TextStyle(color: Colors.grey)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _isTranslating ? null : _startTranslation,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryEmerald,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Bắt Đầu Dịch', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }


}
