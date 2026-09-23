import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../data/api/gemini_translator.dart';
import '../../data/model/subtitle_document.dart';
import '../../data/repository/history_repository.dart';
import '../../data/repository/settings_repository.dart';
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
    final files = await FilePicker.pickFiles(type: FileType.video);
    if (files.isNotEmpty && files.first.path != null) {
      final path = files.first.path!;
      final name = File(path).uri.pathSegments.last;
      setState(() {
        _selectedVideoPath = path;
        _selectedVideoName = name.isNotEmpty ? name : 'video.mp4';
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Lỗi nạp file: $e')));
      }
    }
  }

  Future<void> _translateWithGemini() async {
    final sPath = _selectedSrtPath;
    final vPath = _selectedVideoPath;
    if (sPath == null) return;

    final settings = await SettingsRepository.getInstance();
    if (settings.geminiApiKeys.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Vui lòng cấu hình Gemini API Key trong Cài đặt trước!'),
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
            const SnackBar(content: Text('File phụ đề rỗng hoặc không đúng định dạng.')),
          );
        }
        return;
      }

      final model = settings.selectedModel.startsWith('gemini')
          ? settings.selectedModel
          : 'gemini-3.5-flash-lite';
      final translator = GeminiTranslator(
        apiKeys: settings.geminiApiKeys,
        modelId: model,
      );

      final translatedDoc = await translator.translateSubtitles(
        document: doc,
        stylePreset: settings.selectedStyle,
        customPrompt: settings.geminiCustomPrompt,
        targetLanguage: settings.targetLanguage,
        chunkSize: 45,
        threadCount: settings.geminiThreadCount,
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
              content: Text('Đã dịch xong ${translatedDoc.items.length} câu thoại!'),
            ),
          );
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isTranslating = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Lỗi dịch phụ đề: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasVideo = _selectedVideoPath != null;
    final hasSrt = _selectedSrtPath != null;

    return Dialog(
      backgroundColor: AppTheme.darkCard,
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
                  const Text(
                    '📥 Nhập Video & Phụ Đề',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (!_isTranslating)
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.grey),
                      onPressed: () => Navigator.pop(context),
                    ),
                ],
              ),
              const SizedBox(height: 14),

              // 1. CHỌN VIDEO
              InkWell(
                onTap: _isTranslating ? null : _pickVideo,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E2029),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: hasVideo
                          ? AppTheme.primaryEmerald
                          : const Color(0xFF2E313D),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        hasVideo ? Icons.check_circle : Icons.video_file,
                        color: hasVideo ? AppTheme.primaryEmerald : Colors.grey,
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
                                color: hasVideo ? Colors.white : Colors.grey,
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
                                color: hasVideo
                                    ? AppTheme.primaryEmerald
                                    : Colors.grey,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (hasVideo && !_isTranslating)
                        IconButton(
                          icon: const Icon(Icons.close, size: 18, color: Colors.grey),
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
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E2029),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: hasSrt
                          ? AppTheme.primaryEmerald
                          : const Color(0xFF2E313D),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        hasSrt ? Icons.check_circle : Icons.description,
                        color: hasSrt ? AppTheme.primaryEmerald : Colors.grey,
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _selectedSrtName ?? 'Chọn file Phụ đề (.srt, .vtt)',
                              style: TextStyle(
                                color: hasSrt ? Colors.white : Colors.grey,
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
                                color: hasSrt
                                    ? AppTheme.primaryEmerald
                                    : Colors.grey,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (hasSrt && !_isTranslating)
                        IconButton(
                          icon: const Icon(Icons.close, size: 18, color: Colors.grey),
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
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: AppTheme.primaryEmerald,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _translationProgressText,
                        style: const TextStyle(
                          color: AppTheme.primaryEmerald,
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
                      backgroundColor: AppTheme.primaryEmerald,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
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
                    icon: const Icon(
                      Icons.auto_awesome,
                      color: AppTheme.primaryEmerald,
                    ),
                    label: const Text(
                      'Dịch Phụ Đề Gốc Bằng AI (Gemini)',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppTheme.cardBorder),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
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
