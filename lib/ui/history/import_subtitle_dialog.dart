import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../data/model/subtitle_document.dart';
import '../../data/repository/history_repository.dart';
import '../../data/repository/settings_repository.dart';
import '../../domain/ai/ai_model_registry.dart';
import '../../domain/ai/smart_ai_translator.dart';
import '../../domain/media/media_storage.dart';
import '../theme/app_theme.dart';

class ImportSubtitleDialog extends StatefulWidget {
  final void Function(String videoPath, SubtitleDocument doc) onSuccessPlay;

  const ImportSubtitleDialog({super.key, required this.onSuccessPlay});

  @override
  State<ImportSubtitleDialog> createState() => _ImportSubtitleDialogState();
}

class _ImportSubtitleDialogState extends State<ImportSubtitleDialog> {
  String? _selectedVideoPath;
  String? _selectedVideoName;
  String? _selectedSrtPath;
  String? _selectedSrtName;

  bool _isTranslating = false;
  String _translationProgressText = '';

  Future<void> _pickVideo() async {
    final picked = await MediaStorage.pickPersistentMedia(
      context: context,
      videoOnly: true,
    );
    if (picked != null) {
      setState(() {
        _selectedVideoPath = picked.location;
        _selectedVideoName = picked.name.isNotEmpty ? picked.name : 'video.mp4';
      });
    }
  }

  Future<void> _pickSrt() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['srt', 'vtt', 'txt'],
    );
    if (files.isNotEmpty && files.first.path != null) {
      final path = files.first.path!;
      final name = File(path).uri.pathSegments.last;
      setState(() {
        _selectedSrtPath = path;
        _selectedSrtName = name.isNotEmpty ? name : 'subtitles.srt';
      });
    }
  }

  Future<void> _playDirectly() async {
    final vPath = _selectedVideoPath;
    final sPath = _selectedSrtPath;
    if (vPath == null || sPath == null) return;

    try {
      final srtText = await File(sPath).readAsString();
      final doc = SubtitleDocument.parseSrt(srtText);
      if (doc.items.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Không đọc được nội dung phụ đề SRT hợp lệ.'),
            ),
          );
        }
        return;
      }

      final historyRepo = await HistoryRepository.getInstance();
      await historyRepo.saveHistory(
        videoPath: vPath,
        title: _selectedVideoName ?? 'Video Import',
        document: doc,
      );

      if (mounted) {
        Navigator.pop(context);
        widget.onSuccessPlay(vPath, doc);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Lỗi nạp file: $e')));
      }
    }
  }

  Future<void> _translateWithGemini() async {
    final sPath = _selectedSrtPath;
    final vPath = _selectedVideoPath;
    if (sPath == null) return;

    final settings = await SettingsRepository.getInstance();
    final hasGemini = settings.geminiApiKeys.isNotEmpty;
    final hasGroq = settings.groqApiKeys.isNotEmpty;
    if (!hasGemini && !hasGroq) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Vui lòng cấu hình Gemini hoặc Groq API Key trong Cài đặt trước!',
            ),
          ),
        );
      }
      return;
    }

    setState(() {
      _isTranslating = true;
      _translationProgressText = 'Đang đọc file phụ đề...';
    });

    try {
      final srtText = await File(sPath).readAsString();
      final doc = SubtitleDocument.parseSrt(srtText);
      if (doc.items.isEmpty) {
        if (mounted) {
          setState(() => _isTranslating = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('File phụ đề rỗng hoặc không đúng định dạng.'),
            ),
          );
        }
        return;
      }

      final model = settings.selectedModel;
      if (settings.geminiApiKeys.isEmpty && settings.groqApiKeys.isEmpty) {
        throw StateError(
          'Chưa có API Key nào được cấu hình! Vui lòng vào Cài đặt để thêm Gemini hoặc Groq Key.',
        );
      }

      final smartTranslator = SmartAiTranslator(
        geminiKeys: settings.geminiApiKeys,
        groqKeys: settings.groqApiKeys,
        initialModelId: model,
        enableSmartModelFallback: settings.enableSmartModelFallback,
        enableCrossProviderFallback: settings.enableCrossProviderFallback,
        enableDualModelBalancing: settings.enableDualModelBalancing,
      );
      final effectiveThreadCount = AiModelRegistry.isGeminiFamily(model)
          ? settings.geminiThreadCount
          : settings.groqThreadCount;
      final effectiveBatchSize = AiModelRegistry.isGeminiFamily(model)
          ? settings.geminiBatchSize
          : settings.groqBatchSize;

      final SubtitleDocument translatedDoc = await smartTranslator.translateSubtitles(
        document: doc,
        stylePreset: settings.selectedStyle,
        customPrompt: settings.geminiCustomPrompt,
        targetLanguage: settings.targetLanguage,
        chunkSize: effectiveBatchSize,
        threadCount: effectiveThreadCount,
        progressCallback: (pct, msg) {
          if (mounted) {
            setState(() => _translationProgressText = msg);
          }
        },
      );

      if (vPath != null) {
        final historyRepo = await HistoryRepository.getInstance();
        await historyRepo.saveHistory(
          videoPath: vPath,
          title: _selectedVideoName ?? 'Video Import',
          document: translatedDoc,
        );

        if (mounted) {
          setState(() => _isTranslating = false);
          Navigator.pop(context);
          widget.onSuccessPlay(vPath, translatedDoc);
        }
      } else {
        setState(() => _isTranslating = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Đã dịch xong ${translatedDoc.items.length} câu thoại!',
              ),
            ),
          );
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isTranslating = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Lỗi dịch phụ đề: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.history);
    final onAccent = palette.onColor(accent);
    final hasVideo = _selectedVideoPath != null;
    final hasSrt = _selectedSrtPath != null;

    return Dialog(
      backgroundColor: palette.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '📥 Nhập Video & Phụ Đề',
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (!_isTranslating)
                    IconButton(
                      icon: Icon(Icons.close, color: palette.textMuted),
                      onPressed: () => Navigator.pop(context),
                    ),
                ],
              ),
              const SizedBox(height: 14),

              // 1. CHỌN VIDEO
              InkWell(
                onTap: _isTranslating ? null : _pickVideo,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: palette.surfaceAlt,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: hasVideo ? accent : palette.border,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        hasVideo ? Icons.check_circle : Icons.video_file,
                        color: hasVideo ? accent : palette.textMuted,
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _selectedVideoName ?? 'Chọn file Video từ máy',
                              style: TextStyle(
                                color: hasVideo ? palette.textPrimary : palette.textSecondary,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              hasVideo
                                  ? 'Đã chọn video (Chạm để đổi)'
                                  : 'Hỗ trợ MP4, MKV, MOV',
                              style: TextStyle(
                                color: hasVideo ? accent : palette.textMuted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (hasVideo && !_isTranslating)
                        IconButton(
                          icon: Icon(
                            Icons.close,
                            size: 18,
                            color: palette.textMuted,
                          ),
                          onPressed: () {
                            setState(() {
                              _selectedVideoPath = null;
                              _selectedVideoName = null;
                            });
                          },
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // 2. CHỌN FILE PHỤ ĐỀ
              InkWell(
                onTap: _isTranslating ? null : _pickSrt,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: palette.surfaceAlt,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: hasSrt ? accent : palette.border,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        hasSrt ? Icons.check_circle : Icons.description,
                        color: hasSrt ? accent : palette.textMuted,
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _selectedSrtName ??
                                  'Chọn file Phụ đề (.srt, .vtt)',
                              style: TextStyle(
                                color: hasSrt ? palette.textPrimary : palette.textSecondary,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              hasSrt
                                  ? 'Đã nhận file phụ đề (Chạm để đổi)'
                                  : 'File phụ đề rời có sẵn',
                              style: TextStyle(
                                color: hasSrt ? accent : palette.textMuted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (hasSrt && !_isTranslating)
                        IconButton(
                          icon: Icon(
                            Icons.close,
                            size: 18,
                            color: palette.textMuted,
                          ),
                          onPressed: () {
                            setState(() {
                              _selectedSrtPath = null;
                              _selectedSrtName = null;
                            });
                          },
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),

              // Trạng thái đang dịch hoặc các nút thao tác
              if (_isTranslating) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: accent,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _translationProgressText,
                        style: TextStyle(
                          color: accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                // Nút 1: Xem ngay (Cần Video + Sub)
                SizedBox(
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: (hasVideo && hasSrt) ? _playDirectly : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text(
                      'Xem Ngay với Phụ Đề Này',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: onAccent,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),

                // Nút 2: Dịch file phụ đề gốc bằng AI
                SizedBox(
                  height: 48,
                  child: OutlinedButton.icon(
                    onPressed: hasSrt ? _translateWithGemini : null,
                    icon: Icon(
                      Icons.auto_awesome,
                      color: accent,
                    ),
                    label: Text(
                      'Dịch Phụ Đề Gốc Bằng AI (Gemini)',
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: palette.border),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
