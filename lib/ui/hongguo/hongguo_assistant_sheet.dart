import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/model/watch_later_item.dart';
import '../../data/repository/watch_later_repository.dart';
import '../../domain/ai/ai_model_registry.dart';
import '../../domain/media/hongguo/hongguo_assistant_engine.dart';
import '../../domain/media/hongguo_resolver.dart';
import '../../domain/media/network_header_helper.dart';
import '../settings/settings_screen.dart';
import '../theme/app_theme.dart';
import 'hongguo_assistant_controller.dart';

class HongguoAssistantSheet extends StatefulWidget {
  final HongguoAssistantController controller;
  final void Function(HongguoDramaItem drama) onOpenDrama;
  final void Function(List<HongguoDramaItem> items, String label)
  onApplyToMainGrid;

  const HongguoAssistantSheet({
    super.key,
    required this.controller,
    required this.onOpenDrama,
    required this.onApplyToMainGrid,
  });

  static Future<void> show(
    BuildContext context, {
    required HongguoAssistantController controller,
    required void Function(HongguoDramaItem drama) onOpenDrama,
    required void Function(List<HongguoDramaItem> items, String label)
    onApplyToMainGrid,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => HongguoAssistantSheet(
        controller: controller,
        onOpenDrama: onOpenDrama,
        onApplyToMainGrid: onApplyToMainGrid,
      ),
    );
  }

  @override
  State<HongguoAssistantSheet> createState() => _HongguoAssistantSheetState();
}

class _HongguoAssistantSheetState extends State<HongguoAssistantSheet> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _showFiltersBar = true;
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

  Future<void> _pickCustomCountDialog() async {
    final ctrl = TextEditingController(
      text: (widget.controller.preferredCount ?? 5).toString(),
    );
    final res = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.cardBorder),
        ),
        title: const Text(
          'Số lượng phim gợi ý',
          style: TextStyle(color: AppColors.textPrimary, fontSize: 16),
        ),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: const InputDecoration(
            hintText: 'Nhập số từ 1 đến 20',
            hintStyle: TextStyle(color: AppColors.textMuted),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryEmerald,
              foregroundColor: Colors.black,
            ),
            onPressed: () {
              final n = int.tryParse(ctrl.text.trim());
              if (n != null && n >= 1 && n <= 20) {
                Navigator.pop(ctx, n);
              }
            },
            child: const Text('Áp dụng'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (res != null) {
      widget.controller.setPreferredCount(res);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final screenH = MediaQuery.of(context).size.height;

    return Container(
      height: screenH * 0.90,
      decoration: const BoxDecoration(
        color: AppColors.darkBackground,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        border: Border(top: BorderSide(color: AppColors.cardBorder)),
      ),
      child: Column(
        children: [
          _buildHeader(c),
          _buildModelSelectorBar(c),
          if (_showFiltersBar) _buildGuidedFiltersBar(c),
          if (c.errorBanner != null || !c.hasApiKeys) _buildNoticeOrKeyBanner(c),
          Expanded(
            child: c.messages.isEmpty
                ? _buildEmptyGuideView(c)
                : _buildMessagesList(c),
          ),
          if (c.isAssistantBusy || c.isAiSpeaking) _buildBusyStrip(c),
          if (c.pinnedSeriesIds.isNotEmpty) _buildPinnedStrip(c),
          Padding(
            padding: EdgeInsets.only(bottom: bottomInset),
            child: _buildInputBar(c),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(HongguoAssistantController c) {
    final (statusLabel, statusColor) = switch (c.connectionState) {
      AssistantConnectionState.ready => (
        c.isMicActive
            ? 'Đang nghe'
            : (c.isAiSpeaking ? 'Đang nói' : 'Live Sẵn sàng'),
        AppColors.primaryEmerald,
      ),
      AssistantConnectionState.connecting => ('Đang kết nối...', Colors.amber),
      AssistantConnectionState.reconnecting => (
        'Đang nối lại phiên...',
        Colors.amber,
      ),
      AssistantConnectionState.error => ('Cần kiểm tra', Colors.redAccent),
      AssistantConnectionState.disconnected => (
        'Chờ tin nhắn',
        AppColors.textMuted,
      ),
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 8, bottom: 4),
          width: 38,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 10, 6),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppColors.primaryEmerald.withValues(alpha: 0.28),
                      AppColors.accentGold.withValues(alpha: 0.18),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppColors.primaryEmerald.withValues(alpha: 0.5),
                  ),
                ),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  size: 18,
                  color: AppColors.primaryEmerald,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Trợ lý AI Hồng Quả',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: statusColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            statusLabel,
                            style: TextStyle(
                              color: statusColor,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Công tắc đầu ra: Chữ / Lời nói
              InkWell(
                onTap: () {
                  HapticFeedback.selectionClick();
                  c.setOutputAudioEnabled(!c.outputAudioEnabled);
                },
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: c.outputAudioEnabled
                        ? AppColors.primaryEmerald.withValues(alpha: 0.2)
                        : AppColors.darkSurfaceVariant,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: c.outputAudioEnabled
                          ? AppColors.primaryEmerald
                          : AppColors.cardBorder,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        c.outputAudioEnabled
                            ? Icons.volume_up_rounded
                            : Icons.text_snippet_rounded,
                        size: 14,
                        color: c.outputAudioEnabled
                            ? AppColors.primaryEmerald
                            : AppColors.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        c.outputAudioEnabled ? 'Lời nói' : 'Chỉ Chữ',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: c.outputAudioEnabled
                              ? AppColors.primaryEmerald
                              : AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: _showFiltersBar
                    ? 'Ẩn thanh bộ lọc nhanh'
                    : 'Hiện thanh bộ lọc nhanh',
                icon: Icon(
                  Icons.tune_rounded,
                  size: 19,
                  color: _showFiltersBar
                      ? AppColors.accentGold
                      : AppColors.textMuted,
                ),
                onPressed: () =>
                    setState(() => _showFiltersBar = !_showFiltersBar),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Phiên trò chuyện mới',
                icon: const Icon(
                  Icons.restart_alt_rounded,
                  size: 19,
                  color: AppColors.textSecondary,
                ),
                onPressed: () {
                  HapticFeedback.lightImpact();
                  c.resetConversation();
                },
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Thu gọn',
                icon: const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: AppColors.textSecondary,
                ),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildModelSelectorBar(HongguoAssistantController c) {
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: AiModelRegistry.geminiLiveModels.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (ctx, i) {
          final m = AiModelRegistry.geminiLiveModels[i];
          final selected = c.selectedModelId == m.id;
          return ChoiceChip(
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            label: Text(
              m.displayName,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                color: selected ? Colors.white : AppColors.textSecondary,
              ),
            ),
            selected: selected,
            selectedColor: AppColors.primaryEmerald.withValues(alpha: 0.25),
            backgroundColor: AppColors.darkSurface,
            side: BorderSide(
              color: selected ? AppColors.primaryEmerald : AppColors.cardBorder,
            ),
            onSelected: (_) {
              HapticFeedback.selectionClick();
              c.switchModel(m.id);
            },
          );
        },
      ),
    );
  }

  Widget _buildGuidedFiltersBar(HongguoAssistantController c) {
    const sources = [
      (slug: '', label: 'Tất cả'),
      (slug: 'category/real-drama', label: '🎬 Người thật'),
      (slug: 'category/comic-drama', label: '🎨 Hoạt hình'),
      (slug: 'category/ai-drama', label: '🤖 Phim AI'),
    ];
    const counts = [3, 5, 10, 15];

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 6, 14, 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 28,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: sources.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (_, i) {
                final s = sources[i];
                final selected = c.sourceFilter == s.slug;
                return ChoiceChip(
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  label: Text(
                    s.label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                      color: selected ? Colors.white : AppColors.textSecondary,
                    ),
                  ),
                  selected: selected,
                  selectedColor: AppColors.primaryEmerald.withValues(alpha: 0.3),
                  backgroundColor: Colors.transparent,
                  side: BorderSide(
                    color: selected
                        ? AppColors.primaryEmerald
                        : AppColors.cardBorder.withValues(alpha: 0.7),
                  ),
                  onSelected: (_) {
                    HapticFeedback.selectionClick();
                    c.setSourceFilter(s.slug);
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Text(
                'Số lượng:',
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.accentGold,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: SizedBox(
                  height: 26,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final n in counts) ...[
                        _CountChip(
                          label: '$n',
                          selected: c.preferredCount == n,
                          onTap: () => c.setPreferredCount(n),
                        ),
                        const SizedBox(width: 5),
                      ],
                      _CountChip(
                        label: (c.preferredCount != null &&
                                !counts.contains(c.preferredCount))
                            ? '${c.preferredCount} (Tùy chỉnh)'
                            : 'Tùy chỉnh...',
                        selected: c.preferredCount != null &&
                            !counts.contains(c.preferredCount),
                        onTap: _pickCustomCountDialog,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNoticeOrKeyBanner(HongguoAssistantController c) {
    final needsKey = !c.hasApiKeys;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded,
              color: Colors.redAccent, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              needsKey
                  ? 'Bạn chưa thêm Gemini API Key. Hãy nhập key để dùng Trợ lý Live.'
                  : (c.errorBanner ?? ''),
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
          if (needsKey)
            TextButton(
              onPressed: _openSettingsForKey,
              child: const Text(
                'Mở Cài đặt',
                style: TextStyle(
                  color: AppColors.primaryEmerald,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyGuideView(HongguoAssistantController c) {
    final presets = [
      (
        icon: Icons.favorite_rounded,
        color: Colors.pinkAccent,
        title: 'Tìm theo mô tả chi tiết (Hẹp → Rộng)',
        subtitle:
            'Ví dụ: Học đường thanh xuân, nữ chính mạnh mẽ, tình yêu ngọt ngào',
        prompt:
            'Tìm cho mình ${c.preferredCount ?? 5} phim học đường thanh xuân, nữ chính mạnh mẽ, tình yêu ngọt ngào.',
      ),
      (
        icon: Icons.smart_toy_rounded,
        color: AppColors.primaryEmerald,
        title: 'Tìm Phim AI / Hoạt hình theo thể loại',
        subtitle: 'Mạt thế sinh tồn, não động hệ thống, tu tiên huyền huyễn',
        prompt:
            'Tìm ${c.preferredCount ?? 5} phim AI hoặc hoạt hình thể loại mạt thế sinh tồn hoặc hệ thống kịch tính.',
      ),
      (
        icon: Icons.leaderboard_rounded,
        color: AppColors.accentGold,
        title: 'Tra cứu 10 Bảng Xếp Hạng Hồng Quả',
        subtitle: 'Phim mới ra, Điểm cao uy tín, Nhiều người sưu tầm, Phải xem',
        prompt:
            'Lấy giúp mình Top ${c.preferredCount ?? 5} phim trong BXH Điểm cao uy tín và tóm tắt nhanh từng bộ.',
      ),
      (
        icon: Icons.auto_stories_rounded,
        color: Colors.lightBlueAccent,
        title: 'Xem xong danh sách ➔ Tổng hợp hết cốt truyện',
        subtitle:
            'Sau khi có danh sách, chỉ cần chạm 1 nút hoặc nói "phim số 2" để AI tóm tắt',
        prompt: null,
      ),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.darkSurface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.cardBorder),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Cách dùng Trợ lý hiệu quả nhất:',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 13.5,
                ),
              ),
              SizedBox(height: 6),
              Text(
                '• Chọn Nguồn & Số lượng ngay thanh trên (hoặc nói trực tiếp).\n'
                '• Mô tả cốt truyện bằng Tiếng Việt — AI tự tách từ khóa Trung từ hẹp tới rộng và kết hợp tag thật của app.\n'
                '• Không cần gõ tiếng Trung: bấm Ghim trên thẻ phim hoặc nói "phim số 2" để hỏi tiếp / tóm tắt.',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        for (final p in presets)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              onTap: p.prompt == null ? null : () => _submitText(p.prompt),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: AppColors.darkSurface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: p.color.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(p.icon, color: p.color, size: 18),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.title,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.bold,
                              fontSize: 12.5,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            p.subtitle,
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (p.prompt != null)
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
    );
  }

  Widget _buildMessagesList(HongguoAssistantController c) {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      itemCount: c.messages.length,
      itemBuilder: (ctx, i) {
        final msg = c.messages[i];
        if (msg.isSystemNotice) {
          return Center(
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.darkSurfaceVariant,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: Text(
                msg.text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 11,
                ),
              ),
            ),
          );
        }

        if (msg.isUser) {
          return Align(
            alignment: Alignment.centerRight,
            child: Container(
              margin: const EdgeInsets.only(left: 44, top: 4, bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.primaryEmerald.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: AppColors.primaryEmerald.withValues(alpha: 0.45),
                ),
              ),
              child: Text(
                msg.text,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ),
          );
        }

        // Assistant bubble + Rich Movie Cards
        final report = msg.searchReport;
        return Container(
          margin: const EdgeInsets.only(right: 12, top: 4, bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (msg.text.trim().isNotEmpty || msg.isStreaming)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.darkSurface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.cardBorder),
                  ),
                  child: SelectableText(
                    msg.text.trim().isEmpty
                        ? 'Đang suy nghĩ...'
                        : msg.text,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ),
              if (report != null && report.candidates.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildSearchResultGroup(c, report),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildSearchResultGroup(
    HongguoAssistantController c,
    HongguoSearchReport report,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Dòng minh bạch tìm kiếm (Search Transparency Strip)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.darkSurfaceVariant.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.cardBorder),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.analytics_outlined,
                size: 13,
                color: AppColors.accentGold,
              ),
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
        // Thẻ phim tương tác đánh số #1..#N
        SizedBox(
          height: 238,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: report.candidates.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (ctx, idx) {
              final cand = report.candidates[idx];
              final isPinned = c.pinnedSeriesIds.contains(cand.seriesId);
              return _AssistantMovieCard(
                candidate: cand,
                isPinned: isPinned,
                onTapWatch: () => widget.onOpenDrama(cand.item),
                onTogglePin: () {
                  HapticFeedback.selectionClick();
                  c.togglePinCandidate(cand.seriesId);
                },
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        // Thanh hành động tiếp nối 1 chạm (tránh chat phiếm)
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _ActionPillButton(
              icon: Icons.auto_stories_rounded,
              label: 'Tổng hợp cốt truyện & chọn phim sát nhất',
              accent: AppColors.accentGold,
              onTap: () => _submitText(
                'Hãy tổng hợp và so sánh hết cốt truyện của toàn bộ danh sách phim vừa rồi, chỉ ra phim sát mô tả của mình nhất và tóm tắt chi tiết bằng tiếng Việt.',
              ),
            ),
            _ActionPillButton(
              icon: Icons.grid_view_rounded,
              label: 'Đưa ra lưới Hồng Quả',
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
            _ActionPillButton(
              icon: Icons.expand_more_rounded,
              label: 'Mở rộng rộng hơn',
              accent: Colors.lightBlueAccent,
              onTap: () => _submitText(
                'Hãy mở rộng tìm kiếm với nhiều từ khóa rộng hơn nhưng vẫn giữ đúng tinh thần yêu cầu trước đó.',
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBusyStrip(HongguoAssistantController c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      color: AppColors.darkSurface,
      child: Row(
        children: [
          if (c.isAiSpeaking)
            const Icon(
              Icons.graphic_eq_rounded,
              size: 16,
              color: AppColors.primaryEmerald,
            )
          else
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.primaryEmerald,
              ),
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              c.isAiSpeaking && c.busyLabel.isEmpty
                  ? 'Trợ lý đang đọc câu trả lời...'
                  : c.busyLabel,
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
    );
  }

  Widget _buildPinnedStrip(HongguoAssistantController c) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      color: AppColors.darkSurface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 28,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                const Center(
                  child: Text(
                    'Đang ghim:',
                    style: TextStyle(
                      color: AppColors.accentGold,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                for (final id in c.pinnedSeriesIds) ...[
                  Builder(
                    builder: (_) {
                      final cand = c.engine.getBySeriesId(id);
                      final title = cand != null
                          ? '#${cand.displayIndex} ${cand.viTitle}'
                          : id;
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: InputChip(
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          label: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 160),
                            child: Text(
                              title,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          backgroundColor:
                              AppColors.primaryEmerald.withValues(alpha: 0.2),
                          side: const BorderSide(color: AppColors.primaryEmerald),
                          deleteIconColor: Colors.white70,
                          onDeleted: () => c.unpinCandidate(id),
                        ),
                      );
                    },
                  ),
                ],
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  label: const Text(
                    '✨ Tóm tắt phim ghim',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.accentGold,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  backgroundColor: Colors.transparent,
                  side: BorderSide(
                    color: AppColors.accentGold.withValues(alpha: 0.6),
                  ),
                  onPressed: () => _submitText(
                    'Hãy tổng hợp và tóm tắt chi tiết cốt truyện của các phim mình đang ghim ở trên.',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar(HongguoAssistantController c) {
    final hasText = _inputController.text.trim().isNotEmpty;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: const BoxDecoration(
        color: AppColors.darkSurface,
        border: Border(top: BorderSide(color: AppColors.cardBorder)),
      ),
      child: Row(
        children: [
          // Nút Micro thu âm Live Voice
          GestureDetector(
            onTap: () {
              HapticFeedback.mediumImpact();
              c.toggleMic();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.isMicActive
                    ? Colors.redAccent
                    : AppColors.darkSurfaceVariant,
                border: Border.all(
                  color: c.isMicActive
                      ? Colors.redAccent.shade100
                      : AppColors.cardBorder,
                  width: c.isMicActive ? (1.5 + c.micLevel * 2.5) : 1.0,
                ),
                boxShadow: c.isMicActive
                    ? [
                        BoxShadow(
                          color: Colors.redAccent.withValues(
                            alpha: 0.35 + c.micLevel * 0.4,
                          ),
                          blurRadius: 10 + c.micLevel * 8,
                        ),
                      ]
                    : null,
              ),
              child: Icon(
                c.isMicActive ? Icons.stop_rounded : Icons.mic_rounded,
                color: c.isMicActive ? Colors.white : AppColors.primaryEmerald,
                size: 22,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.darkSurfaceVariant,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: TextField(
                controller: _inputController,
                textInputAction: TextInputAction.send,
                maxLines: 3,
                minLines: 1,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submitText(),
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13.5,
                ),
                decoration: InputDecoration(
                  hintText: c.isMicActive
                      ? 'Đang thu âm... Bấm nút đỏ để gửi xong'
                      : 'Mô tả phim, gọi "phim số 2" hoặc gõ lệnh...',
                  hintStyle: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12.5,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: hasText ? () => _submitText() : null,
            borderRadius: BorderRadius.circular(22),
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hasText
                    ? AppColors.primaryEmerald
                    : AppColors.darkSurfaceVariant,
              ),
              child: Icon(
                Icons.send_rounded,
                size: 19,
                color: hasText ? Colors.black : AppColors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AssistantMovieCard extends StatelessWidget {
  final HongguoAssistantCandidate candidate;
  final bool isPinned;
  final VoidCallback onTapWatch;
  final VoidCallback onTogglePin;

  const _AssistantMovieCard({
    required this.candidate,
    required this.isPinned,
    required this.onTapWatch,
    required this.onTogglePin,
  });

  @override
  Widget build(BuildContext context) {
    final item = candidate.item;
    final hasValidCover =
        item.cover.isNotEmpty && !item.cover.contains('empty_play');

    return Container(
      width: 152,
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isPinned ? AppColors.primaryEmerald : AppColors.cardBorder,
          width: isPinned ? 1.6 : 1.0,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Poster + badges + chạm để mở xem ngay
          Expanded(
            child: InkWell(
              onTap: onTapWatch,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  hasValidCover
                      ? Image.network(
                          item.cover,
                          headers: NetworkHeaderHelper.getHeadersForUrl(
                            item.cover,
                          ),
                          cacheWidth: 280,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            color: AppColors.darkSurfaceVariant,
                            child: const Icon(
                              Icons.movie_rounded,
                              color: AppColors.textMuted,
                            ),
                          ),
                        )
                      : Container(
                          color: AppColors.darkSurfaceVariant,
                          child: const Icon(
                            Icons.movie_rounded,
                            color: AppColors.textMuted,
                          ),
                        ),
                  // Badge #STT to rõ để user dễ nói với AI không cần đọc tiếng Trung
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.78),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppColors.primaryEmerald),
                      ),
                      child: Text(
                        '#${candidate.displayIndex}',
                        style: const TextStyle(
                          color: AppColors.primaryEmerald,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  if (item.episodeCount > 0)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.72),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          '${item.episodeCount}T',
                          style: const TextStyle(
                            color: AppColors.accentGold,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      color: Colors.black.withValues(alpha: 0.68),
                      child: Text(
                        candidate.sourceBadge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: candidate.sourceConfidence ==
                                  HongguoSourceConfidence.confirmed
                              ? AppColors.primaryEmerald
                              : Colors.amberAccent,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Tên tiếng Việt + Tên gốc + Nút Ghim/Lưu
          Padding(
            padding: const EdgeInsets.fromLTRB(7, 6, 7, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  onTap: onTapWatch,
                  child: Text(
                    candidate.viTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      height: 1.2,
                    ),
                  ),
                ),
                if (candidate.viTitle != item.title) ...[
                  const SizedBox(height: 1),
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 9.5,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  candidate.matchReason,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.accentGold,
                    fontSize: 9.5,
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: onTogglePin,
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          decoration: BoxDecoration(
                            color: isPinned
                                ? AppColors.primaryEmerald.withValues(
                                    alpha: 0.25,
                                  )
                                : AppColors.darkSurfaceVariant,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: isPinned
                                  ? AppColors.primaryEmerald
                                  : AppColors.cardBorder,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              isPinned ? '✓ Đang ghim' : '✨ Hỏi #${candidate.displayIndex}',
                              style: TextStyle(
                                color: isPinned
                                    ? AppColors.primaryEmerald
                                    : AppColors.textSecondary,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                    ValueListenableBuilder<List<WatchLaterItem>>(
                      valueListenable: WatchLaterRepository.watchLaterNotifier,
                      builder: (ctx, wlItems, _) {
                        final isWl = wlItems.any(
                          (w) =>
                              w.seriesId == item.seriesId ||
                              w.id == 'hg_${item.seriesId}',
                        );
                        return InkWell(
                          onTap: () async {
                            final repo =
                                await WatchLaterRepository.getInstance();
                            await repo.toggleWatchLater(
                              WatchLaterItem(
                                id: 'hg_${item.seriesId}',
                                title: item.title,
                                coverUrl: item.cover,
                                source: 'hongguo',
                                targetUrl: item.seriesId,
                                seriesId: item.seriesId,
                                totalEpisodes: item.episodeCount > 0
                                    ? item.episodeCount
                                    : null,
                                addedAt:
                                    DateTime.now().millisecondsSinceEpoch,
                              ),
                            );
                          },
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: AppColors.darkSurfaceVariant,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: AppColors.cardBorder),
                            ),
                            child: Icon(
                              isWl
                                  ? Icons.bookmark_added_rounded
                                  : Icons.bookmark_add_outlined,
                              size: 14,
                              color: isWl
                                  ? AppColors.primaryEmerald
                                  : AppColors.textMuted,
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
        ],
      ),
    );
  }
}

class _CountChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CountChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          color: selected ? Colors.black : AppColors.textSecondary,
        ),
      ),
      selected: selected,
      selectedColor: AppColors.accentGold,
      backgroundColor: Colors.transparent,
      side: BorderSide(
        color: selected
            ? AppColors.accentGold
            : AppColors.cardBorder.withValues(alpha: 0.7),
      ),
      onSelected: (_) {
        HapticFeedback.selectionClick();
        onTap();
      },
    );
  }
}

class _ActionPillButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color accent;
  final VoidCallback onTap;

  const _ActionPillButton({
    required this.icon,
    required this.label,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: accent.withValues(alpha: 0.55)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: accent),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: accent,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
