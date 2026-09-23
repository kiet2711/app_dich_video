import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../data/model/history_item.dart';
import '../../data/model/process_progress.dart';
import '../../data/model/subtitle_document.dart';
import '../../data/repository/history_repository.dart';
import '../../data/repository/settings_repository.dart';
import '../../domain/media/audio_extractor.dart';
import '../../domain/media/bilibili_resolver.dart';
import '../../domain/media/media_storage.dart';
import '../../domain/media/network_header_helper.dart';
import '../../domain/pipeline/subtitling_pipeline.dart';
import '../../domain/service/foreground_service_manager.dart';
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
  List<BilibiliPageInfo> _bilibiliPages = [];
  int _selectedBilibiliPage = 1;

  String _selectedSourceLang = 'zh-CN';
  String _selectedEngine = 'capcut';
  String _selectedTargetLang = 'vi-VN';
  String _selectedStyle = 'Zhihu';
  final _customPromptController = TextEditingController();

  bool _isProcessing = false;
  SubtitlingPipeline? _activePipeline;
  bool _cancelRequested = false;

  // Danh mục tuỳ chọn đồng bộ 100% bản gốc Android HomeScreen.kt
  static const _sourceLanguageOptions = [
    MapEntry('zh-CN', '🇨🇳 Tiếng Trung (zh-CN)'),
    MapEntry('en-US', '🇺🇸 Tiếng Anh (en-US)'),
    MapEntry('vi-VN', '🇻🇳 Tiếng Việt (vi-VN)'),
    MapEntry('ja-JP', '🇯🇵 Tiếng Nhật (ja-JP)'),
    MapEntry('ko-KR', '🇰🇷 Tiếng Hàn (ko-KR)'),
  ];

  static const _engineOptions = [
    MapEntry('capcut', '⚡ CapCut Dịch Sẵn (Miễn phí 100% - Không cần Key)'),
    MapEntry(
      'gemini-3.5-flash-lite',
      '🤖 Gemini 3.5 Flash-Lite (RPD cao - Cần API Key)',
    ),
    MapEntry(
      'gemini-3.1-flash-lite',
      '🤖 Gemini 3.1 Flash-Lite (Khuyên dùng - Cần API Key)',
    ),
    MapEntry('none', '🚫 Giữ Nguyên Tiếng Gốc (Không dịch)'),
  ];

  static const _targetLanguageOptions = [
    MapEntry('vi-VN', '🇻🇳 Tiếng Việt (Mặc định)'),
    MapEntry('en-US', '🇺🇸 Tiếng Anh (English)'),
    MapEntry('zh-CN', '🇨🇳 Tiếng Trung (Giản thể)'),
    MapEntry('ja-JP', '🇯🇵 Tiếng Nhật (日本語)'),
    MapEntry('ko-KR', '🇰🇷 Tiếng Hàn (한국어)'),
    MapEntry('fr-FR', '🇫🇷 Tiếng Pháp (Français)'),
    MapEntry('ru-RU', '🇷🇺 Tiếng Nga (Русский)'),
    MapEntry('es-ES', '🇪🇸 Tiếng Tây Ban Nha (Español)'),
    MapEntry('th-TH', '🇹🇭 Tiếng Thái (ไทย)'),
  ];

  static const _styleOptions = [
    MapEntry('Zhihu', '🎬 Phim Ngắn Zhihu (Vả mặt, kịch tính)'),
    MapEntry('ThuanViet', '📖 Thuần Việt Văn Học (Trau chuốt, mượt mà)'),
    MapEntry('CoTrang', '⚔️ Cổ Trang Tiên Hiệp (Hán Việt chuẩn)'),
    MapEntry('Auto', '✨ Tự Động AI (Theo ngữ cảnh)'),
    MapEntry('custom', '✍️ Tự nhập Prompt tùy chỉnh...'),
  ];

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
    unawaited(ForegroundServiceManager.stop());
    _urlController.dispose();
    _customPromptController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    try {
      final picked = await MediaStorage.pickPersistentMedia(
        context: context,
        videoOnly: false,
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
      if (picked == null) {
        if (mounted) setState(() => _probeStatusMessage = null);
        return;
      }
      if (mounted) {
        setState(() => _probeStatusMessage = '⏳ Đang đọc media...');
      }
      final durationMs = await AudioExtractor.probeDuration(picked.location);
      if (!mounted) return;
      setState(() {
        _selectedVideoPath = picked.location;
        _fileName = picked.name;
        _fileSizeMb = picked.sizeBytes > 0
            ? '${(picked.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB'
            : 'Không rõ';
        _fileDurationMs = durationMs;
        _bilibiliPages = [];
        _selectedBilibiliPage = 1;
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
        _probeStatusMessage = '⚠️ Vui lòng nhập đường link hợp lệ (http://, https:// hoặc link Bilibili/b23.tv)';
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
      List<BilibiliPageInfo> pages = [];
      var selectedPage = 1;

      if (BilibiliResolver.isBilibiliPageUrl(clean)) {
        final resolver = BilibiliResolver();
        final target = await resolver.resolveUrl(clean);
        final details = await resolver.getVideoDetails(
          target,
          _settings?.bilibiliSessData ?? '',
        );
        durationMs = details.durationSeconds * 1000;
        resolvedName = '${details.title}.mp4';
        pages = details.pages;
        selectedPage = details.selectedPageIndex;

        // Tự động kiểm tra phụ đề Bilibili có sẵn
        try {
          final subs = await resolver.getSubtitles(
            details,
            _settings?.bilibiliSessData ?? '',
          );
          if (subs.isNotEmpty) {
            final partInfo = pages.length > 1 ? ' (P$selectedPage)' : '';
            _probeStatusMessage =
                '✨ Video$partInfo có sẵn phụ đề Bilibili (${subs.first.languageName})! Bấm "Bắt đầu" để nạp và dịch ngay.';
          } else {
            _probeStatusMessage =
                '✅ Đã tìm thấy audio DASH Bilibili (~30-50MB). Sẵn sàng tạo sub!';
          }
        } on BilibiliSubtitleLoginRequiredException catch (error) {
          _probeStatusMessage = '⚠️ $error';
        } catch (_) {
          _probeStatusMessage =
              '✅ Đã tìm thấy audio DASH Bilibili (~30-50MB). Sẵn sàng tạo sub!';
        }
      } else {
        durationMs = await AudioExtractor.probeDuration(clean);
        _probeStatusMessage = '✅ Video online đã sẵn sàng!';
      }

      if (!mounted) return;
      setState(() {
        _isProbingUrl = false;
        _selectedVideoPath = clean;
        _fileDurationMs = durationMs;
        _fileName = resolvedName.isNotEmpty ? resolvedName : 'video_online.mp4';
        _fileSizeMb = 'Trực tuyến';
        _bilibiliPages = pages;
        _selectedBilibiliPage = selectedPage;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProbingUrl = false;
        _selectedVideoPath = clean;
        _fileDurationMs = 0;
        _fileName = NetworkHeaderHelper.getSuggestedTitle(clean);
        _fileSizeMb = 'Trực tuyến';
        _bilibiliPages = [];
        _selectedBilibiliPage = 1;
        _probeStatusMessage = '✅ Đã nhận link (sẵn sàng tạo sub & xem)';
      });
    }
  }

  void _onSelectBilibiliPage(int pageIndex) {
    if (_selectedVideoPath == null || _bilibiliPages.isEmpty) return;
    var url = _selectedVideoPath!;
    final uri = Uri.tryParse(url);
    if (uri != null) {
      final params = Map<String, String>.from(uri.queryParameters);
      params['p'] = pageIndex.toString();
      final newUri = uri.replace(queryParameters: params);
      url = newUri.toString();
    } else {
      url = url.contains('?') ? '$url&p=$pageIndex' : '$url?p=$pageIndex';
    }
    _probeUrl(url);
  }

  Future<void> _startProcessing() async {
    if (_selectedVideoPath == null || _settings == null || _isProcessing) {
      return;
    }

    // Kiểm tra Gemini API Key trước khi xử lý giống bản gốc Android
    if (_selectedEngine.startsWith('gemini') &&
        _settings!.geminiApiKeys.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Vui lòng nhập Gemini API Key trong Cài đặt trước khi dùng Gemini!',
          ),
          duration: Duration(seconds: 3),
        ),
      );
      if (widget.onNavigateToSettings != null) {
        widget.onNavigateToSettings!();
      } else {
        Navigator.pushNamed(context, '/settings').then((_) => _loadSettings());
      }
      return;
    }

    _settings!
      ..defaultSourceLanguage = _selectedSourceLang
      ..selectedModel = _selectedEngine
      ..targetLanguage = _selectedTargetLang
      ..selectedStyle = _selectedStyle;
    if (_selectedStyle == 'custom') {
      _settings!.geminiCustomPrompt = _customPromptController.text.trim();
    }

    setState(() {
      _isProcessing = true;
      _cancelRequested = false;
    });
    await WakelockPlus.enable();
    await ForegroundServiceManager.start(
      title: 'CapSub AI - Tạo phụ đề',
      message: 'Đang chuẩn bị xử lý video...',
      progress: 5,
      maxProgress: 100,
    );
    if (!mounted) return;

    final pipeline = SubtitlingPipeline(
      apiKeys: _settings!.geminiApiKeys,
      translationEngine: _selectedEngine,
      stylePreset: _selectedStyle,
      customPrompt: _selectedStyle == 'custom'
          ? _customPromptController.text.trim()
          : '',
      targetLanguage: _selectedTargetLang,
      geminiThreadCount: _settings!.geminiThreadCount,
    );
    _activePipeline = pipeline;

    final progressNotifier = ValueNotifier<ProcessProgress>(
      const ProcessProgress(
        stage: ProcessStage.extractingAudio,
        progress: 0.05,
        message: 'Đang chuẩn bị xử lý...',
      ),
    );

    final sub = pipeline.progressStream.listen((p) {
      progressNotifier.value = p;
      final pct = (p.progress * 100).toInt().clamp(0, 100);
      unawaited(
        ForegroundServiceManager.update(
          message: p.message,
          progress: pct,
          maxProgress: 100,
        ),
      );
    });

    // Mở ModalBottomSheet toàn màn hình che BottomNavigationBar giống Compose ModalBottomSheet bản gốc
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return PopScope(
          canPop: false,
          child: ValueListenableBuilder<ProcessProgress>(
            valueListenable: progressNotifier,
            builder: (ctx, progress, _) {
              return ProgressBottomSheet(
                progress: progress,
                onCancel: () {
                  _cancelRequested = true;
                  _activePipeline?.cancel();
                  unawaited(ForegroundServiceManager.stop());
                  if (Navigator.of(
                    sheetContext,
                    rootNavigator: true,
                  ).canPop()) {
                    Navigator.of(sheetContext, rootNavigator: true).pop();
                  }
                },
              );
            },
          ),
        );
      },
    );

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

      // Đóng Bottom Sheet
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }

      if (mounted) {
        widget.onProcessCompleted?.call(resultDoc, _selectedVideoPath!);
      }
    } catch (e) {
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (mounted && !_cancelRequested) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Lỗi: $e')));
      }
    } finally {
      await sub.cancel();
      pipeline.dispose();
      progressNotifier.dispose();
      await WakelockPlus.disable();
      await ForegroundServiceManager.stop();
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
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
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
            tooltip: 'Cài đặt',
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
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),

            // 1. NGUỒN VIDEO: TABS CHUYỂN ĐỔI (FILE MÁY / NHẬP LINK)
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
                          if (_selectedVideoPath != null &&
                              NetworkHeaderHelper.isRemoteUrl(
                                _selectedVideoPath!,
                              )) {
                            _selectedVideoPath = null;
                            _fileName = '';
                            _fileDurationMs = 0;
                            _fileSizeMb = '';
                            _probeStatusMessage = null;
                          }
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
                          if (_selectedVideoPath != null &&
                              !NetworkHeaderHelper.isRemoteUrl(
                                _selectedVideoPath!,
                              )) {
                            _selectedVideoPath = null;
                            _fileName = '';
                            _fileDurationMs = 0;
                            _fileSizeMb = '';
                            _probeStatusMessage = null;
                          }
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
                            ? '⏱️ ${_formatDuration(_fileDurationMs)}  •  💾 $_fileSizeMb'
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
              // CARD NHẬP LINK VIDEO ONLINE
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
                      'Hỗ trợ link Bilibili, Douyin, MP4, M3U8... (Tự động vượt chặn 403)',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _urlController,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      onChanged: (val) {
                        setState(() {
                          _probeStatusMessage = null;
                        });
                      },
                      decoration: InputDecoration(
                        hintText: 'https://.../video.mp4',
                        hintStyle: const TextStyle(
                          color: Colors.grey,
                          fontSize: 13,
                        ),
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
                                    _fileName = '';
                                    _fileDurationMs = 0;
                                    _fileSizeMb = '';
                                    _bilibiliPages = [];
                                    _selectedBilibiliPage = 1;
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
                              backgroundColor: const Color(0xFF2A2A2A),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: _pasteFromClipboard,
                            icon: const Icon(
                              Icons.content_paste,
                              color: AppColors.primaryEmerald,
                              size: 16,
                            ),
                            label: const Text(
                              'Dán Link',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primaryEmerald,
                              foregroundColor: Colors.black,
                              disabledBackgroundColor: AppColors.primaryEmerald
                                  .withValues(alpha: 0.5),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed:
                                (_urlController.text.isNotEmpty &&
                                    !_isProbingUrl)
                                ? () => _probeUrl(_urlController.text)
                                : null,
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
                                color: Colors.black,
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

                    // Preview khi video online đã sẵn sàng giống bản gốc Android
                    if (_selectedVideoPath != null &&
                        NetworkHeaderHelper.isRemoteUrl(
                          _selectedVideoPath!,
                        )) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E2E24),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: AppColors.primaryEmerald.withValues(
                              alpha: 0.5,
                            ),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.check_circle,
                                  color: AppColors.primaryEmerald,
                                  size: 28,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _fileName,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                          color: Colors.white,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '⏱️ Thời lượng: ${_fileDurationMs > 0 ? _formatDuration(_fileDurationMs) : "Tự động"}  •  🌐 Stream trực tiếp',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: AppColors.primaryEmerald,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            if (_bilibiliPages.length > 1) ...[
                              const Divider(
                                color: Color(0xFF2C3E32),
                                height: 20,
                              ),
                              Row(
                                children: [
                                  const Icon(
                                    Icons.video_library,
                                    size: 14,
                                    color: AppColors.primaryEmerald,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Chọn tập / phần video (${_bilibiliPages.length} phần):',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white70,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                height: 36,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: _bilibiliPages.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(width: 6),
                                  itemBuilder: (context, index) {
                                    final page = _bilibiliPages[index];
                                    final isSelected =
                                        page.page == _selectedBilibiliPage;
                                    final partName = page.part.isNotEmpty
                                        ? page.part
                                        : 'Phần ${page.page}';
                                    return ChoiceChip(
                                      label: Text(
                                        'P${page.page}: $partName',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: isSelected
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                          color: isSelected
                                              ? Colors.black
                                              : Colors.white70,
                                        ),
                                      ),
                                      selected: isSelected,
                                      selectedColor: AppColors.primaryEmerald,
                                      backgroundColor: const Color(0xFF1E202A),
                                      onSelected: (selected) {
                                        if (selected &&
                                            page.page !=
                                                _selectedBilibiliPage) {
                                          _onSelectBilibiliPage(page.page);
                                        }
                                      },
                                    );
                                  },
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),

            const SizedBox(height: 24),

            // 3. CẤU HÌNH NHẬN DIỆN & DỊCH THUẬT (ĐỒNG BỘ 100% BẢN GỐC ANDROID)
            const Text(
              'CẤU HÌNH NHẬN DIỆN & DỊCH THUẬT',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
                letterSpacing: 1.0,
              ),
            ),
            const SizedBox(height: 12),

            // Ngôn ngữ lời thoại gốc
            SettingDropdown(
              label: '🌐 Ngôn ngữ lời thoại gốc:',
              currentValue: _selectedSourceLang,
              options: _sourceLanguageOptions,
              onSelect: (code, label) {
                setState(() => _selectedSourceLang = code);
                _settings?.defaultSourceLanguage = code;
              },
            ),
            const SizedBox(height: 16),

            // Bộ máy Dịch thuật phụ đề
            SettingDropdown(
              label: '🤖 Bộ máy Dịch thuật phụ đề:',
              currentValue: _selectedEngine,
              options: _engineOptions,
              onSelect: (code, label) {
                setState(() => _selectedEngine = code);
                _settings?.selectedModel = code;
              },
            ),

            // Ngôn ngữ dịch sang (Ngôn ngữ đích - chỉ hiện khi không chọn "none")
            if (_selectedEngine != 'none') ...[
              const SizedBox(height: 16),
              SettingDropdown(
                label: '🎯 Dịch sang ngôn ngữ:',
                currentValue: _selectedTargetLang,
                options: _targetLanguageOptions,
                onSelect: (code, label) {
                  setState(() => _selectedTargetLang = code);
                  _settings?.targetLanguage = code;
                  _settings?.targetLanguageLabel = label;
                },
              ),
            ],

            // Phong cách dịch ngữ cảnh (Gemini - chỉ hiện khi chọn gemini)
            if (_selectedEngine.startsWith('gemini')) ...[
              const SizedBox(height: 16),
              SettingDropdown(
                label: '🎭 Phong cách dịch ngữ cảnh (Gemini):',
                currentValue: _selectedStyle,
                options: _styleOptions,
                onSelect: (code, label) {
                  setState(() => _selectedStyle = code);
                  _settings?.selectedStyle = code;
                },
              ),

              if (_selectedStyle == 'custom') ...[
                const SizedBox(height: 10),
                TextField(
                  controller: _customPromptController,
                  onChanged: (val) {
                    _settings?.geminiCustomPrompt = val;
                  },
                  maxLines: 4,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Nhập hướng dẫn prompt dịch cho Gemini (vd: Dịch theo lối cổ trang, xưng hô huynh/muội, giữ câu ngắn...)',
                    hintStyle: const TextStyle(
                      color: Colors.grey,
                      fontSize: 13,
                    ),
                    filled: true,
                    fillColor: AppColors.darkSurface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFF333544)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFF333544)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(
                        color: AppColors.primaryEmerald,
                      ),
                    ),
                  ),
                ),
              ],
            ],

            const SizedBox(height: 36),

            // 4. NÚT BẮT ĐẦU TẠO PHỤ ĐỀ (ĐỒNG BỘ 100% BẢN GỐC ANDROID)
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryEmerald,
                  foregroundColor: Colors.black,
                  disabledBackgroundColor: AppColors.primaryEmerald.withValues(
                    alpha: 0.3,
                  ),
                  disabledForegroundColor: Colors.black38,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                onPressed: (_selectedVideoPath != null && !_isProcessing)
                    ? _startProcessing
                    : null,
                child: const Text(
                  '🚀 BẮT ĐẦU TẠO PHỤ ĐỀ & DỊCH THUẬT',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Colors.black,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }
}

/// Dropdown custom đồng bộ 100% style của SettingDropdown.kt trên Jetpack Compose
class SettingDropdown extends StatelessWidget {
  final String label;
  final String currentValue;
  final List<MapEntry<String, String>> options;
  final void Function(String code, String label) onSelect;

  const SettingDropdown({
    super.key,
    required this.label,
    required this.currentValue,
    required this.options,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    // Xác định key hợp lệ
    final currentKey = options.any((e) => e.key == currentValue)
        ? currentValue
        : (options.any((e) => e.value == currentValue)
              ? options.firstWhere((e) => e.value == currentValue).key
              : (options.isNotEmpty ? options.first.key : null));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            color: Color(0xFFC0C0C0),
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: AppColors.darkSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.cardBorder),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: currentKey,
              isExpanded: true,
              dropdownColor: AppColors.darkSurface,
              icon: const Icon(Icons.arrow_drop_down, color: Colors.grey),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
              items: options.map((entry) {
                return DropdownMenuItem<String>(
                  value: entry.key,
                  child: Text(
                    entry.value,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }).toList(),
              onChanged: (val) {
                if (val != null) {
                  final opt = options.firstWhere((e) => e.key == val);
                  onSelect(val, opt.value);
                }
              },
            ),
          ),
        ),
      ],
    );
  }
}
