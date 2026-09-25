import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../domain/media/audio_extractor.dart';
import '../../domain/media/media_storage.dart';
import '../../domain/media/network_header_helper.dart';
import '../../domain/media/video_cache_manager.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../domain/ai/smart_ai_translator.dart';
import '../../data/model/subtitle_document.dart';
import '../../data/model/voice_model.dart';
import '../../data/repository/history_repository.dart';
import '../../data/repository/settings_repository.dart';
import '../../domain/service/foreground_service_manager.dart';
import '../../domain/tts/tts_generation_manager.dart';
import '../player/video_player_screen.dart';
import '../settings/settings_screen.dart';
import '../theme/app_theme.dart';
import 'gemini_translate_subtitle_dialog.dart';
import 'tts_error_review_dialog.dart';

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
  String _videoFileName = '';
  int _videoDurationMs = 0;
  String _videoSizeLabel = '';

  VoiceItem _selectedVoice = VoicePresets.defaultVoice;
  int _threadCount = 50;

  final TtsGenerationManager _ttsManager = TtsGenerationManager();
  bool _errorDialogOpen = false;
  bool _wasRunning = false;

  @override
  void initState() {
    super.initState();
    _doc = widget.initialDoc;
    _videoPath = widget.initialVideoPath;
    _ttsManager.progress.addListener(_onTtsProgressChanged);
    unawaited(_refreshVideoMetadata());
    _loadSettings();
  }

  @override
  void dispose() {
    _ttsManager.progress.removeListener(_onTtsProgressChanged);
    unawaited(ForegroundServiceManager.stop());
    super.dispose();
  }

  void _onTtsProgressChanged() {
    if (!mounted) return;
    final state = _ttsManager.progress.value;
    if (state.isRunning) {
      final pct = state.totalCount > 0
          ? ((state.completedCount / state.totalCount) * 100).toInt().clamp(
              0,
              100,
            )
          : 0;
      final msg =
          'Đã tạo: ${state.completedCount}/${state.totalCount} câu ($pct%)';
      unawaited(
        ForegroundServiceManager.update(
          title: 'CapSub AI - Lồng tiếng TTS',
          message: msg,
          progress: pct,
          maxProgress: 100,
        ),
      );
    } else {
      unawaited(ForegroundServiceManager.stop());
    }
    if (state.isRunning != _wasRunning) {
      _wasRunning = state.isRunning;
      setState(() {});
    }
    if (!state.isRunning && state.failedItems.isNotEmpty && !_errorDialogOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_errorDialogOpen) _showErrorReviewDialog();
      });
    }
  }

  @override
  void didUpdateWidget(covariant TtsStudioScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialDoc != null) {
      if (widget.initialDoc != oldWidget.initialDoc || _doc == null) {
        _doc = widget.initialDoc;
        _linkExistingAudio();
      }
    }
    if (widget.initialVideoPath != null && widget.initialVideoPath!.isNotEmpty) {
      if (widget.initialVideoPath != oldWidget.initialVideoPath ||
          _videoPath == null ||
          _videoPath!.isEmpty) {
        _videoPath = widget.initialVideoPath;
        unawaited(_refreshVideoMetadata());
      }
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
      await TtsGenerationManager.linkAudioFiles(
        _doc!,
        _selectedVoice.voiceType,
      );
      if (mounted) setState(() {});
    }
  }

  Future<void> _pickVideoFromFiles() async {
    final picked = await MediaStorage.pickPersistentMedia(
      context: context,
      videoOnly: true,
    );
    if (picked != null) {
      setState(() {
        _videoPath = picked.location;
      });
      await _refreshVideoMetadata();
      if (_doc != null && _doc!.items.isNotEmpty) {
        await _persistDocumentToHistory();
      }
    }
  }

  Future<void> _refreshVideoMetadata() async {
    final path = _videoPath;
    if (path == null || path.isEmpty) {
      if (mounted) {
        setState(() {
          _videoFileName = '';
          _videoDurationMs = 0;
          _videoSizeLabel = '';
        });
      }
      return;
    }

    var effectivePath = path;
    if (NetworkHeaderHelper.isRemoteUrl(path)) {
      final cached = await VideoCacheManager.findCachedFile(url: path);
      if (cached != null && await cached.exists()) {
        effectivePath = cached.path;
      }
    }

    final isOnline = NetworkHeaderHelper.isRemoteUrl(effectivePath);
    final isContent = MediaStorage.isContentUri(effectivePath);
    var name = 'video.mp4';
    var sizeLabel = isOnline ? 'Trực tuyến' : '';
    var durationMs = 0;

    if (isOnline) {
      name = NetworkHeaderHelper.getSuggestedTitle(effectivePath);
    } else if (isContent) {
      try {
        final meta = await AudioExtractor.getContentMetadata(effectivePath);
        name = meta.name.isNotEmpty ? meta.name : 'video.mp4';
        if (meta.sizeBytes > 0) {
          sizeLabel =
              '${(meta.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
        }
        durationMs = meta.durationMs;
      } catch (_) {}
    } else {
      try {
        name = File(effectivePath).uri.pathSegments.last;
      } catch (_) {}
      try {
        final bytes = await File(effectivePath).length();
        final isCached = effectivePath.contains('video_cache');
        sizeLabel = '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB${isCached ? " (Đã tải)" : ""}';
      } catch (_) {}
    }

    if (durationMs <= 0) {
      try {
        durationMs = await AudioExtractor.probeDuration(effectivePath);
      } catch (_) {}
    }
    if (name.trim().isEmpty) name = 'video.mp4';
    if (!mounted || _videoPath != path) return;
    setState(() {
      _videoFileName = name;
      _videoDurationMs = durationMs;
      _videoSizeLabel = sizeLabel;
    });
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
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
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
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
                    icon: const Icon(
                      Icons.paste,
                      size: 14,
                      color: AppColors.primaryEmerald,
                    ),
                    label: const Text(
                      'Dán từ Clipboard',
                      style: TextStyle(
                        color: AppColors.primaryEmerald,
                        fontSize: 12,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      side: const BorderSide(color: AppColors.primaryEmerald),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ],
              ),
              if (errorText != null) ...[
                const SizedBox(height: 6),
                Text(
                  errorText!,
                  style: const TextStyle(
                    color: Color(0xFFFFB74D),
                    fontSize: 12,
                  ),
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
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () {
                final clean = NetworkHeaderHelper.extractCleanUrl(
                  controller.text,
                );
                if (clean.isEmpty || !NetworkHeaderHelper.isRemoteUrl(clean)) {
                  setDialogState(() {
                    errorText = 'Vui lòng nhập link hợp lệ (http://, https:// hoặc link Bilibili/b23.tv)';
                  });
                  return;
                }
                setState(() => _videoPath = clean);
                unawaited(_refreshVideoMetadata());
                if (_doc != null && _doc!.items.isNotEmpty) {
                  unawaited(_persistDocumentToHistory());
                }
                Navigator.pop(ctx);
              },
              child: const Text(
                'Xác Nhận',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
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
          await _persistDocumentToHistory();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Đã nạp thành công ${doc.items.length} câu phụ đề từ SRT!',
                ),
              ),
            );
          }
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('File SRT không có câu thoại hợp lệ')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Lỗi nạp SRT: $e')));
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
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Chọn Video Từ Lịch Sử',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.5,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: items.length,
                separatorBuilder: (_, _) =>
                    const Divider(color: AppColors.cardBorder),
                itemBuilder: (context, idx) {
                  final it = items[idx];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.history,
                      color: AppColors.primaryEmerald,
                    ),
                    title: Text(
                      it.title,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    subtitle: Text(
                      '${(it.durationMs / 1000).toStringAsFixed(0)}s • ${DateTime.fromMillisecondsSinceEpoch(it.timestamp).toLocal().toString().split(".")[0]}',
                      style: const TextStyle(color: Colors.grey, fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () async {
                      Navigator.pop(ctx);
                      try {
                        final srtContent = await File(it.srtPath)
                            .readAsString();
                        final doc = SubtitleDocument.parseSrt(srtContent);
                        if (!mounted) return;
                        setState(() {
                          _videoPath = it.videoPath;
                          _doc = doc;
                        });
                        await _refreshVideoMetadata();
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

  Future<void> _startGenerateAllTts({bool forceRegenerate = false}) async {
    if (_doc == null || _doc!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Vui lòng nạp phụ đề trước khi tạo giọng!'),
        ),
      );
      return;
    }

    await WakelockPlus.enable();
    await ForegroundServiceManager.start(
      title: 'CapSub AI - Lồng tiếng TTS',
      message: 'Đang chuẩn bị sinh giọng đọc...',
      progress: 0,
      maxProgress: 100,
    );
    try {
      await _ttsManager.generateAll(
        document: _doc!,
        voice: _selectedVoice,
        threadCount: _threadCount,
        forceRegenerate: forceRegenerate,
      );
      await _linkExistingAudio();
      await _persistDocumentToHistory();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Lỗi tạo giọng: $error')));
      }
    } finally {
      await WakelockPlus.disable();
      await ForegroundServiceManager.stop();
    }
  }

  Future<void> _persistDocumentToHistory() async {
    final document = _doc;
    final videoPath = _videoPath;
    if (document == null || videoPath == null || videoPath.isEmpty) return;
    try {
      final repository = await HistoryRepository.getInstance();
      await repository.saveHistory(
        videoPath: videoPath,
        title: _videoFileName.isNotEmpty ? _videoFileName : 'Video',
        document: document,
        durationMs: _videoDurationMs,
        ttsVoice: _selectedVoice.displayName,
      );
    } catch (_) {}
  }

  String _targetLanguageLabel(String code) => switch (code) {
    'en-US' || 'Tiếng Anh' => 'Tiếng Anh',
    'zh-CN' || 'Tiếng Trung' => 'Tiếng Trung',
    'ja-JP' || 'Tiếng Nhật' => 'Tiếng Nhật',
    'ko-KR' || 'Tiếng Hàn' => 'Tiếng Hàn',
    _ => 'Tiếng Việt',
  };

  String _translationSourceFor(int itemId, String currentText) {
    final item = _doc?.items
        .where((candidate) => candidate.id == itemId)
        .firstOrNull;
    final hasHan = RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF]');
    if (hasHan.hasMatch(currentText)) return currentText;
    if (item != null && hasHan.hasMatch(item.originalText)) {
      return item.originalText;
    }
    if (currentText.trim().isNotEmpty) return currentText;
    return item?.originalText ?? currentText;
  }

  SmartAiTranslator _createSmartAiTranslator() {
    final settings = _settings!;
    return SmartAiTranslator(
      geminiKeys: settings.geminiApiKeys,
      groqKeys: settings.groqApiKeys,
      initialModelId: settings.selectedModel,
      enableSmartModelFallback: settings.enableSmartModelFallback,
      enableCrossProviderFallback: settings.enableCrossProviderFallback,
      enableDualModelBalancing: settings.enableDualModelBalancing,
    );
  }

  Future<void> _showErrorReviewDialog() async {
    final settings = _settings;
    final document = _doc;
    final state = _ttsManager.progress.value;
    if (settings == null ||
        document == null ||
        state.failedItems.isEmpty ||
        _errorDialogOpen) {
      return;
    }
    _errorDialogOpen = true;

    final hasAiKeys =
        settings.geminiApiKeys.isNotEmpty || settings.groqApiKeys.isNotEmpty;
    final effectiveAiThreads = settings.selectedModel.startsWith('gemini')
        ? settings.geminiThreadCount
        : settings.groqThreadCount;

    final displayFailedItems = state.failedItems.map((failure) {
      final text = failure.text.trim();
      final hasLetters =
          RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(text);
      if (!hasLetters) {
        final source = _translationSourceFor(failure.itemId, text);
        return TtsFailedItem(
          itemId: failure.itemId,
          text: source,
          reason: failure.reason,
          filePath: failure.filePath,
        );
      }
      return failure;
    }).toList();

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => TtsErrorReviewDialog(
        failedItems: displayFailedItems,
        threadCount: _threadCount,
        geminiThreadCount: effectiveAiThreads,
        geminiApiKeysAvailable: hasAiKeys,
        onRetryOne: (itemId, editedText) async {
          await _ttsManager.retryFailedItem(
            document: document,
            voice: _selectedVoice,
            itemId: itemId,
            editedText: editedText,
            threadCount: _threadCount,
          );
          await _linkExistingAudio();
          await _persistDocumentToHistory();
        },
        onRetryAll: (editedTexts) async {
          await _ttsManager.retryFailedItems(
            document: document,
            voice: _selectedVoice,
            editedTexts: editedTexts,
            threadCount: _threadCount,
          );
          await _linkExistingAudio();
          await _persistDocumentToHistory();
        },
        onTranslateWithGemini: (items, onProgress) async {
          if (!hasAiKeys) return const {};
          final sourceItems = {
            for (final entry in items.entries)
              entry.key: _translationSourceFor(entry.key, entry.value),
          };
          final smartTranslator = _createSmartAiTranslator();
          final translated = await smartTranslator.translateItems(
            items: sourceItems,
            stylePreset: settings.selectedStyle,
            customPrompt: settings.geminiCustomPrompt,
            targetLanguage: _targetLanguageLabel(settings.targetLanguage),
            threadCount: effectiveAiThreads,
            progressCallback: onProgress,
          );
          for (final entry in translated.entries) {
            final item = document.items
                .where((candidate) => candidate.id == entry.key)
                .firstOrNull;
            if (item != null) {
              item.translatedText = entry.value;
              item.normalizeTranslation();
            }
          }
          await _persistDocumentToHistory();
          return translated;
        },
        onTranslateSingleWithGemini: (itemId, text) async {
          if (!hasAiKeys) return text;
          final smartTranslator = _createSmartAiTranslator();
          final translated = await smartTranslator.translateSingleText(
            text: _translationSourceFor(itemId, text),
            stylePreset: settings.selectedStyle,
            customPrompt: settings.geminiCustomPrompt,
            targetLanguage: _targetLanguageLabel(settings.targetLanguage),
          );
          final item = document.items
              .where((candidate) => candidate.id == itemId)
              .firstOrNull;
          if (item != null) {
            item.translatedText = translated;
            item.normalizeTranslation();
            await _persistDocumentToHistory();
          }
          return translated;
        },
        onSkipErrors: () async {
          await _ttsManager.skipFailedItems(
            document: document,
            voice: _selectedVoice,
          );
          await _persistDocumentToHistory();
        },
      ),
    );
    _errorDialogOpen = false;
  }

  Future<void> _showChooseVideoSourceDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.darkCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Chọn Video Nguồn',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'Chọn video trong máy hoặc nhập link video online để phát cùng phụ đề.',
          style: TextStyle(color: Colors.grey),
        ),
        actions: [
          OutlinedButton.icon(
            onPressed: () {
              Navigator.pop(dialogContext);
              _pickVideoFromFiles();
            },
            icon: const Icon(Icons.video_file),
            label: const Text('File máy'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(dialogContext);
              _showEnterLinkDialog();
            },
            icon: const Icon(Icons.link),
            label: const Text('Nhập Link'),
          ),
        ],
      ),
    );
  }

  Future<void> _navigateToPlayer() async {
    if (_doc == null || _doc!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chưa có phụ đề để xem video!')),
      );
      return;
    }

    // Tự động kiểm tra và phục hồi đường dẫn video nếu đang null hoặc rỗng
    if (_videoPath == null || _videoPath!.isEmpty) {
      if (widget.initialVideoPath != null && widget.initialVideoPath!.isNotEmpty) {
        _videoPath = widget.initialVideoPath;
      } else {
        final history = await HistoryRepository.getInstance();
        final latest = history.getHistory().firstOrNull;
        if (latest != null && latest.videoPath.isNotEmpty) {
          _videoPath = latest.videoPath;
        }
      }
      if (_videoPath != null && _videoPath!.isNotEmpty) {
        unawaited(_refreshVideoMetadata());
      }
    }

    if (_videoPath == null || _videoPath!.isEmpty) {
      _showChooseVideoSourceDialog();
      return;
    }

    final pathToPlay = _videoPath!;
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) =>
            VideoPlayerScreen(videoPath: pathToPlay, document: _doc!),
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
            Icon(
              Icons.record_voice_over,
              color: AppColors.primaryEmerald,
              size: 22,
            ),
            SizedBox(width: 8),
            Text(
              'Lồng Tiếng AI (TTS Studio)',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
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

            // 4. TIẾN TRÌNH & THAO TÁC
            ValueListenableBuilder<TtsGenerationState>(
              valueListenable: _ttsManager.progress,
              builder: (context, state, _) => _buildCard4Actions(state),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildCard4Actions(TtsGenerationState state) {
    final document = _doc;
    final totalCount = document?.items.length ?? 0;
    final voicedCount =
        document?.items
            .where((item) => item.audioFilePath?.isNotEmpty == true)
            .length ??
        0;
    final hasAudio = voicedCount > 0;
    final isFullyCompleted = totalCount > 0 && voicedCount == totalCount;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.darkCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: state.isRunning
          ? _buildRunningProgress(state)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (state.isFinished) ...[
                  _buildStatusRow(
                    Icons.check_circle,
                    AppColors.primaryEmerald,
                    state.currentSentence.isEmpty
                        ? 'Đã hoàn thành lồng tiếng $totalCount câu thoại!'
                        : state.currentSentence,
                  ),
                  const SizedBox(height: 12),
                ] else if (state.currentSentence.isNotEmpty) ...[
                  _buildStatusRow(
                    state.isCancelled ? Icons.cancel : Icons.warning_amber,
                    const Color(0xFFFFB74D),
                    state.currentSentence,
                  ),
                  const SizedBox(height: 12),
                ],
                if (state.failedItems.isNotEmpty) ...[
                  OutlinedButton.icon(
                    onPressed: _showErrorReviewDialog,
                    icon: const Icon(Icons.warning_amber),
                    label: Text(
                      'Mở bảng xử lý ${state.failedItems.length} câu lỗi',
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFFFB74D),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                if (!hasAudio) ...[
                  SizedBox(
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: totalCount > 0
                          ? () => _startGenerateAllTts()
                          : null,
                      icon: const Icon(Icons.record_voice_over),
                      label: const Text(
                        'Bắt Đầu Lồng Tiếng AI',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryEmerald,
                        foregroundColor: Colors.black,
                      ),
                    ),
                  ),
                  if (totalCount > 0) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        onPressed: _navigateToPlayer,
                        icon: const Icon(
                          Icons.play_arrow,
                          color: AppColors.primaryEmerald,
                        ),
                        label: const Text(
                          'Xem Vietsub Ngay (Không Cần Lồng Tiếng)',
                        ),
                      ),
                    ),
                  ],
                ] else ...[
                  SizedBox(
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: _navigateToPlayer,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text(
                        'Mở Xem Video (Đã Lồng Tiếng AI)',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryEmerald,
                        foregroundColor: Colors.black,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 48,
                    child: OutlinedButton.icon(
                      onPressed: () => _startGenerateAllTts(
                        forceRegenerate: isFullyCompleted,
                      ),
                      icon: const Icon(
                        Icons.record_voice_over,
                        color: AppColors.primaryEmerald,
                      ),
                      label: Text(
                        isFullyCompleted
                            ? 'Tạo Lại Giọng AI Toàn Bộ'
                            : 'Tiếp Tục Lồng Tiếng ($voicedCount/$totalCount)',
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _navigateToPlayer,
                    child: const Text(
                      'Hoặc xem video chỉ với Vietsub (âm thanh gốc)',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _buildRunningProgress(TtsGenerationState state) {
    final progress = state.totalCount > 0
        ? state.completedCount / state.totalCount
        : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Đang lồng tiếng: ${state.completedCount}/${state.totalCount} câu',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '${(progress * 100).toInt()}%',
              style: const TextStyle(
                color: AppColors.primaryEmerald,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 8,
            color: AppColors.primaryEmerald,
            backgroundColor: const Color(0xFF323444),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Tốc độ: ~${state.speedPerSec.toStringAsFixed(1)} câu/giây',
          style: const TextStyle(color: Color(0xFF64B5F6), fontSize: 12),
        ),
        Text(
          state.currentSentence,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.grey, fontSize: 12),
        ),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: () {
            _ttsManager.cancel();
            unawaited(ForegroundServiceManager.stop());
          },
          icon: const Icon(Icons.cancel, size: 16),
          label: const Text('Hủy tiến trình'),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFFF5252),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusRow(IconData icon, Color color, String message) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCard0VideoSource() {
    final hasVideo = _videoPath != null && _videoPath!.isNotEmpty;
    final isOnline = hasVideo && _videoPath!.startsWith('http');
    final durationSeconds = _videoDurationMs ~/ 1000;
    final durationText = _videoDurationMs > 0
        ? '${(durationSeconds ~/ 60).toString().padLeft(2, '0')}:'
              '${(durationSeconds % 60).toString().padLeft(2, '0')}'
        : 'Tự động';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.darkCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: hasVideo
              ? AppColors.primaryEmerald.withValues(alpha: 0.5)
              : AppColors.cardBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '0. Video Nguồn',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _pickVideoFromFiles,
                    icon: const Icon(
                      Icons.video_file,
                      size: 14,
                      color: Colors.white,
                    ),
                    label: const Text(
                      'File máy',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      side: const BorderSide(color: AppColors.cardBorder),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _showEnterLinkDialog,
                    icon: const Icon(
                      Icons.link,
                      size: 14,
                      color: AppColors.primaryEmerald,
                    ),
                    label: const Text(
                      'Nhập Link',
                      style: TextStyle(
                        color: AppColors.primaryEmerald,
                        fontSize: 12,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      side: const BorderSide(color: AppColors.primaryEmerald),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
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
                      const Icon(
                        Icons.check_circle,
                        color: AppColors.primaryEmerald,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _videoFileName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '⏱️ $durationText  •  💾 $_videoSizeLabel'
                              '${isOnline ? ' (Online)' : ''}',
                              style: TextStyle(
                                color: isOnline
                                    ? AppColors.primaryEmerald
                                    : Colors.grey,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.close,
                          size: 16,
                          color: Colors.grey,
                        ),
                        onPressed: () {
                          setState(() => _videoPath = null);
                          unawaited(_refreshVideoMetadata());
                        },
                      ),
                    ],
                  )
                : InkWell(
                    onTap: _showChooseVideoSourceDialog,
                    child: const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          'Chạm để chọn File từ máy hoặc dán Link online',
                          style: TextStyle(color: Colors.grey, fontSize: 13),
                        ),
                      ),
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
        ? _doc!.items
              .where(
                (it) =>
                    it.audioFilePath != null && it.audioFilePath!.isNotEmpty,
              )
              .length
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
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _showHistoryPicker,
                    icon: const Icon(
                      Icons.play_arrow,
                      size: 14,
                      color: Color(0xFF64B5F6),
                    ),
                    label: const Text(
                      'Lịch sử',
                      style: TextStyle(color: Color(0xFF64B5F6), fontSize: 12),
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      side: const BorderSide(color: Color(0xFF64B5F6)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton.icon(
                    onPressed: _pickSrtFile,
                    icon: const Icon(
                      Icons.file_upload,
                      size: 14,
                      color: AppColors.primaryEmerald,
                    ),
                    label: const Text(
                      'Nạp SRT',
                      style: TextStyle(
                        color: AppColors.primaryEmerald,
                        fontSize: 12,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      side: const BorderSide(color: AppColors.primaryEmerald),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
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
                  const Icon(
                    Icons.subtitles,
                    color: AppColors.primaryEmerald,
                    size: 24,
                  ),
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
                            color: voicedCount > 0
                                ? AppColors.primaryEmerald
                                : Colors.grey,
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
                icon: const Icon(
                  Icons.translate,
                  size: 16,
                  color: Color(0xFF64B5F6),
                ),
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
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  backgroundColor: const Color(0xFF1E222D)
                      .withValues(alpha: 0.3),
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
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
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
    final voices = List<VoiceItem>.from(VoicePresets.vietnameseVoices);
    final selectedIndex = voices.indexWhere(
      (voice) => voice.voiceType == _selectedVoice.voiceType,
    );
    if (selectedIndex > 0) {
      voices.insert(0, voices.removeAt(selectedIndex));
    }

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
                '2. Chọn Giọng Đọc CapCut',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.primaryEmerald.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.mic,
                      size: 14,
                      color: AppColors.primaryEmerald,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _selectedVoice.displayName,
                      style: const TextStyle(
                        color: AppColors.primaryEmerald,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
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
                        color: isSelected
                            ? AppColors.primaryEmerald
                            : AppColors.cardBorder,
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
                                  color: isSelected
                                      ? AppColors.primaryEmerald
                                      : Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isSelected)
                              const Icon(
                                Icons.check_circle,
                                color: AppColors.primaryEmerald,
                                size: 14,
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          v.description.isNotEmpty
                              ? v.description
                              : 'Giọng đọc CapCut',
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
                  Text(
                    '3. Số Luồng Song Song',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Text(
                '$_threadCount luồng',
                style: const TextStyle(
                  color: AppColors.primaryEmerald,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
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
