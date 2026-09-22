import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../data/api/capcut_tts_client.dart';
import '../../data/api/capcut_signer.dart';
import '../../data/model/subtitle_document.dart';

import '../../data/model/voice_model.dart';
import '../../data/repository/settings_repository.dart';
import '../../domain/media/media_storage.dart';
import '../player/video_player_screen.dart';
import '../theme/app_theme.dart';

class TtsStudioScreen extends StatefulWidget {
  final SubtitleDocument? initialDoc;
  final String? initialVideoPath;

  const TtsStudioScreen({super.key, this.initialDoc, this.initialVideoPath});

  @override
  State<TtsStudioScreen> createState() => _TtsStudioScreenState();
}

class _TtsStudioScreenState extends State<TtsStudioScreen> {
  SettingsRepository? _settings;
  SubtitleDocument? _doc;
  String? _videoPath;

  VoiceItem _selectedVoice = VoicePresets.defaultVoice;
  double _playbackSpeed = 1.0;
  bool _isGeneratingTts = false;
  int _ttsProgressCurrent = 0;
  int _ttsProgressTotal = 0;

  @override
  void initState() {
    super.initState();
    _doc = widget.initialDoc;
    _videoPath = widget.initialVideoPath;
    _loadSettings();
  }

  @override
  void didUpdateWidget(covariant TtsStudioScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialDoc != oldWidget.initialDoc &&
        widget.initialDoc != null) {
      _doc = widget.initialDoc;
    }
    if (widget.initialVideoPath != oldWidget.initialVideoPath &&
        widget.initialVideoPath != null) {
      _videoPath = widget.initialVideoPath;
    }
  }

  Future<void> _loadSettings() async {
    final s = await SettingsRepository.getInstance();
    if (!mounted) return;
    setState(() {
      _settings = s;
      _selectedVoice = VoicePresets.vietnameseVoices.firstWhere(
        (v) => v.voiceType == s.selectedTtsVoice,
        orElse: () => VoicePresets.defaultVoice,
      );
    });
  }

  Future<void> _pickSubtitleFile() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['srt'],
    );
    if (files.isNotEmpty && files.first.path != null) {
      final content = await File(files.first.path!).readAsString();
      final loadedDoc = SubtitleDocument.parseSrt(content);
      setState(() {
        _doc = loadedDoc;
      });
    }
  }

  Future<void> _pickVideoFile() async {
    final files = await FilePicker.pickFiles(type: FileType.video);
    if (files.isNotEmpty && files.first.path != null) {
      final imported = await MediaStorage.importForPersistentAccess(
        File(files.first.path!),
        files.first.name,
      );
      if (!mounted) return;
      setState(() {
        _videoPath = imported.path;
      });
    }
  }

  Future<void> _generateTtsForAll() async {
    if (_doc == null || _doc!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chưa có phụ đề để tạo giọng đọc')),
      );
      return;
    }

    setState(() {
      _isGeneratingTts = true;
      _ttsProgressCurrent = 0;
      _ttsProgressTotal = _doc!.size;
    });
    await WakelockPlus.enable();
    try {
      final supportDir = await getApplicationSupportDirectory();
      final ttsDir = Directory(
        '${supportDir.path}/tts_cache/${_selectedVoice.voiceType}',
      );
      await ttsDir.create(recursive: true);

      final items = _doc!.items;
      var nextIndex = 0;
      var completed = 0;
      final errors = <String>[];
      final workerCount = (_settings?.ttsThreadCount ?? 4)
          .clamp(1, 6)
          .clamp(1, items.length)
          .toInt();

      Future<void> worker() async {
        final client = CapCutTtsClient();
        while (true) {
          final index = nextIndex++;
          if (index >= items.length) return;
          final item = items[index];
          final text = item.getTranslationOnlyText();
          if (text.isNotEmpty) {
            final cacheKey = CapCutSigner.md5String(
              '${_selectedVoice.voiceType}|${_playbackSpeed.toStringAsFixed(2)}|$text',
            );
            final destFile = File('${ttsDir.path}/$cacheKey.mp3');
            if (await destFile.exists() && await destFile.length() > 500) {
              item.audioFilePath = destFile.path;
            } else {
              try {
                await client.generateSpeechToFile(
                  text: text,
                  voiceType: _selectedVoice.voiceType,
                  resourceId: _selectedVoice.resourceId,
                  rate: _playbackSpeed.toStringAsFixed(1),
                  destFile: destFile,
                );
                item.audioFilePath = destFile.path;
              } catch (e) {
                errors.add('#${item.id}: $e');
              }
            }
          }

          completed++;
          if (mounted) setState(() => _ttsProgressCurrent = completed);
        }
      }

      await Future.wait(List.generate(workerCount, (_) => worker()));

      if (mounted) {
        final successCount = items
            .where((item) => item.audioFilePath != null)
            .length;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              errors.isEmpty
                  ? 'Đã tạo giọng đọc cho $successCount/${items.length} câu.'
                  : 'Tạo được $successCount/${items.length} câu; lỗi ${errors.length} câu.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Không thể tạo giọng đọc: $e')));
      }
    } finally {
      await WakelockPlus.disable();
      if (mounted) setState(() => _isGeneratingTts = false);
    }
  }

  void _openPlayer() {
    if (_videoPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vui lòng chọn video trước')),
      );
      return;
    }
    if (_doc == null || _doc!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Vui lòng chọn hoặc tạo file phụ đề trước'),
        ),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) =>
            VideoPlayerScreen(videoPath: _videoPath!, document: _doc!),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        backgroundColor: AppColors.darkBackground,
        elevation: 0,
        title: const Row(
          children: [
            Icon(
              Icons.record_voice_over,
              color: AppColors.primaryEmerald,
              size: 24,
            ),
            SizedBox(width: 8),
            Text(
              'Studio Lồng Tiếng AI',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),

            // Card 1: Chọn Video & File SRT
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.darkSurface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.video_library,
                        color: AppColors.primaryEmerald,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _videoPath != null
                              ? _videoPath!.split(Platform.pathSeparator).last
                              : 'Chưa chọn video',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _pickVideoFile,
                        icon: const Icon(
                          Icons.upload_file,
                          size: 16,
                          color: AppColors.primaryEmerald,
                        ),
                        label: const Text(
                          'Chọn Video',
                          style: TextStyle(color: AppColors.primaryEmerald),
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: AppColors.cardBorder),
                  Row(
                    children: [
                      const Icon(
                        Icons.subtitles,
                        color: AppColors.accentGold,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _doc != null && _doc!.isNotEmpty
                              ? 'Đã nạp ${_doc!.size} câu phụ đề'
                              : 'Chưa có file phụ đề SRT',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _pickSubtitleFile,
                        icon: const Icon(
                          Icons.file_open,
                          size: 16,
                          color: AppColors.accentGold,
                        ),
                        label: const Text(
                          'Chọn file SRT',
                          style: TextStyle(color: AppColors.accentGold),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Card 2: Chọn giọng đọc CapCut (Horizontal list)
            const Text(
              'Chọn giọng đọc CapCut AI (26 Giọng Việt)',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 115,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: VoicePresets.vietnameseVoices.length,
                itemBuilder: (context, index) {
                  final voice = VoicePresets.vietnameseVoices[index];
                  final isSelected =
                      voice.voiceType == _selectedVoice.voiceType;

                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        _selectedVoice = voice;
                        _settings?.selectedTtsVoice = voice.voiceType;
                      });
                    },
                    child: Container(
                      width: 140,
                      margin: const EdgeInsets.only(right: 10),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFF1B3B2B)
                            : AppColors.darkSurface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected
                              ? AppColors.primaryEmerald
                              : AppColors.cardBorder,
                          width: isSelected ? 2 : 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.mic,
                                color: isSelected
                                    ? AppColors.primaryEmerald
                                    : Colors.grey,
                                size: 18,
                              ),
                              const Spacer(),
                              if (isSelected)
                                const Icon(
                                  Icons.check_circle,
                                  color: AppColors.primaryEmerald,
                                  size: 16,
                                ),
                            ],
                          ),
                          const Spacer(),
                          Text(
                            voice.displayName,
                            style: TextStyle(
                              color: isSelected
                                  ? AppColors.primaryEmerald
                                  : Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            voice.description,
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 10,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),

            // Card 3: Tốc độ đọc
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.darkSurface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: Row(
                children: [
                  const Icon(Icons.speed, color: AppColors.primaryEmerald),
                  const SizedBox(width: 10),
                  Text(
                    'Tốc độ: ${_playbackSpeed.toStringAsFixed(1)}x',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: _playbackSpeed,
                      min: 0.8,
                      max: 1.5,
                      divisions: 7,
                      activeColor: AppColors.primaryEmerald,
                      inactiveColor: AppColors.cardBorder,
                      onChanged: (val) {
                        setState(() {
                          _playbackSpeed = val;
                        });
                      },
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Nút Thao Tác Lớn:
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryEmerald,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: _isGeneratingTts ? null : _generateTtsForAll,
              icon: _isGeneratingTts
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        color: Colors.black,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.auto_awesome, color: Colors.black),
              label: Text(
                _isGeneratingTts
                    ? 'Đang tạo giọng đọc ($_ttsProgressCurrent/$_ttsProgressTotal)...'
                    : '🎙️ Tạo Giọng Đọc Toàn Bộ (Đa Luồng)',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(height: 10),

            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: AppColors.primaryEmerald),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: _openPlayer,
              icon: const Icon(
                Icons.play_circle_fill,
                color: AppColors.primaryEmerald,
              ),
              label: const Text(
                '🎬 Xem Video Lồng Tiếng & Phụ Đề',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 16),

            // Danh sách các câu phụ đề bên dưới
            if (_doc != null && _doc!.isNotEmpty) ...[
              Text(
                'Kịch bản thoại (${_doc!.size} câu)',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 8),
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _doc!.items.length,
                itemBuilder: (context, index) {
                  final item = _doc!.items[index];
                  final hasAudio =
                      item.audioFilePath != null &&
                      File(item.audioFilePath!).existsSync();

                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.darkSurface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: hasAudio
                            ? AppColors.primaryEmerald.withValues(alpha: 0.4)
                            : AppColors.cardBorder,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '#${item.id}',
                          style: const TextStyle(
                            color: AppColors.primaryEmerald,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.getDisplayText('translated'),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                              if (item.originalText.isNotEmpty &&
                                  item.originalText != item.translatedText)
                                Text(
                                  item.originalText,
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 11,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Icon(
                          hasAudio ? Icons.volume_up : Icons.volume_off,
                          color: hasAudio
                              ? AppColors.primaryEmerald
                              : Colors.grey,
                          size: 18,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
