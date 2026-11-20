import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../data/model/history_item.dart';
import '../../data/model/process_progress.dart';
import '../../data/model/subtitle_document.dart';
import '../../data/repository/history_repository.dart';
import '../../data/repository/settings_repository.dart';
import '../../domain/ai/ai_model_registry.dart';
import '../../domain/ai/translation_checkpoint_manager.dart';
import '../../domain/media/audio_extractor.dart';
import '../../domain/media/bilibili_resolver.dart';
import '../../domain/media/douyin_resolver.dart';
import '../../domain/media/media_storage.dart';
import '../../domain/media/multi_thread_downloader.dart';
import '../../domain/media/network_header_helper.dart';
import '../../domain/media/video_cache_manager.dart';
import '../../domain/pipeline/subtitling_pipeline.dart';
import '../../domain/service/foreground_service_manager.dart';
import '../theme/app_theme.dart';
import 'progress_bottom_sheet.dart';

class HomeScreen extends StatefulWidget {
  final VoidCallback? onNavigateToSettings;
  final void Function(SubtitleDocument doc, String videoPath, [String? title])?
  onProcessCompleted;
  final bool hideAppBar;

  const HomeScreen({
    super.key,
    this.onNavigateToSettings,
    this.onProcessCompleted,
    this.hideAppBar = false,
  });

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  SettingsRepository? _settings;
  TranslationCheckpointDraft? _pendingDraft;

  void loadOnlineVideo(String url, {String? title}) {
    setState(() {
      _urlController.text = url;
      if (title != null && title.isNotEmpty) {
        _fileName = title.endsWith('.mp4') ? title : '$title.mp4';
      }
      _selectedVideoPath = url;
      _probeStatusMessage = '⏳ Đang nạp video tập phim...';
    });
    _probeUrl(url, suggestedTitle: title);
  }

  String? _selectedVideoPath;
  String _fileName = '';
  int _fileDurationMs = 0;
  String _fileSizeMb = '';

  final _urlController = TextEditingController();
  bool _isProbingUrl = false;
  String? _probeStatusMessage;
  List<BilibiliPageInfo> _bilibiliPages = [];
  int _selectedBilibiliPage = 1;
  BilibiliVideoDetails? _bilibiliDetails;
  DouyinVideoDetails? _douyinDetails;
  String _selectedDouyinQuality = 'auto';
  String? _douyinCachedPath;
  bool _isDownloadingDouyin = false;
  double _douyinDownloadProgress = 0.0;
  String? _douyinDownloadMessage;

  String _selectedSourceLang = 'zh-CN';
  String _selectedEngine = 'gemini-3.1-flash-lite';
  String _selectedTargetLang = 'vi-VN';
  final _customPromptController = TextEditingController();

  bool _isProcessing = false;
  SubtitlingPipeline? _activePipeline;
  bool _cancelRequested = false;
  bool _downloadBilibiliVideo = false;
  String _selectedVideoQuality = '80';

  // Danh mục tuỳ chọn đồng bộ 100% bản gốc Android HomeScreen.kt
  static const _sourceLanguageOptions = [
    MapEntry('zh-CN', '🇨🇳 Tiếng Trung (zh-CN)'),
    MapEntry('en-US', '🇺🇸 Tiếng Anh (en-US)'),
    MapEntry('vi-VN', '🇻🇳 Tiếng Việt (vi-VN)'),
    MapEntry('ja-JP', '🇯🇵 Tiếng Nhật (ja-JP)'),
    MapEntry('ko-KR', '🇰🇷 Tiếng Hàn (ko-KR)'),
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_isProcessing) {
      _checkPendingDraft();
    }
  }

  Future<void> _loadSettings() async {
    final s = await SettingsRepository.getInstance();
    if (!mounted) return;
    setState(() {
      _settings = s;
      _selectedSourceLang = s.defaultSourceLanguage;
      _selectedEngine = s.selectedModel;
      _selectedTargetLang = s.targetLanguage;
      _customPromptController.text = s.geminiCustomPrompt;
      _downloadBilibiliVideo = s.downloadBilibiliVideo;
      _selectedVideoQuality = s.preferredVideoQuality;
    });
    await _checkPendingDraft();
  }

  Future<void> _checkPendingDraft() async {
    try {
      final draft = await TranslationCheckpointManager.getLatestDraft();
      if (mounted) {
        setState(() {
          _pendingDraft = draft;
        });
      }
    } catch (_) {}
  }

  void _resumeDraft(TranslationCheckpointDraft draft) {
    var duration = draft.durationMs;
    if (duration <= 0 && draft.sourceDocument.isNotEmpty) {
      duration = draft.sourceDocument.items.last.endMs;
    }
    if (duration <= 0) {
      duration = 60000;
    }

    setState(() {
      _selectedVideoPath = draft.videoPath;
      _fileName = draft.title;
      _fileDurationMs = duration;
      _selectedSourceLang = draft.sourceLanguage;
      _selectedTargetLang = draft.targetLanguage;
      if (NetworkHeaderHelper.isRemoteUrl(draft.videoPath)) {
        _urlController.text = draft.videoPath;
      } else {
        _urlController.clear();
      }
      _probeStatusMessage = '⚡ Đang tiếp tục phiên dịch dang dở (${draft.translatedCount}/${draft.totalItems} câu - ${draft.progressPercent}%)...';
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_isProcessing) {
        _startProcessing();
      }
    });
  }

  Future<void> _discardDraft(TranslationCheckpointDraft draft) async {
    await TranslationCheckpointManager.clearCheckpoint(draft.sessionKey);
    if (mounted) {
      setState(() {
        _pendingDraft = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Đã bỏ qua bản dịch dang dở.'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
        _urlController.clear();
        _selectedVideoPath = picked.location;
        _fileName = picked.name;
        _fileSizeMb = picked.sizeBytes > 0
            ? '${(picked.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB'
            : 'Không rõ';
        _fileDurationMs = durationMs;
        _resetOnlineMetadataFields();
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

  void _resetOnlineMetadataFields() {
    _bilibiliPages = [];
    _selectedBilibiliPage = 1;
    _bilibiliDetails = null;
    _douyinDetails = null;
    _selectedDouyinQuality = 'auto';
    _douyinCachedPath = null;
    _isDownloadingDouyin = false;
    _douyinDownloadProgress = 0.0;
    _douyinDownloadMessage = null;
  }

  Future<void> _downloadDouyinToCache() async {
    final details = _douyinDetails;
    if (details == null || _isDownloadingDouyin) return;

    setState(() {
      _isDownloadingDouyin = true;
      _douyinDownloadProgress = 0.02;
      _douyinDownloadMessage = 'Đang kết nối CDN Douyin...';
    });

    try {
      final existing = await VideoCacheManager.findCachedFile(
        url: details.canonicalUrl,
      );
      if (existing != null && await existing.exists()) {
        if (!mounted) return;
        setState(() {
          _isDownloadingDouyin = false;
          _douyinCachedPath = existing.path;
          _douyinDownloadProgress = 1.0;
          _douyinDownloadMessage = '✅ Video đã sẵn sàng offline!';
        });
        return;
      }

      final cachedFile = await VideoCacheManager.getCachedVideoFile(
        url: details.canonicalUrl,
      );
      final partFile = File('${cachedFile.path}.part');
      final freshDetails = await DouyinResolver().resolveVideo(
        details.canonicalUrl,
      );
      final urls = freshDetails.urlsForQuality(_selectedDouyinQuality);
      final headers = DouyinResolver.cdnHeaders();
      final concurrency = _settings?.downloadThreadCount ?? 4;

      var downloaded = false;
      Object? lastErr;
      for (final url in urls) {
        try {
          if (await partFile.exists()) await partFile.delete();
          await MultiThreadDownloader.downloadFile(
            url: url,
            outputFile: partFile,
            headers: headers,
            concurrency: concurrency,
            progressCallback: (pct, msg) {
              if (!mounted) return;
              setState(() {
                _douyinDownloadProgress = pct.clamp(0.02, 0.99);
                _douyinDownloadMessage = msg;
              });
            },
          );
          if (await partFile.exists() && await partFile.length() > 1024 * 20) {
            if (await cachedFile.exists()) await cachedFile.delete();
            try {
              await partFile.rename(cachedFile.path);
            } catch (_) {
              await partFile.copy(cachedFile.path);
              try {
                await partFile.delete();
              } catch (_) {}
            }
            downloaded = true;
            break;
          }
        } catch (e) {
          lastErr = e;
        }
      }

      if (!downloaded) {
        throw StateError('Không tải được video Douyin: $lastErr');
      }
      unawaited(VideoCacheManager.pruneCacheIfNeeded());

      final sizeMb = (await cachedFile.length() / (1024 * 1024))
          .toStringAsFixed(1);
      if (!mounted) return;
      setState(() {
        _isDownloadingDouyin = false;
        _douyinCachedPath = cachedFile.path;
        _douyinDownloadProgress = 1.0;
        _douyinDownloadMessage = '✅ Đã tải xong MP4 không logo ($sizeMb MB)!';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Đã tải xong video Douyin ($sizeMb MB)!'),
          backgroundColor: AppThemePalette.of(context).accentFor(AppTabId.studio),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloadingDouyin = false;
        _douyinDownloadProgress = 0.0;
        _douyinDownloadMessage = '❌ Lỗi tải video Douyin: $e';
      });
    }
  }

  Future<void> _probeUrl(String rawUrl, {String? suggestedTitle}) async {
    final clean = NetworkHeaderHelper.extractCleanUrl(rawUrl);
    if (clean.isEmpty || !NetworkHeaderHelper.isRemoteUrl(clean)) {
      setState(() {
        _probeStatusMessage =
            '⚠️ Vui lòng nhập đường link hợp lệ (http://, https://, Douyin v.douyin.com hoặc Bilibili/b23.tv)';
      });
      return;
    }

    final isDouyinLink = DouyinResolver.isDouyinPageUrl(clean);
    final isBiliLink = BilibiliResolver.isBilibiliPageUrl(clean);

    setState(() {
      _urlController.text = clean;
      _isProbingUrl = true;
      _probeStatusMessage = isDouyinLink
          ? '⏳ Đang phân giải link Douyin & lấy luồng MP4 không logo...'
          : '⏳ Đang kết nối và phân tích thông tin video...';
    });

    try {
      var durationMs = 0;
      var resolvedName = (suggestedTitle != null && suggestedTitle.isNotEmpty)
          ? (suggestedTitle.endsWith('.mp4')
                ? suggestedTitle
                : '$suggestedTitle.mp4')
          : NetworkHeaderHelper.getSuggestedTitle(clean);
      List<BilibiliPageInfo> pages = [];
      var selectedPage = 1;
      DouyinVideoDetails? resolvedDouyin;
      String? douyinCache;

      if (isBiliLink) {
        final resolver = BilibiliResolver();
        final target = await resolver.resolveUrl(clean);
        final details = await resolver.getVideoDetails(
          target,
          _settings?.bilibiliSessData ?? '',
        );
        _bilibiliDetails = details;
        _douyinDetails = null;
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
            if (_settings?.bilibiliSubtitleSource == 'capcut_always') {
              _probeStatusMessage =
                  '⚡ Video$partInfo có phụ đề Bilibili (${subs.first.languageName}) nhưng bạn đã cài đặt bỏ qua để luôn nhận diện qua CapCut STT.';
            } else {
              _probeStatusMessage =
                  '✨ Video$partInfo có sẵn phụ đề Bilibili (${subs.first.languageName})! (Chọn AI để dịch nhanh từ phụ đề, hoặc chọn CapCut để nghe lại âm thanh).';
            }
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
      } else if (isDouyinLink) {
        final resolver = DouyinResolver();
        final details = await resolver.resolveVideo(rawUrl);
        resolvedDouyin = details;
        _douyinDetails = details;
        _bilibiliDetails = null;
        durationMs = details.durationMs;
        if (durationMs <= 0 && details.playUrls.isNotEmpty) {
          try {
            durationMs = await AudioExtractor.probeDuration(
              details.playUrls.first,
            );
          } catch (_) {}
        }
        resolvedName = '${details.title}.mp4';
        final cached = await VideoCacheManager.findCachedFile(
          url: details.canonicalUrl,
        );
        douyinCache = cached?.path;
        final authorTag = details.author.isNotEmpty
            ? ' (@${details.author})'
            : '';
        _probeStatusMessage =
            '✅ Đã lấy video Douyin$authorTag không logo! Sẵn sàng tải MP4 hoặc tạo phụ đề.';
      } else {
        durationMs = await AudioExtractor.probeDuration(clean);
        _probeStatusMessage = '✅ Video online đã sẵn sàng!';
        _bilibiliDetails = null;
        _douyinDetails = null;
      }

      if (!mounted) return;
      final canonicalUrl =
          (_bilibiliDetails != null && _bilibiliDetails!.bvid.isNotEmpty)
          ? 'https://www.bilibili.com/video/${_bilibiliDetails!.bvid}?p=$selectedPage'
          : (resolvedDouyin != null ? resolvedDouyin.canonicalUrl : clean);

      final draftIdentifier = resolvedDouyin != null
          ? 'douyin_${resolvedDouyin.awemeId}'
          : canonicalUrl;

      String? draftMsg;
      try {
        final draftSessionKey = TranslationCheckpointManager.generateSessionKey(
          document: SubtitleDocument(),
          targetLanguage: _selectedTargetLang,
          identifier: draftIdentifier,
        );
        final draftForUrl = await TranslationCheckpointManager.loadDraft(
          draftSessionKey,
        );
        if (draftForUrl != null &&
            draftForUrl.totalItems > 0 &&
            draftForUrl.translatedCount < draftForUrl.totalItems) {
          draftMsg =
              '⚡ Đã lưu bản dịch dang dở (${draftForUrl.translatedCount}/${draftForUrl.totalItems} câu - ${draftForUrl.progressPercent}%)! Bấm bắt đầu để tiếp tục ngay mà không cần tải hay nhận diện lại.';
        }
      } catch (_) {}

      setState(() {
        _isProbingUrl = false;
        _selectedVideoPath = canonicalUrl;
        _urlController.text = canonicalUrl;
        _fileDurationMs = durationMs;
        _fileName = resolvedName.isNotEmpty ? resolvedName : 'video_online.mp4';
        _fileSizeMb = douyinCache != null ? 'Đã tải offline' : 'Trực tuyến';
        _bilibiliPages = pages;
        _selectedBilibiliPage = selectedPage;
        _douyinDetails = resolvedDouyin;
        _selectedDouyinQuality = 'auto';
        _douyinCachedPath = douyinCache;
        _douyinDownloadProgress = douyinCache != null ? 1.0 : 0.0;
        _douyinDownloadMessage = null;
        if (draftMsg != null) {
          _probeStatusMessage = draftMsg;
        }
      });
    } catch (e) {
      if (!mounted) return;
      if (isDouyinLink) {
        setState(() {
          _isProbingUrl = false;
          _selectedVideoPath = null;
          _fileDurationMs = 0;
          _fileName = '';
          _fileSizeMb = '';
          _resetOnlineMetadataFields();
          _probeStatusMessage = '⚠️ Không phân giải được link Douyin: $e';
        });
        return;
      }
      final defaultName = (suggestedTitle != null && suggestedTitle.isNotEmpty)
          ? (suggestedTitle.endsWith('.mp4')
                ? suggestedTitle
                : '$suggestedTitle.mp4')
          : NetworkHeaderHelper.getSuggestedTitle(clean);
      setState(() {
        _isProbingUrl = false;
        _selectedVideoPath = clean;
        _fileDurationMs = 0;
        _fileName = defaultName;
        _fileSizeMb = 'Trực tuyến';
        _resetOnlineMetadataFields();
        _probeStatusMessage = '✅ Đã nhận link (sẵn sàng tạo sub & xem)';
      });
    }
  }

  void _onSelectBilibiliPage(int pageIndex) async {
    if (_bilibiliPages.isEmpty) return;

    final selectedPageInfo = _bilibiliPages.firstWhere(
      (p) => p.page == pageIndex,
      orElse: () => _bilibiliPages.first,
    );

    final bvid = _bilibiliDetails?.bvid ??
        RegExp(r'BV[a-zA-Z0-9]{10}', caseSensitive: false)
            .firstMatch(_selectedVideoPath ?? '')
            ?.group(0) ??
        '';

    final canonicalUrl = bvid.isNotEmpty
        ? 'https://www.bilibili.com/video/$bvid?p=$pageIndex'
        : (_selectedVideoPath ?? '');

    final baseTitle = _bilibiliDetails?.rawTitle ??
        (_bilibiliDetails?.title ?? _fileName)
            .replaceAll(RegExp(r' - P\d+.*$'), '')
            .replaceAll(RegExp(r'\.mp4$'), '');
    final partName = selectedPageInfo.part.isNotEmpty
        ? selectedPageInfo.part
        : 'Phần $pageIndex';
    final fullTitle = '$baseTitle - P$pageIndex ($partName).mp4';

    // Cập nhật giao diện NGAY LẬP TỨC (0ms) - chip đổi màu ngay, thông tin cập nhật ngay
    setState(() {
      _selectedBilibiliPage = pageIndex;
      _selectedVideoPath = canonicalUrl;
      _urlController.text = canonicalUrl;
      _fileDurationMs = selectedPageInfo.durationSeconds * 1000;
      _fileName = fullTitle;
      _probeStatusMessage = '⏳ Đang kiểm tra phụ đề P$pageIndex...';
    });

    // Kiểm tra phụ đề Bilibili cho phân đoạn này trong nền
    if (_bilibiliDetails != null) {
      final partDetails = BilibiliVideoDetails(
        bvid: _bilibiliDetails!.bvid,
        aid: _bilibiliDetails!.aid,
        cid: selectedPageInfo.cid,
        title: '$baseTitle - P$pageIndex ($partName)',
        rawTitle: baseTitle,
        durationSeconds: selectedPageInfo.durationSeconds,
        pages: _bilibiliDetails!.pages,
        selectedPageIndex: pageIndex,
      );

      try {
        final resolver = BilibiliResolver();
        final subs = await resolver.getSubtitles(
          partDetails,
          _settings?.bilibiliSessData ?? '',
        );
        if (mounted && _selectedBilibiliPage == pageIndex) {
          setState(() {
            if (subs.isNotEmpty) {
              if (_settings?.bilibiliSubtitleSource == 'capcut_always') {
                _probeStatusMessage =
                    '⚡ Video (P$pageIndex) có phụ đề Bilibili (${subs.first.languageName}) nhưng bạn đã cài đặt bỏ qua để luôn nhận diện qua CapCut STT.';
              } else {
                _probeStatusMessage =
                    '✨ Video (P$pageIndex) có sẵn phụ đề Bilibili (${subs.first.languageName})! (Chọn AI để dịch nhanh từ phụ đề, hoặc chọn CapCut để nghe lại âm thanh).';
              }
            } else {
              _probeStatusMessage =
                  '✅ Đã chọn P$pageIndex: $partName (${_formatDuration(selectedPageInfo.durationSeconds * 1000)}). Sẵn sàng tạo sub!';
            }
          });
        }
      } on BilibiliSubtitleLoginRequiredException catch (error) {
        if (mounted && _selectedBilibiliPage == pageIndex) {
          setState(() => _probeStatusMessage = '⚠️ $error');
        }
      } catch (_) {
        if (mounted && _selectedBilibiliPage == pageIndex) {
          setState(() {
            _probeStatusMessage =
                '✅ Đã chọn P$pageIndex: $partName (${_formatDuration(selectedPageInfo.durationSeconds * 1000)}). Sẵn sàng tạo sub!';
          });
        }
      }
    }
  }

  Future<void> _startProcessing() async {
    if (_selectedVideoPath == null || _settings == null || _isProcessing) {
      return;
    }

    // Kiểm tra API Key tương ứng trước khi xử lý
    final provider = AiModelRegistry.detectProvider(_selectedEngine);
    if (provider == AiProvider.gemini && _settings!.geminiApiKeys.isEmpty) {
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

    if (provider == AiProvider.groq && _settings!.groqApiKeys.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Vui lòng nhập Groq API Key trong Cài đặt trước khi dùng Groq AI!',
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

    final customPrompt = _customPromptController.text.trim();
    final effectiveStyle = customPrompt.isNotEmpty ? 'custom' : 'Auto';

    _settings!
      ..defaultSourceLanguage = _selectedSourceLang
      ..selectedModel = _selectedEngine
      ..targetLanguage = _selectedTargetLang
      ..selectedStyle = effectiveStyle
      ..geminiCustomPrompt = customPrompt;

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
      groqApiKeys: _settings!.groqApiKeys,
      translationEngine: _selectedEngine,
      stylePreset: effectiveStyle,
      customPrompt: customPrompt,
      targetLanguage: _selectedTargetLang,
      geminiThreadCount: _settings!.geminiThreadCount,
      geminiBatchSize: _settings!.geminiBatchSize,
      groqThreadCount: _settings!.groqThreadCount,
      groqBatchSize: _settings!.groqBatchSize,
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
        title: _fileName,
        sourceLanguage: _selectedSourceLang,
        outputSrtFile: srtFile,
        downloadBilibiliVideo: _downloadBilibiliVideo,
        bilibiliQuality: _selectedVideoQuality,
        douyinQuality: _selectedDouyinQuality,
      );

      String finalPlayableVideo;
      if (pipeline.lastLocalVideoPath != null &&
          await File(pipeline.lastLocalVideoPath!).exists()) {
        finalPlayableVideo = pipeline.lastLocalVideoPath!;
      } else if (_downloadBilibiliVideo) {
        final cached = await VideoCacheManager.findCachedFile(
          url: _selectedVideoPath!,
          bvid: _bilibiliDetails?.bvid,
          bilibiliPage: _selectedBilibiliPage,
        );
        if (cached != null && await cached.exists()) {
          finalPlayableVideo = cached.path;
        } else {
          finalPlayableVideo = _selectedVideoPath!;
        }
      } else {
        // Người dùng không chọn tải về: Luôn mở xem online bằng link trực tuyến
        finalPlayableVideo = _selectedVideoPath!;
      }
      final history = await HistoryRepository.getInstance();
      await documentFile.writeAsString(
        jsonEncode(resultDoc.toJson()),
        flush: true,
      );
      var effectiveTitle = _fileName.replaceAll(RegExp(r'\.mp4$', caseSensitive: false), '').trim();
      if ((effectiveTitle.isEmpty || effectiveTitle == 'Video' || effectiveTitle.startsWith('Video Online')) &&
          pipeline.lastResolvedTitle != null &&
          pipeline.lastResolvedTitle!.isNotEmpty) {
        effectiveTitle = pipeline.lastResolvedTitle!;
      }
      if (effectiveTitle.isEmpty) effectiveTitle = 'Video';

      final coverToSave =
          _bilibiliDetails?.coverUrl ??
          _douyinDetails?.coverUrl ??
          pipeline.lastResolvedCover;

      await history.addItem(
        HistoryItem(
          id: historyId,
          title: effectiveTitle,
          originalTitle: effectiveTitle,
          videoPath: finalPlayableVideo,
          srtPath: srtFile.path,
          documentPath: documentFile.path,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          durationMs: _fileDurationMs,
          seriesCover: coverToSave,
        ),
      );

      // Đóng Bottom Sheet
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }

      final finishedSessionKey = TranslationCheckpointManager.generateSessionKey(
        document: SubtitleDocument(),
        targetLanguage: _selectedTargetLang,
        identifier: _douyinDetails != null
            ? 'douyin_${_douyinDetails!.awemeId}'
            : _selectedVideoPath!,
      );
      await TranslationCheckpointManager.clearCheckpoint(finishedSessionKey);
      await _checkPendingDraft();

      if (mounted) {
        widget.onProcessCompleted?.call(resultDoc, finalPlayableVideo, effectiveTitle);
      }
    } catch (e) {
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      await _checkPendingDraft();
      if (mounted && !_cancelRequested) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Lỗi: $e'),
            duration: const Duration(seconds: 10),
            action: _pendingDraft != null
                ? SnackBarAction(
                    label: 'Tiếp tục ngay',
                    textColor: AppThemePalette.of(context)
                        .accentFor(AppTabId.studio),
                    onPressed: () => _resumeDraft(_pendingDraft!),
                  )
                : null,
          ),
        );
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
        await _checkPendingDraft();
      }
    }
  }

  String _formatDuration(int durationMs) {
    final totalSeconds = durationMs ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _buildResumeDraftCard(TranslationCheckpointDraft draft) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.studio);
    final percent = draft.progressPercent;
    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        gradient: LinearGradient(
          colors: [
            accent.withValues(alpha: palette.isDark ? 0.18 : 0.10),
            palette.surface,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: accent.withValues(alpha: 0.42),
          width: 1.3,
        ),
        boxShadow: palette.cardShadows,
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.history_toggle_off,
                  color: accent,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Tiếp tục phiên dịch dang dở',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: palette.textPrimary,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.close, color: palette.textMuted, size: 20),
                tooltip: 'Bỏ qua',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => _discardDraft(draft),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            draft.title.isEmpty ? 'Video chưa hoàn thành' : draft.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: palette.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Đã dịch: ${draft.translatedCount}/${draft.totalItems} câu',
                style: TextStyle(
                  fontSize: 12,
                  color: palette.textSecondary,
                ),
              ),
              Text(
                '$percent%',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: draft.progress,
              backgroundColor: accent.withValues(alpha: 0.14),
              valueColor: AlwaysStoppedAnimation<Color>(accent),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: palette.onColor(accent),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                  ),
                  onPressed: () => _resumeDraft(draft),
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: const Text(
                    'Tiếp tục dịch ngay',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: palette.textSecondary,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                onPressed: () => _discardDraft(draft),
                child: const Text('Bỏ qua', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOfflineDownloadToggle() {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.studio);
    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _downloadBilibiliVideo
              ? accent.withValues(alpha: 0.55)
              : palette.border,
        ),
      ),
      child: SwitchListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
        title: Row(
          children: [
            Icon(
              Icons.download_for_offline,
              size: 16,
              color: accent,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Tải video về máy để xem offline',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: palette.textPrimary,
                ),
              ),
            ),
          ],
        ),
        subtitle: Text(
          'Lưu vào cache máy để phát mượt mà 100%, không bị xoay vòng hoặc giật lag mạng.',
          style: TextStyle(fontSize: 11, color: palette.textSecondary),
        ),
        value: _downloadBilibiliVideo,
        activeTrackColor: accent,
        onChanged: (val) {
          setState(() {
            _downloadBilibiliVideo = val;
            _settings?.downloadBilibiliVideo = val;
          });
        },
      ),
    );
  }

  Widget _buildDouyinDetailsCard(DouyinVideoDetails details) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.studio);
    final resText = (details.width > 0 && details.height > 0)
        ? '${details.width}x${details.height}'
        : 'MP4';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: accent.withValues(alpha: 0.3)),
              ),
              child: Text(
                '🎵 Douyin • Không watermark',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: accent,
                ),
              ),
            ),
            if (details.author.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: palette.surfaceAlt,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: palette.border),
                ),
                child: Text(
                  '@${details.author}',
                  style: TextStyle(fontSize: 11, color: palette.textSecondary),
                ),
              ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: palette.surfaceAlt,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: palette.border),
              ),
              child: Text(
                '$resText • ID: ${details.awemeId}',
                style: TextStyle(fontSize: 11, color: palette.textSecondary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _buildOfflineDownloadToggle(),
        if (details.qualityOptions.length > 1) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: palette.surfaceAlt,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: palette.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.high_quality,
                      size: 16,
                      color: accent,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Chất lượng MP4 Douyin:',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: palette.textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: Text(
                        'Tự động (Nét nhất)',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: _selectedDouyinQuality == 'auto'
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: _selectedDouyinQuality == 'auto'
                              ? palette.onColor(accent)
                              : palette.textSecondary,
                        ),
                      ),
                      selected: _selectedDouyinQuality == 'auto',
                      selectedColor: accent,
                      backgroundColor: palette.surface,
                      side: BorderSide(color: palette.border),
                      showCheckmark: false,
                      onSelected: (selected) {
                        if (selected) {
                          setState(() => _selectedDouyinQuality = 'auto');
                        }
                      },
                    ),
                    ...details.qualityOptions.take(4).map((q) {
                      final isSel = _selectedDouyinQuality == q.id;
                      return ChoiceChip(
                        label: Text(
                          q.label,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: isSel
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: isSel
                                ? palette.onColor(accent)
                                : palette.textSecondary,
                          ),
                        ),
                        selected: isSel,
                        selectedColor: accent,
                        backgroundColor: palette.surface,
                        side: BorderSide(color: palette.border),
                        showCheckmark: false,
                        onSelected: (selected) {
                          if (selected) {
                            setState(() => _selectedDouyinQuality = q.id);
                          }
                        },
                      );
                    }),
                  ],
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        if (_isDownloadingDouyin) ...[
          LinearProgressIndicator(
            value: _douyinDownloadProgress > 0 ? _douyinDownloadProgress : null,
            backgroundColor: palette.surfaceAlt,
            valueColor: AlwaysStoppedAnimation<Color>(accent),
            minHeight: 6,
          ),
          if (_douyinDownloadMessage != null) ...[
            const SizedBox(height: 6),
            Text(
              _douyinDownloadMessage!,
              style: TextStyle(fontSize: 11, color: palette.textSecondary),
            ),
          ],
        ] else
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: accent,
                    side: BorderSide(
                      color: accent.withValues(alpha: 0.6),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onPressed: _douyinCachedPath != null
                      ? () {
                          final cached = File(_douyinCachedPath!);
                          if (cached.existsSync()) {
                            SharePlus.instance.share(
                              ShareParams(
                                files: [XFile(cached.path)],
                                text: details.title,
                              ),
                            );
                          } else {
                            _downloadDouyinToCache();
                          }
                        }
                      : _downloadDouyinToCache,
                  icon: Icon(
                    _douyinCachedPath != null
                        ? Icons.ios_share
                        : Icons.download_rounded,
                    size: 16,
                  ),
                  label: Text(
                    _douyinCachedPath != null
                        ? 'Đã tải MP4 • Lưu / Chia sẻ tệp'
                        : 'Tải MP4 không logo về máy',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        if (!_isDownloadingDouyin && _douyinDownloadMessage != null) ...[
          const SizedBox(height: 6),
          Text(
            _douyinDownloadMessage!,
            style: TextStyle(
              fontSize: 11,
              color: _douyinDownloadMessage!.startsWith('❌')
                  ? const Color(0xFFD97706)
                  : accent,
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.studio);
    final secondary = palette.secondaryFor(AppTabId.studio);
    final onAccent = palette.onColor(accent);
    final hasFilePicked =
        _selectedVideoPath != null &&
        !NetworkHeaderHelper.isRemoteUrl(_selectedVideoPath!);
    final hasRemoteUrl =
        _selectedVideoPath != null &&
        NetworkHeaderHelper.isRemoteUrl(_selectedVideoPath!);
    final hasAnyMedia = hasFilePicked || hasRemoteUrl;
    final trimmedUrl = _urlController.text.trim();
    final hasPendingTypedUrl =
        trimmedUrl.isNotEmpty &&
        trimmedUrl != (_selectedVideoPath ?? '') &&
        NetworkHeaderHelper.isRemoteUrl(
          NetworkHeaderHelper.extractCleanUrl(trimmedUrl),
        );

    final scaffold = Scaffold(
      backgroundColor: Colors.transparent,
      appBar: widget.hideAppBar
          ? null
          : AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              title: Row(
                children: [
                  Icon(Icons.movie_rounded, color: accent, size: 26),
                  const SizedBox(width: 10),
                  Text(
                    'CapSub AI Studio',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: palette.textPrimary,
                    ),
                  ),
                ],
              ),
              actions: [
                IconButton(
                  icon: Icon(Icons.settings_rounded, color: palette.textPrimary),
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
        physics: const BouncingScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(
          16,
          4,
          16,
          palette.bottomContentPadding(extra: 18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // CARD KHÔI PHỤC PHIÊN DỊCH DANG DỞ
            if (_pendingDraft != null) ...[
              _buildResumeDraftCard(_pendingDraft!),
              const SizedBox(height: 14),
            ],

            // 1. HERO CARD HỢP NHẤT: CHỌN FILE HOẶC DÁN LINK VIDEO ONLINE
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [accent, secondary],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.34),
                    blurRadius: 22,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    right: -28,
                    top: -28,
                    child: Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.14),
                      ),
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      InkWell(
                        onTap: _pickFile,
                        borderRadius: BorderRadius.circular(16),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 9,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.22),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Text(
                                      hasRemoteUrl
                                          ? 'VIDEO ONLINE'
                                          : (hasFilePicked
                                                ? 'ĐÃ SẴN SÀNG'
                                                : 'DỰ ÁN MỚI'),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.8,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    hasAnyMedia
                                        ? _fileName
                                        : 'Chọn Video từ máy',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 17,
                                      color: Colors.white,
                                      height: 1.25,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    hasFilePicked
                                        ? '⏱️ ${_formatDuration(_fileDurationMs)}  •  💾 $_fileSizeMb'
                                        : (hasRemoteUrl
                                              ? '⏱️ ${_fileDurationMs > 0 ? _formatDuration(_fileDurationMs) : "Tự động"}  •  🌐 Trực tuyến'
                                              : 'Hỗ trợ MP4, MOV, âm thanh & SRT'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.white.withValues(alpha: 0.9),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 14),
                            Container(
                              width: 50,
                              height: 50,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(18),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.14),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Icon(
                                hasAnyMedia
                                    ? Icons.check_rounded
                                    : Icons.add_rounded,
                                color: accent,
                                size: 28,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              height: 44,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.28),
                                ),
                              ),
                              child: TextField(
                                controller: _urlController,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w500,
                                ),
                                cursorColor: Colors.white,
                                textInputAction: TextInputAction.search,
                                onSubmitted: (val) => _probeUrl(val),
                                onChanged: (val) {
                                  setState(() {
                                    _probeStatusMessage = null;
                                    if (val.trim().isEmpty && hasRemoteUrl) {
                                      _selectedVideoPath = null;
                                      _fileName = '';
                                      _fileDurationMs = 0;
                                      _fileSizeMb = '';
                                      _resetOnlineMetadataFields();
                                    }
                                  });
                                },
                                decoration: InputDecoration(
                                  isDense: true,
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(
                                    vertical: 11,
                                  ),
                                  prefixIcon: Icon(
                                    Icons.link_rounded,
                                    color: Colors.white.withValues(alpha: 0.9),
                                    size: 18,
                                  ),
                                  prefixIconConstraints: const BoxConstraints(
                                    minWidth: 38,
                                    minHeight: 38,
                                  ),
                                  hintText: 'Dán link Bilibili, Douyin...',
                                  hintStyle: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.85),
                                    fontSize: 12.5,
                                  ),
                                  suffixIcon: _urlController.text.isNotEmpty
                                      ? IconButton(
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(
                                            minWidth: 32,
                                            minHeight: 32,
                                          ),
                                          icon: Icon(
                                            Icons.close_rounded,
                                            size: 16,
                                            color: Colors.white.withValues(
                                              alpha: 0.9,
                                            ),
                                          ),
                                          onPressed: () {
                                            setState(() {
                                              _urlController.clear();
                                              if (hasRemoteUrl) {
                                                _selectedVideoPath = null;
                                                _fileName = '';
                                                _fileDurationMs = 0;
                                                _fileSizeMb = '';
                                                _resetOnlineMetadataFields();
                                              }
                                              _probeStatusMessage = null;
                                            });
                                          },
                                        )
                                      : null,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            height: 44,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: accent,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              onPressed: _isProbingUrl
                                  ? null
                                  : (hasPendingTypedUrl
                                        ? () => _probeUrl(_urlController.text)
                                        : _pasteFromClipboard),
                              child: _isProbingUrl
                                  ? SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        color: accent,
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Text(
                                      hasPendingTypedUrl ? 'Kiểm tra' : 'Dán',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w800,
                                        color: accent,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),

            if (_probeStatusMessage != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _selectedVideoPath != null
                        ? accent.withValues(alpha: 0.35)
                        : const Color(0xFFD97706).withValues(alpha: 0.45),
                  ),
                ),
                child: Text(
                  _probeStatusMessage!,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: _selectedVideoPath != null
                        ? accent
                        : const Color(0xFFD97706),
                  ),
                ),
              ),
            ],

            // Preview chi tiết khi video online đã sẵn sàng (tập Bilibili, chất lượng, Douyin)
            if (hasRemoteUrl &&
                (_bilibiliPages.length > 1 ||
                    _bilibiliDetails != null ||
                    _douyinDetails != null)) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: palette.border),
                  boxShadow: palette.cardShadows,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.check_circle,
                          color: accent,
                          size: 22,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _fileName,
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13.5,
                                  color: palette.textPrimary,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '⏱️ Thời lượng: ${_fileDurationMs > 0 ? _formatDuration(_fileDurationMs) : "Tự động"}  •  🌐 Stream trực tiếp',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: accent,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (_bilibiliPages.length > 1) ...[
                      Divider(
                        color: palette.border,
                        height: 20,
                      ),
                      Row(
                        children: [
                          Icon(
                            Icons.video_library,
                            size: 14,
                            color: accent,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Chọn tập / phần video (${_bilibiliPages.length} phần):',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: palette.textSecondary,
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
                                      ? onAccent
                                      : palette.textSecondary,
                                ),
                              ),
                              selected: isSelected,
                              selectedColor: accent,
                              backgroundColor: palette.surfaceAlt,
                              side: BorderSide(color: palette.border),
                              showCheckmark: false,
                              onSelected: (selected) {
                                if (selected &&
                                    page.page != _selectedBilibiliPage) {
                                  _onSelectBilibiliPage(page.page);
                                }
                              },
                            );
                          },
                        ),
                      ),
                    ],
                    if (_bilibiliDetails != null) ...[
                      const SizedBox(height: 10),
                      _buildOfflineDownloadToggle(),
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: palette.surfaceAlt,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: palette.border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.high_quality,
                                  size: 16,
                                  color: accent,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Chất lượng video:',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: palette.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: const [
                                MapEntry('80', '1080p (FHD)'),
                                MapEntry('64', '720p (HD - Mặc định)'),
                                MapEntry('32', '480p (Mạng yếu)'),
                                MapEntry('16', '360p (Siêu nhẹ)'),
                              ].map((q) {
                                final isSel = _selectedVideoQuality == q.key;
                                return ChoiceChip(
                                  label: Text(
                                    q.value,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: isSel
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                      color: isSel
                                          ? onAccent
                                          : palette.textSecondary,
                                    ),
                                  ),
                                  selected: isSel,
                                  selectedColor: accent,
                                  backgroundColor: palette.surface,
                                  side: BorderSide(color: palette.border),
                                  showCheckmark: false,
                                  onSelected: (selected) {
                                    if (selected) {
                                      setState(() {
                                        _selectedVideoQuality = q.key;
                                        _settings?.preferredVideoQuality =
                                            q.key;
                                      });
                                    }
                                  },
                                );
                              }).toList(),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '💡 Mạng yếu hoặc 3G/4G chập chờn? Chọn 480p hoặc 360p để xem online và tải video siêu mượt không lo giật lag.',
                              style: TextStyle(
                                fontSize: 11,
                                color: palette.textMuted,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (_douyinDetails != null) ...[
                      const SizedBox(height: 10),
                      _buildDouyinDetailsCard(_douyinDetails!),
                    ],
                  ],
                ),
              ),
            ],

            const SizedBox(height: 16),

            // 3. CẤU HÌNH NHẬN DIỆN & DỊCH THUẬT
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: palette.border),
                boxShadow: palette.cardShadows,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          'Cấu hình AI & Dịch thuật',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: palette.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            _selectedEngine == 'none'
                                ? 'Chỉ tạo sub gốc'
                                : 'AI Dịch Ngữ Cảnh',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.bold,
                              color: accent,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Ngôn ngữ gốc -> Dịch sang (kiểu A -> B gọn gàng)
                  Text(
                    _selectedEngine == 'none'
                        ? '🌐 Ngôn ngữ lời thoại gốc:'
                        : '🌐 Ngôn ngữ gốc ➔ Dịch sang:',
                    style: TextStyle(
                      fontSize: 13,
                      color: palette.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildLanguagePairRow(palette, accent),
                  const SizedBox(height: 14),

                  // Bộ máy Dịch thuật phụ đề
                  Text(
                    '🤖 Bộ máy Dịch thuật phụ đề:',
                    style: TextStyle(
                      fontSize: 13,
                      color: palette.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Tầng 1: Chọn Nền tảng (Provider Chips)
                  _buildEngineProviderChips(),
                  const SizedBox(height: 8),

                  // Tầng 2: Model selector tương ứng hoặc thông tin
                  _buildEngineModelSelector(),

                  // Ô nhập phong cách / ghi chú dịch (không bắt buộc — trống = AI tự nhận diện)
                  if (AiModelRegistry.isAiTranslationModel(_selectedEngine)) ...[
                    const SizedBox(height: 14),
                    Text(
                      '🎭 Phong cách dịch (AI):',
                      style: TextStyle(
                        fontSize: 13,
                        color: palette.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _customPromptController,
                      onChanged: (val) {
                        setState(() {});
                        final trimmed = val.trim();
                        _settings?.geminiCustomPrompt = trimmed;
                        _settings?.selectedStyle =
                            trimmed.isNotEmpty ? 'custom' : 'Auto';
                      },
                      minLines: 2,
                      maxLines: 3,
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontSize: 13,
                      ),
                      decoration: InputDecoration(
                        hintText:
                            'Có thể nhập phong cách/ghi chú (vd: cổ trang, tổng tài, hài hước...) hoặc để trống — AI sẽ tự nhận diện.',
                        hintStyle: TextStyle(
                          color: palette.textMuted,
                          fontSize: 12.5,
                          height: 1.35,
                        ),
                        filled: true,
                        fillColor: palette.surfaceAlt,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        suffixIcon: _customPromptController.text.isNotEmpty
                            ? IconButton(
                                tooltip: 'Xóa để AI tự nhận diện',
                                icon: Icon(
                                  Icons.close_rounded,
                                  size: 18,
                                  color: palette.textMuted,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _customPromptController.clear();
                                    _settings?.geminiCustomPrompt = '';
                                    _settings?.selectedStyle = 'Auto';
                                  });
                                },
                              )
                            : null,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: palette.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: palette.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: accent, width: 1.5),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 20),

            // 4. NÚT BẮT ĐẦU TẠO PHỤ ĐỀ
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: (_selectedVideoPath != null && !_isProcessing)
                    ? LinearGradient(colors: [accent, secondary])
                    : null,
                color: (_selectedVideoPath != null && !_isProcessing)
                    ? null
                    : accent.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(16),
                boxShadow: (_selectedVideoPath != null && !_isProcessing)
                    ? [
                        BoxShadow(
                          color: accent.withValues(alpha: 0.34),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ]
                    : null,
              ),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.transparent,
                    disabledForegroundColor: palette.textMuted,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  onPressed: (_selectedVideoPath != null && !_isProcessing)
                      ? _startProcessing
                      : null,
                  child: Text(
                    '🚀 BẮT ĐẦU TẠO PHỤ ĐỀ & DỊCH THUẬT',
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                      color: (_selectedVideoPath != null && !_isProcessing)
                          ? Colors.white
                          : palette.textMuted,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return widget.hideAppBar
        ? scaffold
        : AppTabBackdrop(tab: AppTabId.studio, child: scaffold);
  }

  String _shortLanguageLabel(String fullLabel) =>
      fullLabel.replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim();

  Widget _buildLanguagePairRow(AppThemePalette palette, Color accent) {
    return Row(
      children: [
        Expanded(
          child: _buildCompactLanguageDropdown(
            palette: palette,
            accent: accent,
            currentValue: _selectedSourceLang,
            options: _sourceLanguageOptions,
            onSelect: (code, label) {
              setState(() => _selectedSourceLang = code);
              _settings?.defaultSourceLanguage = code;
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: _selectedEngine == 'none'
                  ? palette.surfaceAlt
                  : accent.withValues(alpha: 0.14),
              shape: BoxShape.circle,
              border: Border.all(
                color: _selectedEngine == 'none'
                    ? palette.border
                    : accent.withValues(alpha: 0.3),
              ),
            ),
            child: Icon(
              Icons.arrow_forward_rounded,
              size: 16,
              color: _selectedEngine == 'none' ? palette.textMuted : accent,
            ),
          ),
        ),
        Expanded(
          child: _selectedEngine == 'none'
              ? Container(
                  height: 46,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: palette.surfaceAlt,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: palette.border),
                  ),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '🚫 Không dịch',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.textMuted,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              : _buildCompactLanguageDropdown(
                  palette: palette,
                  accent: accent,
                  currentValue: _selectedTargetLang,
                  options: _targetLanguageOptions,
                  onSelect: (code, label) {
                    setState(() => _selectedTargetLang = code);
                    _settings?.targetLanguage = code;
                    _settings?.targetLanguageLabel = label;
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildCompactLanguageDropdown({
    required AppThemePalette palette,
    required Color accent,
    required String currentValue,
    required List<MapEntry<String, String>> options,
    required void Function(String code, String label) onSelect,
  }) {
    final currentKey = options.any((e) => e.key == currentValue)
        ? currentValue
        : (options.any((e) => e.value == currentValue)
              ? options.firstWhere((e) => e.value == currentValue).key
              : (options.isNotEmpty ? options.first.key : null));

    return Container(
      height: 46,
      padding: const EdgeInsets.only(left: 10, right: 6),
      decoration: BoxDecoration(
        color: palette.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: currentKey,
          isExpanded: true,
          dropdownColor: palette.surface,
          icon: Icon(
            Icons.keyboard_arrow_down_rounded,
            color: accent,
            size: 20,
          ),
          selectedItemBuilder: (context) => options
              .map(
                (entry) => Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _shortLanguageLabel(entry.value),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              )
              .toList(),
          items: options
              .map(
                (entry) => DropdownMenuItem<String>(
                  value: entry.key,
                  child: Text(
                    entry.value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              )
              .toList(),
          onChanged: (val) {
            if (val != null) {
              final opt = options.firstWhere((e) => e.key == val);
              onSelect(val, opt.value);
            }
          },
        ),
      ),
    );
  }

  Widget _buildEngineProviderChips() {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.studio);
    final currentProvider = AiModelRegistry.detectProvider(_selectedEngine);
    return Row(
      children: [
        _buildProviderChip(
          label: 'CapCut',
          icon: Icons.bolt_rounded,
          color: accent,
          isSelected: currentProvider == AiProvider.capcut,
          onTap: () {
            setState(() => _selectedEngine = 'capcut');
            _settings?.selectedModel = 'capcut';
          },
        ),
        const SizedBox(width: 6),
        _buildProviderChip(
          label: 'Gemini',
          icon: Icons.auto_awesome,
          color: const Color(0xFF4285F4),
          isSelected: currentProvider == AiProvider.gemini,
          onTap: () {
            final model = _settings?.selectedGeminiModel.isNotEmpty == true
                ? _settings!.selectedGeminiModel
                : 'gemini-3.1-flash-lite';
            setState(() => _selectedEngine = model);
            _settings?.selectedModel = model;
          },
        ),
        const SizedBox(width: 6),
        _buildProviderChip(
          label: 'Groq AI',
          icon: Icons.electric_bolt_rounded,
          color: const Color(0xFFD97706),
          isSelected: currentProvider == AiProvider.groq,
          onTap: () {
            final model = _settings?.selectedGroqModel.isNotEmpty == true
                ? _settings!.selectedGroqModel
                : 'openai/gpt-oss-120b';
            setState(() => _selectedEngine = model);
            _settings?.selectedModel = model;
          },
        ),
        const SizedBox(width: 6),
        _buildProviderChip(
          label: 'Không dịch',
          icon: Icons.block_rounded,
          color: palette.textMuted,
          isSelected: currentProvider == AiProvider.none,
          onTap: () {
            setState(() => _selectedEngine = 'none');
            _settings?.selectedModel = 'none';
          },
        ),
      ],
    );
  }

  Widget _buildProviderChip({
    required String label,
    required IconData icon,
    required Color color,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final palette = AppThemePalette.of(context);
    return Expanded(
      flex: label.length > 8 ? 13 : 10,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? color.withValues(alpha: 0.14)
                : palette.surfaceAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? color : palette.border,
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 13.5,
                color: isSelected ? color : palette.textSecondary,
              ),
              const SizedBox(width: 3.5),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                      color: isSelected ? palette.textPrimary : palette.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEngineModelSelector() {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.studio);
    final currentProvider = AiModelRegistry.detectProvider(_selectedEngine);

    if (currentProvider == AiProvider.gemini) {
      final hasKey = _settings?.geminiApiKeys.isNotEmpty == true;
      return ValueListenableBuilder<int>(
        valueListenable: AiModelRegistry.customModelsRevision,
        builder: (context, _, _) {
          final geminiModels = AiModelRegistry.allGeminiModels;
          final normalizedSelected =
              AiModelRegistry.normalizeModelId(_selectedEngine);
          final safeValue =
              geminiModels.any((m) => m.id == normalizedSelected)
              ? normalizedSelected
              : geminiModels.first.id;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: palette.surfaceAlt,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFF4285F4).withValues(alpha: 0.45),
                  ),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: safeValue,
                    isExpanded: true,
                    dropdownColor: palette.surface,
                    icon: const Icon(
                      Icons.arrow_drop_down,
                      color: Color(0xFF4285F4),
                    ),
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    items: geminiModels.map((model) {
                      final icon = AiModelRegistry.isGemmaModel(model.id)
                          ? '💎'
                          : (model.isCustom ? '✨' : '🤖');
                      final suffix = model.isRecommended
                          ? ' (Khuyên dùng)'
                          : (model.id == 'gemini-3.5-flash-lite'
                                ? ' (RPD cao)'
                                : (model.isCustom ? ' (Tùy chỉnh)' : ''));
                      return DropdownMenuItem<String>(
                        value: model.id,
                        child: Text(
                          '$icon ${model.displayName}$suffix',
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                    onChanged: (code) {
                      if (code != null) {
                        setState(() => _selectedEngine = code);
                        _settings?.selectedModel = code;
                        _settings?.selectedGeminiModel = code;
                      }
                    },
                  ),
                ),
              ),
              if (!hasKey) ...[
                const SizedBox(height: 6),
                _buildMissingKeyAlert(
                  title: 'Chưa có Gemini API Key',
                  providerName: 'Gemini',
                ),
              ],
            ],
          );
        },
      );
    }

    if (currentProvider == AiProvider.groq) {
      final hasKey = _settings?.groqApiKeys.isNotEmpty == true;
      return ValueListenableBuilder<int>(
        valueListenable: AiModelRegistry.customModelsRevision,
        builder: (context, _, _) {
          final groqModels = AiModelRegistry.allGroqModels;
          final normalizedSelected =
              AiModelRegistry.normalizeModelId(_selectedEngine);
          final safeValue = groqModels.any((m) => m.id == normalizedSelected)
              ? normalizedSelected
              : groqModels.first.id;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: palette.surfaceAlt,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFFD97706).withValues(alpha: 0.45),
                  ),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: safeValue,
                    isExpanded: true,
                    dropdownColor: palette.surface,
                    icon: const Icon(
                      Icons.arrow_drop_down,
                      color: Color(0xFFD97706),
                    ),
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    items: groqModels.map((model) {
                      final icon = model.id.contains('qwen')
                          ? '🇨🇳'
                          : (model.isCustom ? '✨' : '⚡');
                      return DropdownMenuItem<String>(
                        value: model.id,
                        child: Text(
                          '$icon ${model.displayName}',
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                    onChanged: (code) {
                      if (code != null) {
                        setState(() => _selectedEngine = code);
                        _settings?.selectedModel = code;
                        _settings?.selectedGroqModel = code;
                      }
                    },
                  ),
                ),
              ),
              if (!hasKey) ...[
                const SizedBox(height: 6),
                _buildMissingKeyAlert(
                  title: 'Chưa có Groq API Key',
                  providerName: 'Groq',
                ),
              ],
            ],
          );
        },
      );
    }

    if (currentProvider == AiProvider.capcut) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: palette.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: palette.border),
        ),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, size: 16, color: accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Dịch trực tiếp qua CapCut Cloud (Miễn phí 100% - Không cần API Key)',
                style: TextStyle(color: palette.textSecondary, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: palette.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: palette.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Giữ nguyên phụ đề tiếng gốc, không qua bước dịch thuật',
              style: TextStyle(color: palette.textMuted, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMissingKeyAlert({
    required String title,
    required String providerName,
  }) {
    final palette = AppThemePalette.of(context);
    const warnColor = Color(0xFFD97706);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: warnColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: warnColor.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, size: 16, color: warnColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$title! Vui lòng cấu hình key.',
              style: TextStyle(
                color: palette.isDark ? Colors.amber : warnColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          InkWell(
            onTap: () {
              if (widget.onNavigateToSettings != null) {
                widget.onNavigateToSettings!();
              } else {
                Navigator.pushNamed(context, '/settings')
                    .then((_) => _loadSettings());
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: warnColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Cài đặt',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dropdown custom theme-aware đồng bộ giao diện sáng/tối
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
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.studio);

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
          style: TextStyle(
            fontSize: 13,
            color: palette.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: palette.surfaceAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.border),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: currentKey,
              isExpanded: true,
              dropdownColor: palette.surface,
              icon: Icon(Icons.keyboard_arrow_down_rounded, color: accent),
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
              items: options.map((entry) {
                return DropdownMenuItem<String>(
                  value: entry.key,
                  child: Text(
                    entry.value,
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 13.5,
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
