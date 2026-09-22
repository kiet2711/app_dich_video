import 'package:flutter/services.dart';
import '../../domain/media/network_header_helper.dart';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../data/model/subtitle_document.dart';
import '../../data/model/voice_model.dart';
import '../../data/repository/history_repository.dart';
import '../../data/repository/settings_repository.dart';
import '../../domain/tts/tts_generation_manager.dart';
import '../player/video_player_screen.dart';
import '../settings/settings_screen.dart';
import '../theme/app_theme.dart';
import 'gemini_translate_subtitle_dialog.dart';

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
  int _threadCount = 50;

  final TtsGenerationManager _ttsManager = TtsGenerationManager();

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
    if (widget.initialDoc != oldWidget.initialDoc && widget.initialDoc != null) {
      _doc = widget.initialDoc;
      _linkExistingAudio();
    }
    if (widget.initialVideoPath != oldWidget.initialVideoPath && widget.initialVideoPath != null) {
      _videoPath = widget.initialVideoPath;
    }
  }

  Future<void> _loadSettings() async {
    final s = await SettingsRepository.getInstance();
    if (!mounted) return;
    setState(() {
      _settings = s;
      _threadCount = s.ttsThreadCount;
      _selectedVoice = VoicePresets.vietnameseVoices.firstWhere(
        (v) => v.voiceType == s.selectedTtsVoice,
        orElse: () => VoicePresets.defaultVoice,
      );
    });
    _linkExistingAudio();
  }

  Future<void> _linkExistingAudio() async {
    if (_doc != null) {
      await TtsGenerationManager.linkAudioFiles(_doc!, _selectedVoice.voiceType);
      if (mounted) setState(() {});
    }
  }

  Future<void> _pickVideoFromFiles() async {
    final files = await FilePicker.pickFiles(type: FileType.video);
    if (files.isNotEmpty && files.first.path != null) {
      setState(() {
        _videoPath = files.first.path!;
      });
    }
  }

  void _showEnterLinkDialog() {
    final controller = TextEditingController(
      text: _videoPath?.startsWith('http') == true ? _videoPath : '',
    );
    String? errorText;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: AppColors.darkCard,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: const [
              Icon(Icons.link, color: AppColors.primaryEmerald, size: 20),
              SizedBox(width: 8),
              Text(
                'Nhập Link Video Online',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Dán link video trực tiếp (Bilibili, Douyin, MP4, M3U8...):',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: controller,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'https://.../video.mp4 hoặc link Bilibili',
                  hintStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                  filled: true,
                  fillColor: const Color(0xFF14151B),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.cardBorder),
                  ),
                ),
                onChanged: (_) {
                  if (errorText != null) {
                    setDialogState(() => errorText = null);
                  }
                },
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      final data = await Clipboard.getData('text/plain');
                      final text = data?.text?.trim() ?? '';
                      if (text.isNotEmpty) {
                        controller.text = text;
                        setDialogState(() => errorText = null);
                      }
                    },
                    icon: const Icon(Icons.paste, size: 14, color: AppColors.primaryEmerald),
                    label: const Text('Dán từ Clipboard', style: TextStyle(color: AppColors.primaryEmerald, fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      side: const BorderSide(color: AppColors.primaryEmerald),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ],
              ),
              if (errorText != null) ...[
                const SizedBox(height: 6),
                Text(
                  errorText!,
                  style: const TextStyle(color: Color(0xFFFFB74D), fontSize: 12),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Hủy', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryEmerald,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                final clean = NetworkHeaderHelper.extractCleanUrl(controller.text);
                if (clean.isEmpty || !NetworkHeaderHelper.isRemoteUrl(clean)) {
                  setDialogState(() {
                    errorText =
                        'Vui lòng nhập link hợp lệ (http://, https:// hoặc link Bilibili/b23.tv)';
                  });
                  return;
                }
                setState(() => _videoPath = clean);
                Navigator.pop(ctx);
              },
              child: const Text('Xác Nhận', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickSrtFile() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['srt', 'txt'],
    );
    if (files.isNotEmpty && files.first.path != null) {
      try {
        final content = await File(files.first.path!).readAsString();
        final doc = SubtitleDocument.parseSrt(content);
        if (doc.items.isNotEmpty) {
          setState(() => _doc = doc);
          await _linkExistingAudio();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Đã nạp thành công ${doc.items.length} câu phụ đề từ SRT!')),
            );
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Lỗi nạp SRT: $e')));
        }
      }
    }
  }

  Future<void> _showHistoryPicker() async {
    final historyRepo = await HistoryRepository.getInstance();
    final items = historyRepo.getHistory();
    if (items.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Chưa có bản ghi lịch sử nào!')),
        );
      }
      return;
    }

    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.darkCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Chọn Video Từ Lịch Sử',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: items.length,
                separatorBuilder: (_, _) => const Divider(color: AppColors.cardBorder),
                itemBuilder: (context, idx) {
                  final it = items[idx];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.history, color: AppColors.primaryEmerald),
                    title: Text(it.title, style: const TextStyle(color: Colors.white, fontSize: 14)),
                    subtitle: Text(
                      '${(it.durationMs / 1000).toStringAsFixed(0)}s • ${DateTime.fromMillisecondsSinceEpoch(it.timestamp).toLocal().toString().split(".")[0]}',
                      style: const TextStyle(color: Colors.grey, fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () async {
                      Navigator.pop(ctx);
                      try {
                        final srtContent = await File(it.srtPath).readAsString();
                        final doc = SubtitleDocument.parseSrt(srtContent);
                        if (!mounted) return;
                        setState(() {
                          _videoPath = it.videoPath;
                          _doc = doc;
                        });
                        await _linkExistingAudio();
                      } catch (e) {
                        if (mounted) {
                          messenger.showSnackBar(
                            SnackBar(content: Text('Không thể nạp phụ đề: $e')),
                          );
                        }
                      }
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openTranslateDialog() {
    if (_doc == null || _doc!.isEmpty) return;
    showDialog(
      context: context,
      builder: (ctx) => GeminiTranslateSubtitleDialog(
        subtitleDoc: _doc!,
        onTranslationCompleted: (newDoc) {
          setState(() => _doc = newDoc);
          _linkExistingAudio();
        },
      ),
    );
  }

  Future<void> _startGenerateAllTts() async {
    if (_doc == null || _doc!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vui lòng nạp phụ đề trước khi tạo giọng!')),
      );
      return;
    }

    await WakelockPlus.enable();
    try {
      await _ttsManager.generateAll(
        document: _doc!,
        voice: _selectedVoice,
        threadCount: _threadCount,
        forceRegenerate: false,
      );
      await _linkExistingAudio();
    } finally {
      await WakelockPlus.disable();
    }
  }

  void _navigateToPlayer() {
    if (_doc == null || _doc!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chưa có phụ đề để xem video!')),
      );
      return;
    }
    if (_videoPath == null || _videoPath!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vui lòng chọn Video Nguồn trước!')),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => VideoPlayerScreen(
          videoPath: _videoPath!,
          document: _doc!,
        ),
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
        title: Row(
          children: const [
            Icon(Icons.record_voice_over, color: AppColors.primaryEmerald, size: 22),
            SizedBox(width: 8),
            Text(
              'Lồng Tiếng AI (TTS Studio)',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white70),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (ctx) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 0. VIDEO NGUỒN
            _buildCard0VideoSource(),
            const SizedBox(height: 14),

            // 1. DANH SÁCH PHỤ ĐỀ
            _buildCard1Subtitle(),
            const SizedBox(height: 14),

            // 2. CHỌN GIỌNG ĐỌC CAPCUT
            _buildCard2VoiceSelector(),
            const SizedBox(height: 14),

            // 3. SỐ LUỒNG SONG SONG
            _buildCard3ThreadCount(),
            const SizedBox(height: 18),

            // TIẾN TRÌNH TẠO GIỌNG
            ValueListenableBuilder<TtsGenerationState>(
              valueListenable: _ttsManager.progress,
              builder: (context, state, _) {
                if (!state.isRunning) return const SizedBox.shrink();
                final pct = state.totalCount > 0 ? (state.completedCount / state.totalCount) : 0.0;
                return Container(
                  margin: const EdgeInsets.only(bottom: 14),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.darkCard,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.primaryEmerald),
                  ),
                  child: Column(
                    children: [
                      LinearProgressIndicator(value: pct, color: AppColors.primaryEmerald, backgroundColor: Colors.white12),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(state.currentSentence, style: const TextStyle(color: Colors.white, fontSize: 12)),
                          TextButton(
                            onPressed: () => _ttsManager.cancel(),
                            child: const Text('Hủy', style: TextStyle(color: Colors.redAccent)),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),

            // ACTION BUTTONS
            ElevatedButton.icon(
              onPressed: _startGenerateAllTts,
              icon: const Icon(Icons.mic, size: 20),
              label: const Text('🎙️ Tạo Giọng Đọc Toàn Bộ (Đa Luồng)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryEmerald,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _navigateToPlayer,
              icon: const Icon(Icons.play_circle_fill, size: 20, color: AppColors.primaryEmerald),
              label: const Text('🎬 Xem Video Lồng Tiếng & Phụ Đề', style: TextStyle(color: Colors.white, fontSize: 15)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.primaryEmerald),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 20),

            // SUBTITLES LIST PREVIEW
            if (_doc != null && _doc!.items.isNotEmpty) ...[
              Text(
                'Danh Sách Câu Phụ Đề (${_doc!.items.length} câu)',
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _doc!.items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, idx) {
                  final item = _doc!.items[idx];
                  final hasAudio = item.audioFilePath != null && item.audioFilePath!.isNotEmpty;
                  final displayText = item.translatedText.trim().isNotEmpty ? item.translatedText : item.originalText;
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.darkCard,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: hasAudio ? AppColors.primaryEmerald.withValues(alpha: 0.4) : AppColors.cardBorder),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '#${item.id} [${item.formatSrtTimecode()}]',
                              style: const TextStyle(color: Colors.grey, fontSize: 11),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: hasAudio ? AppColors.primaryEmerald.withValues(alpha: 0.15) : Colors.white10,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                hasAudio ? 'Đã có audio (${item.playbackSpeed.toStringAsFixed(2)}x)' : 'Chưa tạo audio',
                                style: TextStyle(
                                  color: hasAudio ? AppColors.primaryEmerald : Colors.grey,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(displayText, style: const TextStyle(color: Colors.white, fontSize: 13)),
                      ],
                    ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCard0VideoSource() {
    final hasVideo = _videoPath != null && _videoPath!.isNotEmpty;
    final isOnline = hasVideo && _videoPath!.startsWith('http');
    final name = hasVideo
        ? (isOnline ? NetworkHeaderHelper.getSuggestedTitle(_videoPath!) : File(_videoPath!).uri.pathSegments.last)
        : '';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.darkCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('0. Video Nguồn', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _pickVideoFromFiles,
                    icon: const Icon(Icons.video_file, size: 14, color: Colors.white),
                    label: const Text('File máy', style: TextStyle(color: Colors.white, fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      side: const BorderSide(color: AppColors.cardBorder),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _showEnterLinkDialog,
                    icon: const Icon(Icons.link, size: 14, color: AppColors.primaryEmerald),
                    label: const Text('Nhập Link', style: TextStyle(color: AppColors.primaryEmerald, fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      side: const BorderSide(color: AppColors.primaryEmerald),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF14151B),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white10),
            ),
            child: hasVideo
                ? Row(
                    children: [
                      const Icon(Icons.check_circle, color: AppColors.primaryEmerald, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          name,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 16, color: Colors.grey),
                        onPressed: () => setState(() => _videoPath = null),
                      ),
                    ],
                  )
                : const Center(
                    child: Text(
                      'Chạm để chọn File từ máy hoặc dán Link online',
                      style: TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard1Subtitle() {
    final hasDoc = _doc != null && _doc!.items.isNotEmpty;
    final voicedCount = hasDoc
        ? _doc!.items.where((it) => it.audioFilePath != null && it.audioFilePath!.isNotEmpty).length
        : 0;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.darkCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '1. Danh Sách Phụ Đề',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
              ),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _showHistoryPicker,
                    icon: const Icon(Icons.play_arrow, size: 14, color: Color(0xFF64B5F6)),
                    label: const Text('Lịch sử', style: TextStyle(color: Color(0xFF64B5F6), fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      side: const BorderSide(color: Color(0xFF64B5F6)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton.icon(
                    onPressed: _pickSrtFile,
                    icon: const Icon(Icons.file_upload, size: 14, color: AppColors.primaryEmerald),
                    label: const Text('Nạp SRT', style: TextStyle(color: AppColors.primaryEmerald, fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      side: const BorderSide(color: AppColors.primaryEmerald),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (hasDoc) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1F2029),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.subtitles, color: AppColors.primaryEmerald, size: 24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Đã sẵn sàng: ${_doc!.items.length} câu phụ đề',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          voicedCount > 0
                              ? 'Đã tạo giọng: $voicedCount / ${_doc!.items.length} câu'
                              : 'Chưa tạo giọng đọc',
                          style: TextStyle(
                            color: voicedCount > 0 ? AppColors.primaryEmerald : Colors.grey,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                    tooltip: 'Bỏ chọn phụ đề này',
                    onPressed: () => setState(() => _doc = null),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 38,
              child: OutlinedButton.icon(
                onPressed: _openTranslateDialog,
                icon: const Icon(Icons.translate, size: 16, color: Color(0xFF64B5F6)),
                label: const Text(
                  'Dịch phụ đề bằng Gemini AI',
                  style: TextStyle(
                    color: Color(0xFF64B5F6),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF384055)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  backgroundColor: const Color(0xFF1E222D).withValues(alpha: 0.3),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
              ),
            ),
          ] else ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              decoration: BoxDecoration(
                color: const Color(0xFF1F2029),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                children: const [
                  Icon(Icons.subtitles, color: Colors.grey, size: 32),
                  SizedBox(height: 8),
                  Text(
                    'Chưa có phụ đề để lồng tiếng',
                    style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 4),
                  Text(
                    "Tạo phụ đề từ Tab 'Tạo Phụ Đề' hoặc bấm 'Nạp SRT' ở trên",
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCard2VoiceSelector() {
    final voices = VoicePresets.vietnameseVoices;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.darkCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('2. Chọn Giọng Đọc CapCut', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.primaryEmerald.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.mic, size: 14, color: AppColors.primaryEmerald),
                    const SizedBox(width: 4),
                    Text(
                      _selectedVoice.displayName,
                      style: const TextStyle(color: AppColors.primaryEmerald, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 76,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: voices.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, idx) {
                final v = voices[idx];
                final isSelected = v.voiceType == _selectedVoice.voiceType;
                return GestureDetector(
                  onTap: () {
                    setState(() => _selectedVoice = v);
                    _settings?.selectedTtsVoice = v.voiceType;
                    _linkExistingAudio();
                  },
                  child: Container(
                    width: 145,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF14151B),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected ? AppColors.primaryEmerald : AppColors.cardBorder,
                        width: isSelected ? 1.5 : 1.0,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                v.displayName,
                                style: TextStyle(
                                  color: isSelected ? AppColors.primaryEmerald : Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isSelected) const Icon(Icons.check_circle, color: AppColors.primaryEmerald, size: 14),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          v.description.isNotEmpty ? v.description : 'Giọng đọc CapCut',
                          style: const TextStyle(color: Colors.grey, fontSize: 10),
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
        ],
      ),
    );
  }

  Widget _buildCard3ThreadCount() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.darkCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: const [
                  Icon(Icons.speed, color: AppColors.primaryEmerald, size: 18),
                  SizedBox(width: 6),
                  Text('3. Số Luồng Song Song', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                ],
              ),
              Text(
                '$_threadCount luồng',
                style: const TextStyle(color: AppColors.primaryEmerald, fontSize: 15, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppColors.primaryEmerald,
              thumbColor: AppColors.primaryEmerald,
              inactiveTrackColor: const Color(0xFF323444),
            ),
            child: Slider(
              value: _threadCount.toDouble(),
              min: 1,
              max: 100,
              divisions: 99,
              onChanged: (val) {
                setState(() => _threadCount = val.toInt());
                _settings?.ttsThreadCount = val.toInt();
              },
            ),
          ),
          const Text(
            'Mặc định 50 luồng. Hệ thống tự động phân chia và co giãn tốc độ đọc khớp khít mốc thời gian SRT.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
