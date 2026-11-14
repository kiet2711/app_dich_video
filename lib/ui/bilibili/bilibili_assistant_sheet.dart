import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/model/watch_later_item.dart';
import '../../data/repository/watch_later_repository.dart';
import '../../domain/ai/live/live_reply_title_sync.dart';
import '../../domain/media/bilibili/bilibili_assistant_engine.dart';
import '../../domain/media/bilibili_resolver.dart';
import '../ai_assistant/live_assistant_shared_widgets.dart';
import '../settings/settings_screen.dart';
import '../theme/app_theme.dart';
import 'bilibili_assistant_controller.dart';
import 'bilibili_uploader_sheet.dart';

const _biliPink = Color(0xFFFB7299);
const _biliCyan = Color(0xFF00AEEC);

class BilibiliAssistantSheet extends StatefulWidget {
  final BilibiliAssistantController controller;
  final void Function(BilibiliAnimeItem item) onOpenVideo;
  final void Function(List<BilibiliAnimeItem> items, String label)
  onApplyToMainGrid;

  const BilibiliAssistantSheet({
    super.key,
    required this.controller,
    required this.onOpenVideo,
    required this.onApplyToMainGrid,
  });

  static Future<void> show(
    BuildContext context, {
    required BilibiliAssistantController controller,
    required void Function(BilibiliAnimeItem item) onOpenVideo,
    required void Function(List<BilibiliAnimeItem> items, String label)
    onApplyToMainGrid,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => BilibiliAssistantSheet(
        controller: controller,
        onOpenVideo: onOpenVideo,
        onApplyToMainGrid: onApplyToMainGrid,
      ),
    );
  }

  @override
  State<BilibiliAssistantSheet> createState() => _BilibiliAssistantSheetState();
}

class _BilibiliAssistantSheetState extends State<BilibiliAssistantSheet> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  int _lastMsgCount = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    widget.controller.refreshApiKeyStatus();
    _lastMsgCount = widget.controller.messages.length;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final count = widget.controller.messages.length;
    if (count != _lastMsgCount) {
      _lastMsgCount = count;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          );
        }
      });
    }
    setState(() {});
  }

  void _submitText([String? overrideText]) {
    final text = (overrideText ?? _inputController.text).trim();
    if (text.isEmpty) return;
    HapticFeedback.lightImpact();
    if (overrideText == null) {
      _inputController.clear();
    }
    FocusScope.of(context).unfocus();
    widget.controller.sendTextMessage(text);
  }

  Future<void> _openSettingsForKey() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    if (mounted) {
      await widget.controller.refreshApiKeyStatus();
    }
  }

  void _handleCandidatePrimaryTap(BilibiliAssistantCandidate cand) {
    if (cand.kind == BilibiliCandidateKind.upChannel &&
        cand.userResult != null) {
      final u = cand.userResult!;
      BilibiliUploaderSheet.show(
        context: context,
        mid: u.mid,
        authorName: u.uname,
        initialAvatar: u.upic,
        onSelectVideo: (video) {
          Navigator.pop(context);
          widget.onOpenVideo(video);
        },
      );
      return;
    }
    widget.onOpenVideo(cand.item);
  }

  void _askSummarizeCandidate(
    BilibiliAssistantCandidate cand, {
    String summaryStyle = 'structured',
  }) {
    final prompt = widget.controller.buildSummarizePrompt(
      cand,
      summaryStyle: summaryStyle,
    );
    _submitText(prompt);
  }

  Future<void> _handleExportSrt(BilibiliAssistantCandidate cand) async {
    final file = await widget.controller.exportSrtForCandidate(cand);
    if (!mounted || file == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Đã xuất file .srt: ${file.path.split(RegExp(r"[/\\]")).last}',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _handleSrtAction(BilibiliAssistantCandidate cand) async {
    if (cand.hasSrtInMemory) {
      await _handleExportSrt(cand);
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: geminiSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.subtitles_rounded, color: _biliCyan, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Phụ đề .srt cho #${cand.displayIndex}',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Tạo/xuất .srt tách lời thoại thành file phụ đề chuẩn (khác với Cốt truyện / Ý chính là AI tóm tắt nhanh từ mô tả & bình luận).',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                leading: const Icon(
                  Icons.download_for_offline_rounded,
                  color: AppColors.primaryEmerald,
                ),
                title: const Text(
                  'Chỉ tạo & xuất file .srt',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                  ),
                ),
                subtitle: const Text(
                  'Trích giọng nói lưu thành file .srt để tải/dịch, không tự tóm tắt AI',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 11.5),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  final file = await widget.controller.extractAndExportSrtOnly(cand);
                  if (!mounted || file == null) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Đã lưu file .srt: ${file.path.split(RegExp(r"[/\\]")).last}',
                      ),
                      duration: const Duration(seconds: 3),
                    ),
                  );
                },
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                leading: const Icon(Icons.auto_stories_rounded, color: _biliPink),
                title: const Text(
                  'Tạo .srt & Kể cốt truyện',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                  ),
                ),
                subtitle: const Text(
                  'Tạo .srt từ giọng nói rồi kể mạch truyện trôi chảy (không mốc giờ)',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 11.5),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  widget.controller.runManualCapCutSttAndSummarize(
                    cand,
                    summaryStyle: 'story',
                  );
                },
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                leading: const Icon(Icons.fact_check_rounded, color: _biliCyan),
                title: const Text(
                  'Tạo .srt & Tóm tắt ý chính',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                  ),
                ),
                subtitle: const Text(
                  'Tạo .srt rồi tóm tắt từng ý quan trọng kèm mốc [mm:ss]',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 11.5),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  widget.controller.runManualCapCutSttAndSummarize(
                    cand,
                    summaryStyle: 'structured',
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final screenH = MediaQuery.of(context).size.height;

    return Container(
      height: screenH * 0.92,
      decoration: BoxDecoration(
        color: AppColors.darkBackground,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
      ),
      child: Column(
        children: [
          _buildHeader(c),
          _buildFilterStrip(c),
          if (!c.hasApiKeys || c.errorBanner != null)
            LiveAssistantNoticeBanner(
              hasApiKeys: c.hasApiKeys,
              errorBanner: c.errorBanner,
              onQuickKey: () => showLiveQuickApiKeyDialog(
                context,
                onSaveKeys: c.saveQuickGeminiKeys,
              ),
              onOpenSettings: _openSettingsForKey,
              onDismissError: c.clearErrorBanner,
            ),
          Expanded(
            child: c.messages.isEmpty
                ? _buildEmptyGuideView(c)
                : _buildMessagesList(c),
          ),
          if (c.isAssistantBusy || c.isAiSpeaking || c.isRunningManualStt)
            _buildBusyStrip(c),
          if (c.pinnedKeys.isNotEmpty) _buildPinnedStrip(c),
          Padding(
            padding: EdgeInsets.only(bottom: bottomInset),
            child: LiveAssistantInputBar(
              textController: _inputController,
              isMicActive: c.isMicActive,
              micLevel: c.micLevel,
              isBusy: c.isAssistantBusy,
              hintText: c.titleTranslateOnly
                  ? 'Mô tả phim/video tiếng Việt để lấy tên tiếng Trung tự copy tìm...'
                  : 'Tìm video kiến thức, công nghệ, UP chủ, BXH hoặc hỏi tóm tắt #1...',
              onSend: () => _submitText(),
              onToggleMic: c.toggleMic,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BilibiliAssistantController c) {
    final shortModel = shortLiveModelLabel(c.selectedModelId);
    final isLive = c.isConnected;
    final isConnecting =
        c.connectionState == AssistantConnectionState.connecting ||
        c.connectionState == AssistantConnectionState.reconnecting;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Center(
          child: Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(top: 8, bottom: 6),
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 8, 8),
          child: Row(
            children: [
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => showLiveModelPickerSheet(
                    context,
                    selectedModelId: c.selectedModelId,
                    diagnostics: c.lastDiagnostics,
                    subtitle:
                        'Chuyển mô hình bất cứ lúc nào mà vẫn giữ ngữ cảnh, thẻ Bilibili & SRT đang đọc.',
                    thinkingDetail:
                        'Suy luận sâu, tìm từ khóa đa tầng, đối chiếu bình luận & phân đoạn SRT kỹ hơn.',
                    onSelectModel: c.switchModel,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: geminiPillSurface,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.1),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ShaderMask(
                          shaderCallback: (bounds) => const LinearGradient(
                            colors: [_biliPink, _biliCyan],
                          ).createShader(bounds),
                          child: const Icon(
                            Icons.auto_awesome_rounded,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Bilibili · $shortModel',
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 2),
                        const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 18,
                          color: AppColors.textSecondary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: () => showLiveDiagnosticsSheet(
                  context,
                  selectedModelId: c.selectedModelId,
                  resolvedModelId: c.resolvedServerModelId,
                  apiVersion: c.resolvedApiVersion,
                  isConnected: c.isConnected,
                  isConnecting: isConnecting,
                  hasApiKeys: c.hasApiKeys,
                  apiKeyCount: c.apiKeyCount,
                  maskedActiveKey: c.maskedActiveKey,
                  diagnostics: c.lastDiagnostics,
                  onReconnect: () => c.ensureConnected(
                    seedContextSnapshot:
                        c.messages.isNotEmpty ||
                        c.engine.lastDisplayedCandidates.isNotEmpty,
                    forceFreshSession: true,
                    forceRefreshModelDiscovery: true,
                  ),
                ),
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: isLive
                              ? AppColors.primaryEmerald
                              : isConnecting
                                  ? Colors.amberAccent
                                  : c.connectionState ==
                                          AssistantConnectionState.error
                                      ? const Color(0xFFEF4444)
                                      : Colors.white38,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isLive
                            ? 'Live'
                            : isConnecting
                                ? 'Đang nối'
                                : 'Thông tin',
                        style: TextStyle(
                          color: isLive
                              ? AppColors.primaryEmerald
                              : AppColors.textMuted,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(
                  c.outputAudioEnabled
                      ? Icons.volume_up_rounded
                      : Icons.volume_off_rounded,
                  size: 20,
                  color: c.outputAudioEnabled ? _biliCyan : AppColors.textMuted,
                ),
                tooltip: c.outputAudioEnabled
                    ? 'Đang bật đọc thoại'
                    : 'Chỉ văn bản (im lặng)',
                onPressed: () {
                  HapticFeedback.selectionClick();
                  c.setOutputAudioEnabled(!c.outputAudioEnabled);
                },
              ),
              IconButton(
                icon: const Icon(
                  Icons.edit_square,
                  size: 19,
                  color: AppColors.textSecondary,
                ),
                tooltip: 'Cuộc trò chuyện mới',
                onPressed: () {
                  HapticFeedback.lightImpact();
                  c.resetConversation();
                },
              ),
              IconButton(
                icon: const Icon(
                  Icons.close_rounded,
                  size: 21,
                  color: AppColors.textSecondary,
                ),
                tooltip: 'Đóng',
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showPartitionPickerSheet(BilibiliAssistantController c) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: geminiSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.grid_view_rounded, color: _biliPink, size: 18),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Chọn mảng / phân khu Bilibili',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        c.setPartitionTid(0);
                        c.setAiAnimeOnly(false);
                        Navigator.pop(ctx);
                      },
                      child: const Text('Tất cả'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                InkWell(
                  onTap: () {
                    final next = !c.aiAnimeOnly;
                    c.setAiAnimeOnly(next);
                    if (next &&
                        c.partitionTid != 0 &&
                        c.partitionTid != 1 &&
                        c.partitionTid != 167 &&
                        c.partitionTid != 13) {
                      c.setPartitionTid(0);
                    }
                    Navigator.pop(ctx);
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: c.aiAnimeOnly
                          ? _biliPink.withValues(alpha: 0.16)
                          : Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: c.aiAnimeOnly
                            ? _biliPink.withValues(alpha: 0.7)
                            : Colors.white.withValues(alpha: 0.1),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.movie_filter_rounded,
                          size: 18,
                          color: c.aiAnimeOnly ? _biliPink : _biliCyan,
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Chỉ Phim Hoạt Hình AI (Lọc sạch)',
                                style: TextStyle(
                                  color: AppColors.textPrimary,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Quét phân khu Hoạt hình + Quốc sáng, tự bỏ video dạy làm AI, người thật & tiểu thuyết audio',
                                style: TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          c.aiAnimeOnly
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          size: 18,
                          color: c.aiAnimeOnly ? _biliPink : AppColors.textMuted,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in BilibiliPartition.catalog)
                      _FilterChip(
                        label: p.viLabel.split(' / ').first,
                        selected: c.partitionTid == p.tid && !c.aiAnimeOnly,
                        activeColor: _biliPink,
                        onTap: () {
                          if (p.tid != 0 &&
                              p.tid != 1 &&
                              p.tid != 167 &&
                              p.tid != 13) {
                            c.setAiAnimeOnly(false);
                          }
                          c.setPartitionTid(p.tid);
                          Navigator.pop(ctx);
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterStrip(BilibiliAssistantController c) {
    final currentCount = c.preferredCount ?? 5;
    final partitionShort = c.partitionTid == 0
        ? 'Mảng'
        : (BilibiliPartition.byTid(c.partitionTid)?.viLabel ?? 'Mảng')
            .split(' / ')
            .first;
    final durationText = c.durationBucket == 0
        ? 'Độ dài'
        : BilibiliAssistantEngine.durationLabel(c.durationBucket);
    final recencyText = c.recencyBucket == 'any'
        ? 'Ngày đăng'
        : BilibiliAssistantEngine.recencyLabel(c.recencyBucket);
    final sortLabel = switch (c.sortOrder) {
      'stow' => 'Lưu nhiều',
      'click' => 'Xem nhiều',
      'pubdate' => 'Mới đăng',
      _ => 'Xếp: Liên quan',
    };

    return Container(
      height: 40,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _FilterDropdownPill(
                  label: 'Tên Việt → Trung',
                  icon: Icons.translate_rounded,
                  selected: c.titleTranslateOnly,
                  showArrow: false,
                  activeColor: _biliCyan,
                  onTap: () => c.setTitleTranslateOnly(!c.titleTranslateOnly),
                ),
                const SizedBox(width: 6),
                _FilterDropdownPill(
                  label: 'Hoạt hình AI',
                  icon: Icons.movie_filter_rounded,
                  selected: c.aiAnimeOnly,
                  showArrow: false,
                  activeColor: _biliPink,
                  onTap: () => c.setAiAnimeOnly(!c.aiAnimeOnly),
                ),
                const SizedBox(width: 6),
                _FilterDropdownPill(
                  label: partitionShort,
                  icon: Icons.grid_view_rounded,
                  selected: c.partitionTid > 0,
                  activeColor: _biliPink,
                  onTap: () => _showPartitionPickerSheet(c),
                ),
                const SizedBox(width: 6),
                PopupMenuButton<int>(
                  tooltip: 'Lọc theo độ dài video',
                  color: geminiSurface,
                  onSelected: c.setDurationBucket,
                  itemBuilder: (_) => [
                    for (final b in const [0, 1, 2, 3, 4])
                      PopupMenuItem<int>(
                        value: b,
                        child: Row(
                          children: [
                            Icon(
                              c.durationBucket == b
                                  ? Icons.check_rounded
                                  : Icons.schedule_rounded,
                              size: 16,
                              color: c.durationBucket == b
                                  ? _biliCyan
                                  : AppColors.textMuted,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              BilibiliAssistantEngine.durationLabel(b),
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  child: _FilterDropdownPill(
                    label: durationText,
                    icon: Icons.schedule_rounded,
                    selected: c.durationBucket > 0,
                    activeColor: _biliCyan,
                  ),
                ),
                const SizedBox(width: 6),
                PopupMenuButton<String>(
                  tooltip: 'Lọc theo ngày đăng',
                  color: geminiSurface,
                  onSelected: c.setRecencyBucket,
                  itemBuilder: (_) => [
                    for (final r in const [
                      'any',
                      '24h',
                      '7d',
                      '30d',
                      '90d',
                      '1y',
                    ])
                      PopupMenuItem<String>(
                        value: r,
                        child: Row(
                          children: [
                            Icon(
                              c.recencyBucket == r
                                  ? Icons.check_rounded
                                  : Icons.calendar_today_rounded,
                              size: 15,
                              color: c.recencyBucket == r
                                  ? Colors.orangeAccent
                                  : AppColors.textMuted,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              BilibiliAssistantEngine.recencyLabel(r),
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  child: _FilterDropdownPill(
                    label: recencyText,
                    icon: Icons.event_available_rounded,
                    selected: c.recencyBucket != 'any',
                    activeColor: Colors.orangeAccent,
                  ),
                ),
                const SizedBox(width: 6),
                PopupMenuButton<String>(
                  tooltip: 'Sắp xếp kết quả',
                  color: geminiSurface,
                  onSelected: c.setSortOrder,
                  itemBuilder: (_) => [
                    for (final ord in const [
                      ('totalrank', 'Liên quan nhất'),
                      ('pubdate', 'Mới đăng nhất'),
                      ('click', 'Xem nhiều nhất'),
                      ('stow', 'Lưu nhiều nhất'),
                    ])
                      PopupMenuItem<String>(
                        value: ord.$1,
                        child: Row(
                          children: [
                            Icon(
                              c.sortOrder == ord.$1
                                  ? Icons.check_rounded
                                  : Icons.sort_rounded,
                              size: 16,
                              color: c.sortOrder == ord.$1
                                  ? AppColors.accentGold
                                  : AppColors.textMuted,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              ord.$2,
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  child: _FilterDropdownPill(
                    label: sortLabel,
                    icon: Icons.sort_rounded,
                    selected: c.sortOrder != 'totalrank',
                    activeColor: AppColors.accentGold,
                  ),
                ),
                if (c.hasActiveFilters) ...[
                  const SizedBox(width: 6),
                  _FilterDropdownPill(
                    label: 'Đặt lại',
                    icon: Icons.close_rounded,
                    selected: false,
                    showArrow: false,
                    activeColor: AppColors.textMuted,
                    onTap: c.resetFilters,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<int>(
            tooltip: 'Số mục hiển thị',
            color: geminiSurface,
            onSelected: (val) async {
              if (val < 0) {
                final next = await showLiveCountPickerDialog(
                  context,
                  initialCount: currentCount,
                  title: 'Số lượng kết quả gợi ý',
                );
                if (next != null) c.setPreferredCount(next);
              } else {
                c.setPreferredCount(val);
              }
            },
            itemBuilder: (_) => [
              for (final n in const [3, 5, 8, 10, 12])
                PopupMenuItem<int>(
                  value: n,
                  child: Row(
                    children: [
                      Icon(
                        currentCount == n
                            ? Icons.check_rounded
                            : Icons.format_list_numbered_rounded,
                        size: 16,
                        color: currentCount == n
                            ? AppColors.primaryEmerald
                            : AppColors.textMuted,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '$n mục',
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem<int>(
                value: -1,
                child: Row(
                  children: [
                    Icon(Icons.tune_rounded, size: 16, color: _biliCyan),
                    SizedBox(width: 8),
                    Text(
                      'Tùy chọn số khác...',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            child: _FilterDropdownPill(
              label: 'SL: $currentCount',
              icon: Icons.format_list_numbered_rounded,
              selected: true,
              activeColor: AppColors.primaryEmerald,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyGuideView(BilibiliAssistantController c) {
    final taste = c.tasteProfile;
    final samples = [
      (
        icon: Icons.favorite_rounded,
        text: 'Đề xuất video Bilibili mới hợp với gu mình hay xem',
      ),
      (
        icon: Icons.movie_filter_rounded,
        text: 'Tìm đúng phim Phàm Nhân Tu Tiên bản gốc tiếng Trung mới nhất',
      ),
      (
        icon: Icons.timelapse_rounded,
        text: 'Tìm phim hoạt hình AI trọng sinh dài trên 1 tiếng (chỉ lấy hoạt hình, bỏ kiến thức/audio/người thật)',
      ),
      (
        icon: Icons.new_releases_rounded,
        text: 'Tìm video review công nghệ AI mới đăng trong 7 ngày qua',
      ),
      (
        icon: Icons.build_circle_outlined,
        text: 'Hướng dẫn tự build NAS / homelab giá rẻ cho người mới',
      ),
      (
        icon: Icons.translate_rounded,
        text:
            'Chuyển giúp mình mô tả "phim hoạt hình nam chính trọng sinh giả phàm nhân vào tông môn báo thù" sang tên tiếng Trung để mình tự copy tìm (không đề xuất video)',
      ),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ShaderMask(
                shaderCallback: (bounds) => const LinearGradient(
                  colors: [_biliPink, _biliCyan],
                ).createShader(bounds),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  size: 28,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Trợ lý Bilibili Toàn Năng',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Học gu xem từ lịch sử Bilibili, tìm đúng tên phim gốc hoặc gợi ý theo thời lượng (kể cả >1 tiếng) & ngày đăng mới nhất.',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
              height: 1.45,
            ),
          ),
          if (taste != null && taste.hasSignals) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: _biliPink.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _biliPink.withValues(alpha: 0.3)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.recommend_rounded,
                    color: _biliPink,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      taste.topTags.isNotEmpty
                          ? 'Gu đã học (${taste.sampleCount} mục): ${taste.topTags.take(5).join(" · ")}'
                          : 'Đã đồng bộ ${taste.sampleCount} video bạn hay xem để ưu tiên kết quả hợp gu.',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11.5,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: geminiSurface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Phân biệt Tóm tắt AI & Phụ đề .srt',
                  style: TextStyle(
                    color: _biliCyan,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  '• Cốt truyện: Kể mạch truyện phim/hoạt hình mượt bằng tiếng Việt (không mốc giờ).\n'
                  '• Ý chính: Tóm tắt video kiến thức/công nghệ/đời sống kèm mốc [mm:ss].\n'
                  '• Tạo/Xuất .srt: Trích lời thoại thành file phụ đề .srt để tải về hoặc đọc sâu từng đoạn video dài.',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11.5,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Thử hỏi ngay:',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          for (final s in samples)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                onTap: () => _submitText(s.text),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: geminiSurface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.07),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(s.icon, size: 17, color: _biliPink),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          s.text,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.arrow_forward_ios_rounded,
                        size: 13,
                        color: AppColors.textMuted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMessagesList(BilibiliAssistantController c) {
    final modelShort = shortLiveModelLabel(c.selectedModelId);

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      itemCount: c.messages.length,
      itemBuilder: (ctx, idx) {
        final msg = c.messages[idx];

        if (msg.isSystemNotice) {
          return Center(
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                msg.text,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 11.5,
                ),
              ),
            ),
          );
        }

        if (msg.isUser) {
          return Align(
            alignment: Alignment.centerRight,
            child: Container(
              margin: const EdgeInsets.only(left: 52, top: 4, bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: geminiPillSurface,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(6),
                ),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: SelectableText(
                msg.text,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13.5,
                  height: 1.4,
                ),
              ),
            ),
          );
        }

        final report = msg.searchReport;
        final suggestions = msg.titleSuggestions;
        return Container(
          margin: const EdgeInsets.only(top: 6, bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ShaderMask(
                    shaderCallback: (bounds) => const LinearGradient(
                      colors: [_biliPink, _biliCyan],
                    ).createShader(bounds),
                    child: const Icon(
                      Icons.auto_awesome_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Gemini · $modelShort',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              if (msg.text.trim().isNotEmpty || msg.isStreaming)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 2, right: 6),
                  child: SelectableText(
                    msg.text.trim().isEmpty ? 'Đang suy nghĩ...' : msg.text,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13.5,
                      height: 1.5,
                    ),
                  ),
                ),
              if (suggestions != null && suggestions.suggestions.isNotEmpty) ...[
                const SizedBox(height: 10),
                LiveChineseTitleSuggestionsCard(
                  batch: suggestions,
                  accentColor: _biliCyan,
                ),
              ],
              if (report != null && report.candidates.isNotEmpty) ...[
                const SizedBox(height: 10),
                _buildSearchResultGroup(c, report),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildSearchResultGroup(
    BilibiliAssistantController c,
    BilibiliSearchReport report,
  ) {
    final activeSrt = c.activeSrtSession;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.darkSurfaceVariant.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.cardBorder),
          ),
          child: Row(
            children: [
              const Icon(Icons.analytics_outlined, size: 13, color: _biliCyan),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  report.traceSummary,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 252,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: report.candidates.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (ctx, idx) {
              final cand = report.candidates[idx];
              final isPinned = c.pinnedKeys.contains(cand.candidateKey);
              return _BilibiliAssistantCard(
                candidate: cand,
                isPinned: isPinned,
                isRunningStt: c.isRunningManualStt,
                onTapWatch: () => _handleCandidatePrimaryTap(cand),
                onTapSummarizeStory: () => _askSummarizeCandidate(
                  cand,
                  summaryStyle: 'story',
                ),
                onTapSummarizeStructured: () => _askSummarizeCandidate(
                  cand,
                  summaryStyle: 'structured',
                ),
                onTapSttOrExport: () => _handleSrtAction(cand),
                onTogglePin: () {
                  HapticFeedback.selectionClick();
                  c.togglePinCandidate(cand.candidateKey);
                },
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            LiveAssistantActionPill(
              icon: Icons.summarize_rounded,
              label: 'Tổng hợp & so sánh top kết quả',
              accent: _biliCyan,
              onTap: () => _submitText(
                'Hãy tổng hợp so sánh các lựa chọn nổi bật nhất trong danh sách vừa rồi bằng Tiếng Việt dễ hiểu (kèm ưu nhược điểm và gợi ý nên xem mục nào nhất).',
              ),
            ),
            if (activeSrt != null && activeSrt.isLongVideo)
              LiveAssistantActionPill(
                icon: Icons.menu_book_rounded,
                label: 'Đọc tiếp đoạn SRT (${activeSrt.bvid})',
                accent: _biliPink,
                onTap: () => _submitText(
                  'Hãy gọi `read_srt_chunk` để đọc tiếp đoạn SRT tiếp theo của video ${activeSrt.bvid} và tóm tắt chi tiết kèm mốc thời gian.',
                ),
              ),
            LiveAssistantActionPill(
              icon: Icons.grid_view_rounded,
              label: 'Đưa ra lưới Bilibili',
              accent: AppColors.primaryEmerald,
              onTap: () {
                HapticFeedback.lightImpact();
                widget.onApplyToMainGrid(
                  report.candidates.map((e) => e.item).toList(),
                  report.traceSummary,
                );
                Navigator.pop(context);
              },
            ),
            LiveAssistantActionPill(
              icon: Icons.expand_more_rounded,
              label: 'Mở rộng rộng hơn',
              accent: AppColors.accentGold,
              onTap: () => _submitText(
                'Hãy mở rộng tìm kiếm với nhiều từ khóa đồng nghĩa rộng hơn trên Bilibili nhưng vẫn đúng chủ đề trước đó.',
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBusyStrip(BilibiliAssistantController c) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      color: geminiSurface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: c.isAiSpeaking ? _biliCyan : _biliPink,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  c.isAiSpeaking
                      ? 'Gemini đang nói... (bạn có thể gõ hoặc bật Mic để ngắt)'
                      : (c.busyLabel.isNotEmpty
                          ? c.busyLabel
                          : 'Gemini đang xử lý...'),
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (c.sttProgress != null) ...[
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: c.sttProgress,
                minHeight: 3,
                backgroundColor: Colors.white12,
                color: _biliCyan,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPinnedStrip(BilibiliAssistantController c) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      color: geminiSurface,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            const Text(
              'Đang chọn:',
              style: TextStyle(color: AppColors.textMuted, fontSize: 11),
            ),
            const SizedBox(width: 6),
            for (final key in c.pinnedKeys) ...[
              Builder(
                builder: (_) {
                  final cand = c.engine.getByKey(key);
                  final label = cand != null
                      ? '#${cand.displayIndex} ${cand.viTitle}'
                      : key;
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: _biliCyan.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _biliCyan.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 160),
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _biliCyan,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          GestureDetector(
                            onTap: () => c.unpinCandidate(key),
                            child: const Icon(
                              Icons.close_rounded,
                              size: 13,
                              color: _biliCyan,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
            TextButton(
              onPressed: c.clearPins,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'Bỏ hết',
                style: TextStyle(color: AppColors.textMuted, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterDropdownPill extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final Color activeColor;
  final bool showArrow;
  final VoidCallback? onTap;

  const _FilterDropdownPill({
    required this.label,
    required this.icon,
    required this.selected,
    required this.activeColor,
    this.showArrow = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: selected
            ? activeColor.withValues(alpha: 0.16)
            : geminiPillSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected
              ? activeColor.withValues(alpha: 0.68)
              : Colors.white.withValues(alpha: 0.09),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 12.5,
            color: selected ? activeColor : AppColors.textMuted,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: selected ? activeColor : AppColors.textSecondary,
              fontSize: 11,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          if (showArrow) ...[
            const SizedBox(width: 1),
            Icon(
              Icons.arrow_drop_down_rounded,
              size: 15,
              color: selected ? activeColor : AppColors.textMuted,
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return pill;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: pill,
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color activeColor;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.activeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? activeColor.withValues(alpha: 0.18)
              : geminiPillSurface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? activeColor.withValues(alpha: 0.7)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? activeColor : AppColors.textSecondary,
            fontSize: 11,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _BilibiliAssistantCard extends StatelessWidget {
  final BilibiliAssistantCandidate candidate;
  final bool isPinned;
  final bool isRunningStt;
  final VoidCallback onTapWatch;
  final VoidCallback onTapSummarizeStory;
  final VoidCallback onTapSummarizeStructured;
  final VoidCallback onTapSttOrExport;
  final VoidCallback onTogglePin;

  const _BilibiliAssistantCard({
    required this.candidate,
    required this.isPinned,
    required this.isRunningStt,
    required this.onTapWatch,
    required this.onTapSummarizeStory,
    required this.onTapSummarizeStructured,
    required this.onTapSttOrExport,
    required this.onTogglePin,
  });

  @override
  Widget build(BuildContext context) {
    final item = candidate.item;
    final isVideo = candidate.kind == BilibiliCandidateKind.video;

    return Container(
      width: 236,
      decoration: BoxDecoration(
        color: geminiSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isPinned ? _biliCyan : Colors.white.withValues(alpha: 0.08),
          width: isPinned ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 16:9 Thumbnail clickable to open/play
          InkWell(
            onTap: onTapWatch,
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (item.cover.isNotEmpty)
                    Image.network(
                      item.cover,
                      fit: BoxFit.cover,
                      cacheWidth: 420,
                      errorBuilder: (_, _, _) => Container(
                        color: const Color(0xFF232734),
                        child: Icon(
                          candidate.kind == BilibiliCandidateKind.upChannel
                              ? Icons.person_rounded
                              : Icons.ondemand_video_rounded,
                          color: Colors.white24,
                          size: 32,
                        ),
                      ),
                    )
                  else
                    Container(
                      color: const Color(0xFF232734),
                      child: const Icon(
                        Icons.ondemand_video_rounded,
                        color: Colors.white24,
                        size: 32,
                      ),
                    ),
                  // Bottom scrim
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.72),
                          ],
                          stops: const [0.55, 1.0],
                        ),
                      ),
                    ),
                  ),
                  // #STT badge
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _biliPink,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '#${candidate.displayIndex}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  // SRT Loaded badge
                  if (candidate.hasSrtInMemory)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primaryEmerald,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'SRT ${candidate.srtChunkCount}đ',
                          style: const TextStyle(
                            color: Colors.black,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  // Duration / views bottom bar
                  Positioned(
                    left: 6,
                    right: 6,
                    bottom: 4,
                    child: Row(
                      children: [
                        if (item.viewCountText.isNotEmpty) ...[
                          const Icon(
                            Icons.play_arrow_rounded,
                            size: 12,
                            color: Colors.white70,
                          ),
                          Text(
                            item.viewCountText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                        const Spacer(),
                        if (item.durationText.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.65),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              item.durationText,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Details + Action Buttons
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: onTapWatch,
                    child: Text(
                      candidate.viTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (item.author.isNotEmpty) item.author,
                      if (item.publishedAtText.isNotEmpty) item.publishedAtText,
                      if (candidate.sourceBadge.isNotEmpty)
                        candidate.sourceBadge,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 9.5,
                    ),
                  ),
                  const Spacer(),
                  if (candidate.kind == BilibiliCandidateKind.upChannel)
                    Row(
                      children: [
                        Expanded(
                          child: _MiniCardButton(
                            label: 'Xem video kênh',
                            icon: Icons.video_library_rounded,
                            color: _biliCyan,
                            onTap: onTapSummarizeStructured,
                          ),
                        ),
                      ],
                    )
                  else
                    Row(
                      children: [
                        Expanded(
                          child: _MiniCardButton(
                            label: 'Cốt truyện',
                            icon: Icons.auto_stories_rounded,
                            color: _biliPink,
                            onTap: onTapSummarizeStory,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: _MiniCardButton(
                            label: 'Ý chính',
                            icon: Icons.fact_check_rounded,
                            color: _biliCyan,
                            onTap: onTapSummarizeStructured,
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (isVideo && candidate.bvid.isNotEmpty) ...[
                        Expanded(
                          child: _MiniCardButton(
                            label: candidate.hasSrtInMemory
                                ? 'Xuất .srt'
                                : 'Tạo .srt',
                            icon: candidate.hasSrtInMemory
                                ? Icons.download_done_rounded
                                : Icons.subtitles_rounded,
                            color: candidate.hasSrtInMemory
                                ? AppColors.primaryEmerald
                                : Colors.amberAccent,
                            onTap: isRunningStt ? null : onTapSttOrExport,
                          ),
                        ),
                        const SizedBox(width: 4),
                      ] else
                        const Spacer(),
                      // Ghim
                      InkWell(
                        onTap: onTogglePin,
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: isPinned
                                ? _biliCyan.withValues(alpha: 0.22)
                                : geminiPillSurface,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: isPinned
                                  ? _biliCyan
                                  : Colors.white.withValues(alpha: 0.1),
                            ),
                          ),
                          child: Icon(
                            isPinned
                                ? Icons.push_pin_rounded
                                : Icons.push_pin_outlined,
                            size: 13,
                            color: isPinned ? _biliCyan : AppColors.textMuted,
                          ),
                        ),
                      ),
                      if (isVideo) const SizedBox(width: 4),
                      // Bookmark Xem sau
                      if (isVideo)
                        ValueListenableBuilder<List<WatchLaterItem>>(
                          valueListenable:
                              WatchLaterRepository.watchLaterNotifier,
                          builder: (ctx, wlItems, _) {
                            final bvid = candidate.bvid;
                            final isWl = wlItems.any(
                              (w) =>
                                  (bvid.isNotEmpty &&
                                      (w.targetUrl.contains(bvid) ||
                                          w.id.contains(bvid))) ||
                                  w.targetUrl == item.targetPlayUrl,
                            );
                            return InkWell(
                              onTap: () async {
                                final repo =
                                    await WatchLaterRepository.getInstance();
                                await repo.toggleWatchLater(
                                  WatchLaterItem(
                                    id: 'bili_${bvid.isNotEmpty ? bvid : item.title.hashCode}',
                                    title: item.title,
                                    coverUrl: item.cover,
                                    source: 'bilibili',
                                    targetUrl: item.targetPlayUrl,
                                    author: item.author,
                                    addedAt:
                                        DateTime.now().millisecondsSinceEpoch,
                                  ),
                                );
                              },
                              borderRadius: BorderRadius.circular(6),
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: geminiPillSurface,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.1),
                                  ),
                                ),
                                child: Icon(
                                  isWl
                                      ? Icons.bookmark_added_rounded
                                      : Icons.bookmark_add_outlined,
                                  size: 13,
                                  color:
                                      isWl ? _biliCyan : AppColors.textMuted,
                                ),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniCardButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  const _MiniCardButton({
    required this.label,
    required this.icon,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
