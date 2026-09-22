import '../../domain/media/network_header_helper.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../data/model/history_item.dart';
import '../../data/model/process_progress.dart';
import '../../data/model/subtitle_document.dart';
import '../../data/repository/history_repository.dart';
import '../../data/repository/settings_repository.dart';
import '../../domain/pipeline/subtitling_pipeline.dart';
import '../../domain/media/audio_extractor.dart';
import '../../domain/media/media_storage.dart';
import '../../domain/media/bilibili_resolver.dart';
import '../theme/app_theme.dart';
import 'progress_bottom_sheet.dart';

class HomeScreen extends StatefulWidget {
  final VoidCallback? onNavigateToSettings;
  final void Function(SubtitleDocument doc, String videoPath)?
  onProcessCompleted;

  const HomeScreen({
    super.key,
    this.onNavigateToSettings,
    this.onProcessCompleted,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  SettingsRepository? _settings;
  int _inputMode = 0; // 0: File máy, 1: Link video online

  String? _selectedVideoPath;
  String _fileName = '';
  int _fileDurationMs = 0;
  String _fileSizeMb = '';

  final _urlController = TextEditingController();
  bool _isProbingUrl = false;
  String? _probeStatusMessage;

  String _selectedSourceLang = 'zh-CN';
  String _selectedEngine = 'capcut';
  String _selectedTargetLang = 'vi-VN';
  String _selectedStyle = 'Zhihu';
  final _customPromptController = TextEditingController();

  bool _isProcessing = false;
  ProcessProgress _currentProgress = const ProcessProgress();
  SubtitlingPipeline? _activePipeline;
  bool _cancelRequested = false;

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
      _selectedSourceLang = s.defaultSourceLanguage;
      _selectedEngine = s.selectedModel;
      _selectedTargetLang = s.targetLanguage;
      _selectedStyle = s.selectedStyle;
      _customPromptController.text = s.geminiCustomPrompt;
    });
  }

  @override
  void dispose() {
    _activePipeline?.cancel();
    unawaited(WakelockPlus.disable());
    _urlController.dispose();
    _customPromptController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        'mp4',
        'mov',
        'm4v',
        'mkv',
        'webm',
        'mp3',
        'm4a',
        'aac',
        'wav',
        'flac',
      ],
    );
    if (files.isEmpty || files.first.path == null) return;

    final pickedFile = File(files.first.path!);
    try {
      if (mounted) {
        setState(
          () => _probeStatusMessage =
              '⏳ Đang nhập media vào vùng lưu trữ của ứng dụng...',
        );
      }
      final file = await MediaStorage.importForPersistentAccess(
        pickedFile,
        files.first.name,
      );
      final bytes = await file.length();
      final durationMs = await AudioExtractor.probeDuration(file.path);
      if (!mounted) return;
      setState(() {
        _selectedVideoPath = file.path;
        _fileName = files.first.name;
        _fileSizeMb = '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
        _fileDurationMs = durationMs;
        _probeStatusMessage = '✅ Đã đọc media: ${_formatDuration(durationMs)}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _selectedVideoPath = null;
        _fileDurationMs = 0;
        _probeStatusMessage = '❌ Không đọc được media: $e';
      });
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim() ?? '';
    if (text.isNotEmpty) {
      setState(() {
        _urlController.text = text;
      });
      _probeUrl(text);
    } else {
      setState(() {
        _probeStatusMessage = 'Khay nhớ tạm trống';
      });
    }
  }

  Future<void> _probeUrl(String rawUrl) async {
    final clean = NetworkHeaderHelper.extractCleanUrl(rawUrl);
    if (clean.isEmpty || !NetworkHeaderHelper.isRemoteUrl(clean)) {
      setState(() {
        _probeStatusMessage =
            '⚠️ Vui lòng nhập link hợp lệ (http://, https:// hoặc link Bilibili/b23.tv)';
      });
      return;
    }

    setState(() {
      _urlController.text = clean;
      _isProbingUrl = true;
      _probeStatusMessage = '⏳ Đang kết nối và phân tích thông tin video...';
    });

    try {
      var durationMs = 0;
      var resolvedName = NetworkHeaderHelper.getSuggestedTitle(clean);

      if (BilibiliResolver.isBilibiliPageUrl(clean)) {
        final resolver = BilibiliResolver();
        final target = await resolver.resolveUrl(clean);
        final details = await resolver.getVideoDetails(
          target,
          _settings?.bilibiliSessData ?? '',
        );
        durationMs = details.durationSeconds * 1000;
        resolvedName = '${details.title}.mp4';

        // Tự động kiểm tra phụ đề Bilibili có sẵn
        try {
          final subs = await resolver.getSubtitles(
            details,
            _settings?.bilibiliSessData ?? '',
          );
          if (subs.isNotEmpty) {
            _probeStatusMessage =
                '✨ Video có sẵn phụ đề Bilibili! Bấm "Bắt đầu" để nạp và dịch ngay.';
          } else {
            _probeStatusMessage =
                '✅ Đã tìm thấy audio Bilibili. Sẵn sàng tạo sub!';
          }
        } catch (_) {
          _probeStatusMessage =
              '✅ Đã tìm thấy audio Bilibili. Sẵn sàng tạo sub!';
        }
      } else {
        durationMs = await AudioExtractor.probeDuration(clean);
        _probeStatusMessage = '✅ Link video online hợp lệ!';
      }

      if (!mounted) return;
      setState(() {
        _isProbingUrl = false;
        _selectedVideoPath = clean;
        _fileDurationMs = durationMs;
        _fileName = resolvedName.isNotEmpty ? resolvedName : 'video_online.mp4';
        _fileSizeMb = 'Trực tuyến';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProbingUrl = false;
        _selectedVideoPath = clean;
        _fileDurationMs = 0;
        _fileName = NetworkHeaderHelper.getSuggestedTitle(clean);
        _fileSizeMb = 'Trực tuyến';
        _probeStatusMessage = '✅ Đã nhận link (sẵn sàng tạo sub & xem)';
      });
    }
  }

  Future<void> _startProcessing() async {
    if (_selectedVideoPath == null || _settings == null) return;

    setState(() {
      _isProcessing = true;
      _cancelRequested = false;
      _currentProgress = const ProcessProgress(
        stage: ProcessStage.extractingAudio,
        message: 'Khởi động...',
      );
    });
    await WakelockPlus.enable();

    final pipeline = SubtitlingPipeline(
      apiKeys: _settings!.geminiApiKeys,
      translationEngine: _selectedEngine,
      stylePreset: _selectedStyle,
      customPrompt: _customPromptController.text,
      targetLanguage: _selectedTargetLang,
      geminiThreadCount: _settings!.geminiThreadCount,
    );
    _activePipeline = pipeline;

    final sub = pipeline.progressStream.listen((p) {
      if (mounted) {
        setState(() {
          _currentProgress = p;
        });
      }
    });

    try {
      final docDir = await getApplicationDocumentsDirectory();
      final baseName = _fileName.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), '');
      final outputDir = Directory(
        '${docDir.path}${Platform.pathSeparator}subtitles',
      );
      await outputDir.create(recursive: true);
      final historyId = DateTime.now().millisecondsSinceEpoch.toString();
      final safeBaseName = baseName.replaceAll(
        RegExp(r'[^a-zA-Z0-9._()\-\u00C0-\u024F\u1E00-\u1EFF]'),
        '_',
      );
      final outputBase =
          '${historyId}_${safeBaseName.isEmpty ? "sub" : safeBaseName}';
      final srtFile = File(
        '${outputDir.path}${Platform.pathSeparator}$outputBase.srt',
      );
      final documentFile = File(
        '${outputDir.path}${Platform.pathSeparator}$outputBase.capsub.json',
      );

      final resultDoc = await pipeline.execute(
        videoPath: _selectedVideoPath!,
        totalDurationMs: _fileDurationMs,
        sourceLanguage: _selectedSourceLang,
        outputSrtFile: srtFile,
      );

      final history = await HistoryRepository.getInstance();
      await documentFile.writeAsString(
        jsonEncode(resultDoc.toJson()),
        flush: true,
      );
      await history.addItem(
        HistoryItem(
          id: historyId,
          title: _fileName.isEmpty ? 'Video' : _fileName,
          videoPath: _selectedVideoPath!,
          srtPath: srtFile.path,
          documentPath: documentFile.path,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          durationMs: _fileDurationMs,
        ),
      );

      if (mounted) {
        widget.onProcessCompleted?.call(resultDoc, _selectedVideoPath!);
      }
    } catch (e) {
      if (mounted && !_cancelRequested) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Lỗi: $e')));
      }
    } finally {
      await sub.cancel();
      pipeline.dispose();
      await WakelockPlus.disable();
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _activePipeline = null;
        });
      }
    }
  }

  String _formatDuration(int durationMs) {
    final totalSeconds = durationMs ~/ 1000;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
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
            Icon(Icons.movie, color: AppColors.primaryEmerald, size: 26),
            SizedBox(width: 10),
            Text(
              'CapSub AI Studio',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white),
            onPressed: () {
              if (widget.onNavigateToSettings != null) {
                widget.onNavigateToSettings!();
              } else {
                Navigator.pushNamed(
                  context,
                  '/settings',
                ).then((_) => _loadSettings());
              }
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),

            // 1. TABS CHUYỂN ĐỔI: FILE MÁY / NHẬP LINK
            Container(
              decoration: BoxDecoration(
                color: AppColors.darkSurface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.cardBorder),
              ),
              padding: const EdgeInsets.all(4),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          _inputMode = 0;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: _inputMode == 0
                              ? AppColors.primaryEmerald
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.video_file,
                              size: 18,
                              color: _inputMode == 0
                                  ? Colors.black
                                  : Colors.grey,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '📁 File Trên Máy',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: _inputMode == 0
                                    ? Colors.black
                                    : Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          _inputMode = 1;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: _inputMode == 1
                              ? AppColors.primaryEmerald
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.link,
                              size: 18,
                              color: _inputMode == 1
                                  ? Colors.black
                                  : Colors.grey,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '🔗 Nhập Link Video',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: _inputMode == 1
                                    ? Colors.black
                                    : Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // 2. NỘI DUNG CHỌN NGUỒN VIDEO
            if (_inputMode == 0)
              // CARD CHỌN FILE TỪ THIẾT BỊ
              InkWell(
                onTap: _pickFile,
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: AppColors.darkSurface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.cardBorder),
                  ),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.video_file,
                        size: 48,
                        color: AppColors.primaryEmerald,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _selectedVideoPath != null
                            ? _fileName
                            : 'Chạm để chọn Video hoặc Âm thanh',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _selectedVideoPath != null
                            ? '💾 $_fileSizeMb'
                            : 'Hỗ trợ MP4, MKV, MOV, MP3, M4A',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              // CARD NHẬP LINK ONLINE
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: AppColors.darkSurface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(
                          Icons.link,
                          color: AppColors.primaryEmerald,
                          size: 22,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Dán Link Video Trực Tiếp',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Hỗ trợ link Bilibili, Douyin, MP4, M3U8...',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _urlController,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'https://.../video.mp4 hoặc link Bilibili',
                        hintStyle: const TextStyle(color: Colors.white38),
                        filled: true,
                        fillColor: const Color(0xFF1E202A),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: AppColors.cardBorder,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: AppColors.cardBorder,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: AppColors.primaryEmerald,
                          ),
                        ),
                        suffixIcon: _urlController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(
                                  Icons.clear,
                                  color: Colors.grey,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _urlController.clear();
                                    _selectedVideoPath = null;
                                    _probeStatusMessage = null;
                                  });
                                },
                              )
                            : null,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF2A2C38),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            onPressed: _pasteFromClipboard,
                            icon: const Icon(
                              Icons.paste,
                              color: AppColors.primaryEmerald,
                              size: 16,
                            ),
                            label: const Text(
                              'Dán Link',
                              style: TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primaryEmerald,
                              foregroundColor: Colors.black,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            onPressed: _isProbingUrl
                                ? null
                                : () => _probeUrl(_urlController.text),
                            icon: _isProbingUrl
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      color: Colors.black,
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(
                                    Icons.search,
                                    color: Colors.black,
                                    size: 16,
                                  ),
                            label: Text(
                              _isProbingUrl
                                  ? 'Đang kiểm tra...'
                                  : 'Kiểm Tra Link',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_probeStatusMessage != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        _probeStatusMessage!,
                        style: TextStyle(
                          fontSize: 12,
                          color: _selectedVideoPath != null
                              ? AppColors.primaryEmerald
                              : const Color(0xFFFFB74D),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 16),

            // 3. CẤU HÌNH NHẬN DIỆN GIỌNG NÓI & DỊCH THUẬT
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: AppColors.darkSurface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Cấu hình nhận diện giọng nói & Dịch thuật',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 14),

                  // 1. Ngôn ngữ nguồn
                  const Text(
                    '1. Ngôn ngữ nguồn trong video',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  DropdownButtonFormField<String>(
                    key: ValueKey(_selectedSourceLang),
                    initialValue: _selectedSourceLang,
                    dropdownColor: const Color(0xFF222430),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFF1E202A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'zh-CN',
                        child: Text('🇨🇳 Tiếng Trung (zh-CN)'),
                      ),
                      DropdownMenuItem(
                        value: 'en-US',
                        child: Text('🇺🇸 Tiếng Anh (en-US)'),
                      ),
                      DropdownMenuItem(
                        value: 'vi-VN',
                        child: Text('🇻🇳 Tiếng Việt (vi-VN)'),
                      ),
                      DropdownMenuItem(
                        value: 'ja-JP',
                        child: Text('🇯🇵 Tiếng Nhật (ja-JP)'),
                      ),
                      DropdownMenuItem(
                        value: 'ko-KR',
                        child: Text('🇰🇷 Tiếng Hàn (ko-KR)'),
                      ),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _selectedSourceLang = val);
                      }
                    },
                  ),
                  const SizedBox(height: 12),

                  // 2. Công cụ dịch thuật
                  const Text(
                    '2. Công cụ Dịch thuật',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  DropdownButtonFormField<String>(
                    key: ValueKey(_selectedEngine),
                    initialValue: _selectedEngine,
                    dropdownColor: const Color(0xFF222430),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFF1E202A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'capcut',
                        child: Text(
                          '⚡ CapCut Dịch Sẵn (Miễn phí 100% - Không cần Key)',
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'gemini-3.5-flash-lite',
                        child: Text(
                          '🚀 Gemini 3.5 Flash-Lite (RPD cao - Cần API Key)',
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'gemini-3.1-flash-lite',
                        child: Text(
                          '🌟 Gemini 3.1 Flash-Lite (Khuyên dùng - Cần API Key)',
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'none',
                        child: Text('🔒 Giữ Nguyên Tiếng Gốc (Không dịch)'),
                      ),
                    ],
                    onChanged: (val) {
                      if (val != null) setState(() => _selectedEngine = val);
                    },
                  ),
                  const SizedBox(height: 12),

                  // 3. Ngôn ngữ đích
                  const Text(
                    '3. Ngôn ngữ đích',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  DropdownButtonFormField<String>(
                    key: ValueKey(_selectedTargetLang),
                    initialValue: _selectedTargetLang,
                    dropdownColor: const Color(0xFF222430),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFF1E202A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'vi-VN',
                        child: Text('🇻🇳 Tiếng Việt (Mặc định)'),
                      ),
                      DropdownMenuItem(
                        value: 'en-US',
                        child: Text('🇺🇸 Tiếng Anh (English)'),
                      ),
                      DropdownMenuItem(
                        value: 'zh-CN',
                        child: Text('🇨🇳 Tiếng Trung (Chinese)'),
                      ),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _selectedTargetLang = val);
                      }
                    },
                  ),
                  const SizedBox(height: 12),

                  // 4. Phong cách dịch
                  const Text(
                    '4. Phong cách dịch thuật',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  DropdownButtonFormField<String>(
                    key: ValueKey(_selectedStyle),
                    initialValue: _selectedStyle,
                    dropdownColor: const Color(0xFF222430),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFF1E202A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'Zhihu',
                        child: Text('🎬 Phim Ngắn Zhihu (Vả mặt, kịch tính)'),
                      ),
                      DropdownMenuItem(
                        value: 'ThuanViet',
                        child: Text(
                          '📖 Thuần Việt Văn Học (Trau chuốt, mượt mà)',
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'CoTrang',
                        child: Text('⚔️ Cổ Trang Tiên Hiệp (Hán Việt chuẩn)'),
                      ),
                      DropdownMenuItem(
                        value: 'Auto',
                        child: Text('✨ Tự Động AI (Theo ngữ cảnh)'),
                      ),
                      DropdownMenuItem(
                        value: 'custom',
                        child: Text('✍️ Tự nhập Prompt tùy chỉnh...'),
                      ),
                    ],
                    onChanged: (val) {
                      if (val != null) setState(() => _selectedStyle = val);
                    },
                  ),

                  if (_selectedStyle == 'custom') ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: _customPromptController,
                      maxLines: 3,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'Nhập hướng dẫn dịch thuật cho AI...',
                        hintStyle: const TextStyle(color: Colors.white38),
                        filled: true,
                        fillColor: const Color(0xFF1E202A),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),

            // 4. NÚT BẮT ĐẦU TẠO PHỤ ĐỀ (MÀU XANH EMERALD #00E676)
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryEmerald,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 2,
              ),
              onPressed: (_selectedVideoPath != null && !_isProcessing)
                  ? _startProcessing
                  : null,
              child: _isProcessing
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.black,
                            strokeWidth: 2,
                          ),
                        ),
                        SizedBox(width: 12),
                        Text(
                          'Đang xử lý phụ đề...',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.black,
                          ),
                        ),
                      ],
                    )
                  : const Text(
                      '⚡ Bắt Đầu Tạo & Dịch Phụ Đề',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.black,
                      ),
                    ),
            ),


            const SizedBox(height: 24),
          ],
        ),
      ),
          if (_isProcessing)
            Positioned.fill(
              child: Container(
                color: Colors.black.withValues(alpha: 0.65),
                alignment: Alignment.bottomCenter,
                child: ProgressBottomSheet(
                  progress: _currentProgress,
                  onCancel: () {
                    _cancelRequested = true;
                    _activePipeline?.cancel();
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}
