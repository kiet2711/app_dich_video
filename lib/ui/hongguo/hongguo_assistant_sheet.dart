import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/model/watch_later_item.dart';
import '../../data/repository/watch_later_repository.dart';
import '../../domain/ai/ai_model_registry.dart';
import '../../domain/media/hongguo/hongguo_assistant_engine.dart';
import '../../domain/media/hongguo_resolver.dart';
import '../../domain/media/network_header_helper.dart';
import '../ai_assistant/live_assistant_shared_widgets.dart';
import '../settings/settings_screen.dart';
import '../theme/app_theme.dart';
import 'hongguo_assistant_controller.dart';

const _geminiBlue = Color(0xFF4285F4);
const _geminiPurple = Color(0xFF9B72CB);
const _geminiSurface = Color(0xFF171B24);
const _geminiPillSurface = Color(0xFF212633);

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

  Future<void> _openQuickKeyDialog() async {
    final ctrl = TextEditingController();
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _geminiSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
        title: const Text(
          'Nhập nhanh Gemini API Key',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Dán key AIza... (nhiều key cách nhau bởi dấu phẩy hoặc xuống dòng). Key sẽ được lưu vào Settings bảo mật.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              maxLines: 3,
              minLines: 2,
              autofocus: true,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12.5,
                fontFamily: 'monospace',
              ),
              decoration: InputDecoration(
                hintText: 'AIzaSy...',
                hintStyle: const TextStyle(color: AppColors.textMuted),
                filled: true,
                fillColor: AppColors.darkBackground,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _geminiBlue,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Lưu Key'),
          ),
        ],
      ),
    );
    ctrl.dispose();

    if (saved != null && saved.isNotEmpty) {
      await widget.controller.saveQuickGeminiKeys(saved);
    }
  }

  Future<void> _pickCustomCountDialog() async {
    final ctrl = TextEditingController(
      text: (widget.controller.preferredCount ?? 5).toString(),
    );
    final res = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _geminiSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
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
              backgroundColor: _geminiBlue,
              foregroundColor: Colors.white,
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

  String _shortModelLabel(String modelId) {
    return switch (modelId) {
      'gemini-3.8-live' => '3.8 Live',
      'gemini-3.8-live-extended-thinking' => '3.8 Thinking',
      'gemini-3.1-flash-live-preview' => '3 Flash Live',
      _ => modelId,
    };
  }

  ({IconData icon, String badge, String detail}) _modelPresentation(
    AiModelInfo m,
  ) {
    return switch (m.id) {
      'gemini-3.8-live' => (
        icon: Icons.auto_awesome_rounded,
        badge: 'Cân bằng',
        detail: 'Tốc độ nhanh, gọi hàm chính xác và hội thoại tự nhiên.',
      ),
      'gemini-3.8-live-extended-thinking' => (
        icon: Icons.psychology_rounded,
        badge: 'Suy luận sâu',
        detail:
            'Phân tích mô tả phim nhiều lớp, gom & đối chiếu cốt truyện kỹ hơn.',
      ),
      'gemini-3.1-flash-live-preview' => (
        icon: Icons.bolt_rounded,
        badge: 'Siêu nhanh',
        detail: 'Phản hồi văn bản & giọng nói độ trễ cực thấp.',
      ),
      _ => (
        icon: Icons.smart_toy_rounded,
        badge: 'Live',
        detail: m.shortDescription,
      ),
    };
  }

  Future<void> _showGeminiModelPickerSheet(HongguoAssistantController c) async {
    HapticFeedback.selectionClick();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetCtx) {
        final available = c.lastDiagnostics?.availableBidiModels ?? const [];
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 22),
          decoration: BoxDecoration(
            color: _geminiSurface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
            border: Border(
              top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Text(
                  'Chọn mô hình Gemini',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Chuyển mô hình bất cứ lúc nào mà vẫn giữ nguyên ngữ cảnh & danh sách phim.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 14),
                for (final m in AiModelRegistry.geminiLiveModels) ...[
                  Builder(
                    builder: (_) {
                      final selected = c.selectedModelId == m.id;
                      final meta = _modelPresentation(m);
                      final candidates =
                          AiModelRegistry.liveModelCandidateIds[m.id] ?? [m.id];
                      final isDiscovered =
                          available.isNotEmpty &&
                          candidates.any(available.contains);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: InkWell(
                          onTap: () {
                            HapticFeedback.selectionClick();
                            Navigator.pop(sheetCtx);
                            c.switchModel(m.id);
                          },
                          borderRadius: BorderRadius.circular(18),
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: selected
                                  ? _geminiBlue.withValues(alpha: 0.14)
                                  : _geminiPillSurface.withValues(alpha: 0.65),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: selected
                                    ? _geminiBlue.withValues(alpha: 0.75)
                                    : Colors.white.withValues(alpha: 0.08),
                                width: selected ? 1.4 : 1.0,
                              ),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 38,
                                  height: 38,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: selected
                                          ? [_geminiBlue, _geminiPurple]
                                          : [
                                              Colors.white.withValues(
                                                alpha: 0.08,
                                              ),
                                              Colors.white.withValues(
                                                alpha: 0.04,
                                              ),
                                            ],
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    meta.icon,
                                    color: selected
                                        ? Colors.white
                                        : AppColors.textSecondary,
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              m.displayName,
                                              style: const TextStyle(
                                                color: AppColors.textPrimary,
                                                fontSize: 14.5,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 7,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: selected
                                                  ? _geminiBlue.withValues(
                                                      alpha: 0.25,
                                                    )
                                                  : Colors.white.withValues(
                                                      alpha: 0.07,
                                                    ),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: Text(
                                              meta.badge,
                                              style: TextStyle(
                                                color: selected
                                                    ? Colors.lightBlueAccent
                                                    : AppColors.textSecondary,
                                                fontSize: 10,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        meta.detail,
                                        style: const TextStyle(
                                          color: AppColors.textSecondary,
                                          fontSize: 12,
                                          height: 1.35,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          Text(
                                            m.id,
                                            style: const TextStyle(
                                              color: AppColors.textMuted,
                                              fontSize: 10.5,
                                              fontFamily: 'monospace',
                                            ),
                                          ),
                                          if (available.isNotEmpty) ...[
                                            const SizedBox(width: 8),
                                            Text(
                                              isDiscovered
                                                  ? '• Có sẵn trên Key'
                                                  : '• Tự thử fallback',
                                              style: TextStyle(
                                                color: isDiscovered
                                                    ? AppColors.primaryEmerald
                                                    : AppColors.accentGold,
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Icon(
                                    selected
                                        ? Icons.check_circle_rounded
                                        : Icons.radio_button_unchecked_rounded,
                                    color: selected
                                        ? _geminiBlue
                                        : AppColors.textMuted,
                                    size: 22,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showSessionDiagnosticsSheet(
    HongguoAssistantController c,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final diag = c.lastDiagnostics;
            final isOk = c.isConnected;
            final isConnecting =
                c.connectionState == AssistantConnectionState.connecting ||
                c.connectionState == AssistantConnectionState.reconnecting;

            return Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.84,
              ),
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
              decoration: BoxDecoration(
                color: _geminiSurface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
                border: Border(
                  top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                ),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Icon(
                          isConnecting
                              ? Icons.sync_rounded
                              : (isOk
                                    ? Icons.verified_rounded
                                    : Icons.hub_outlined),
                          color: isConnecting
                              ? Colors.amber
                              : (isOk
                                    ? AppColors.primaryEmerald
                                    : (c.errorBanner != null
                                          ? Colors.redAccent
                                          : _geminiBlue)),
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Thông tin phiên Gemini Live & API Key',
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.close_rounded,
                            color: AppColors.textMuted,
                          ),
                          onPressed: () => Navigator.pop(sheetCtx),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Status Summary Card
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: _geminiPillSurface,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: isOk
                                      ? AppColors.primaryEmerald.withValues(
                                          alpha: 0.5,
                                        )
                                      : (c.errorBanner != null
                                            ? Colors.redAccent.withValues(
                                                alpha: 0.5,
                                              )
                                            : Colors.white.withValues(
                                                alpha: 0.08,
                                              )),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      if (isConnecting)
                                        const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.amber,
                                          ),
                                        )
                                      else
                                        Container(
                                          width: 9,
                                          height: 9,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: isOk
                                                ? AppColors.primaryEmerald
                                                : (c.errorBanner != null
                                                      ? Colors.redAccent
                                                      : Colors.white38),
                                          ),
                                        ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          isConnecting
                                              ? 'Đang kết nối tới Gemini Live...'
                                              : (isOk
                                                    ? 'Phiên Live đang hoạt động & sẵn sàng chat'
                                                    : (c.errorBanner ??
                                                          'Chưa mở phiên Live (sẽ tự kết nối khi bạn gửi tin nhắn).')),
                                          style: const TextStyle(
                                            color: AppColors.textPrimary,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  _diagRow(
                                    'Gemini API Key đã nạp',
                                    c.hasApiKeys
                                        ? '${c.maskedActiveKey} (${c.apiKeyCount} key)'
                                        : 'Chưa có key',
                                  ),
                                  _diagRow(
                                    'Model đang chọn',
                                    c.selectedModelId,
                                  ),
                                  _diagRow(
                                    'Model server phản hồi',
                                    c.resolvedServerModelId.isNotEmpty
                                        ? '${c.resolvedServerModelId} (${c.resolvedApiVersion})'
                                        : 'Chưa mở phiên',
                                  ),
                                  if (diag != null) ...[
                                    _diagRow(
                                      'Cấu hình phiên / Độ trễ',
                                      '${diag.profileLabel} · ${diag.latencyMs} ms',
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: AppColors.textPrimary,
                                      side: BorderSide(
                                        color: Colors.white.withValues(
                                          alpha: 0.14,
                                        ),
                                      ),
                                    ),
                                    onPressed: () async {
                                      await _openQuickKeyDialog();
                                      if (ctx.mounted) setModalState(() {});
                                    },
                                    icon: const Icon(
                                      Icons.vpn_key_outlined,
                                      size: 16,
                                    ),
                                    label: const Text('Dán Key nhanh'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: AppColors.textPrimary,
                                      side: BorderSide(
                                        color: Colors.white.withValues(
                                          alpha: 0.14,
                                        ),
                                      ),
                                    ),
                                    onPressed: () async {
                                      await _openSettingsForKey();
                                      if (ctx.mounted) setModalState(() {});
                                    },
                                    icon: const Icon(
                                      Icons.settings_outlined,
                                      size: 16,
                                    ),
                                    label: const Text('Mở Cài đặt'),
                                  ),
                                ),
                              ],
                            ),
                            if (diag != null &&
                                diag.availableBidiModels.isNotEmpty) ...[
                              const SizedBox(height: 14),
                              const Text(
                                'Model Live (BidiGenerateContent) Key hỗ trợ:',
                                style: TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final m in diag.availableBidiModels)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: m == c.resolvedServerModelId
                                            ? AppColors.primaryEmerald
                                                  .withValues(alpha: 0.2)
                                            : _geminiPillSurface,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: m == c.resolvedServerModelId
                                              ? AppColors.primaryEmerald
                                              : Colors.white.withValues(
                                                  alpha: 0.1,
                                                ),
                                        ),
                                      ),
                                      child: Text(
                                        m,
                                        style: TextStyle(
                                          color: m == c.resolvedServerModelId
                                              ? AppColors.primaryEmerald
                                              : AppColors.textSecondary,
                                          fontSize: 11,
                                          fontFamily: 'monospace',
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                            if (diag != null &&
                                diag.attemptLogs.isNotEmpty) ...[
                              const SizedBox(height: 14),
                              const Text(
                                'Nhật ký bắt tay gần nhất:',
                                style: TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: AppColors.darkBackground,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.08),
                                  ),
                                ),
                                child: SelectableText(
                                  diag.attemptLogs.join('\n'),
                                  style: const TextStyle(
                                    color: AppColors.textMuted,
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _geminiBlue,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: isConnecting
                            ? null
                            : () async {
                                await c.ensureConnected(
                                  seedContextSnapshot:
                                      c.messages.isNotEmpty ||
                                      c.engine.lastDisplayedCandidates.isNotEmpty,
                                  forceFreshSession: true,
                                  forceRefreshModelDiscovery: true,
                                );
                                if (ctx.mounted) setModalState(() {});
                              },
                        icon: isConnecting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.refresh_rounded, size: 19),
                        label: Text(
                          isConnecting
                              ? 'Đang kết nối...'
                              : (isOk ? 'Làm mới phiên Live' : 'Kết nối lại'),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _diagRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 11.5),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
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
          _buildSessionAndFilterStrip(c),
          if (!c.hasApiKeys || c.errorBanner != null)
            _buildNoticeOrKeyBanner(c),
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
    final shortModel = _shortModelLabel(c.selectedModelId);
    final isLive = c.isConnected;
    final isConnecting =
        c.connectionState == AssistantConnectionState.connecting ||
        c.connectionState == AssistantConnectionState.reconnecting;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 8, bottom: 4),
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 8, 6),
          child: Row(
            children: [
              // Gemini-style clickable Model Pill ở góc trái
              InkWell(
                onTap: () => _showGeminiModelPickerSheet(c),
                borderRadius: BorderRadius.circular(22),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: _geminiPillSurface,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: isLive
                          ? _geminiBlue.withValues(alpha: 0.45)
                          : Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ShaderMask(
                        shaderCallback: (bounds) => const LinearGradient(
                          colors: [
                            _geminiBlue,
                            _geminiPurple,
                            AppColors.primaryEmerald,
                          ],
                        ).createShader(bounds),
                        child: const Icon(
                          Icons.auto_awesome_rounded,
                          size: 17,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 7),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 145),
                        child: Text(
                          shortModel,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.1,
                          ),
                        ),
                      ),
                      if (isConnecting || isLive) ...[
                        const SizedBox(width: 6),
                        if (isConnecting)
                          const SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.8,
                              color: Colors.amber,
                            ),
                          )
                        else
                          Container(
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(
                              color: AppColors.primaryEmerald,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                      const SizedBox(width: 3),
                      const Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: AppColors.textSecondary,
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              // Công tắc đầu ra: Chữ / Lời nói
              InkWell(
                onTap: () {
                  HapticFeedback.selectionClick();
                  c.setOutputAudioEnabled(!c.outputAudioEnabled);
                },
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: c.outputAudioEnabled
                        ? AppColors.primaryEmerald.withValues(alpha: 0.18)
                        : _geminiPillSurface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: c.outputAudioEnabled
                          ? AppColors.primaryEmerald.withValues(alpha: 0.7)
                          : Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        c.outputAudioEnabled
                            ? Icons.volume_up_rounded
                            : Icons.notes_rounded,
                        size: 14,
                        color: c.outputAudioEnabled
                            ? AppColors.primaryEmerald
                            : AppColors.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        c.outputAudioEnabled ? 'Lời nói' : 'Chữ',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: c.outputAudioEnabled
                              ? AppColors.primaryEmerald
                              : AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 2),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Cuộc trò chuyện mới',
                icon: const Icon(
                  Icons.add_comment_outlined,
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
                tooltip: 'Đóng',
                icon: const Icon(
                  Icons.close_rounded,
                  size: 20,
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

  Widget _buildSessionAndFilterStrip(HongguoAssistantController c) {
    final diag = c.lastDiagnostics;
    final isTesting =
        c.connectionState == AssistantConnectionState.connecting ||
        c.connectionState == AssistantConnectionState.reconnecting;
    final isConnected = c.isConnected;
    final isError = c.connectionState == AssistantConnectionState.error;

    final Color dotColor = isTesting
        ? Colors.amber
        : (isConnected
              ? AppColors.primaryEmerald
              : (isError || !c.hasApiKeys
                    ? Colors.redAccent
                    : Colors.white38));

    final String sessionLabel;
    if (isTesting) {
      sessionLabel = 'Đang kết nối...';
    } else if (isConnected) {
      final ms = (diag != null && diag.latencyMs > 0)
          ? ' · ${diag.latencyMs}ms'
          : '';
      final keyText = c.maskedActiveKey.isNotEmpty
          ? ' · ${c.maskedActiveKey}'
          : '';
      sessionLabel = 'Live$keyText$ms';
    } else if (!c.hasApiKeys) {
      sessionLabel = 'Chưa có Key';
    } else if (isError) {
      sessionLabel = 'Lỗi kết nối';
    } else {
      sessionLabel = c.maskedActiveKey.isNotEmpty
          ? 'Chưa nối · ${c.maskedActiveKey}'
          : 'Chưa mở phiên';
    }

    final sourceLabel = switch (c.sourceFilter) {
      'category/real-drama' => 'Người thật',
      'category/comic-drama' => 'Hoạt hình',
      'category/ai-drama' => 'Phim AI',
      _ => 'Tất cả nguồn',
    };
    final countLabel = c.preferredCount != null
        ? '${c.preferredCount} phim'
        : 'SL mặc định';

    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        children: [
          // Pill Trạng thái phiên & Key (chạm để xem chi tiết / dán Key)
          InkWell(
            onTap: () => _showSessionDiagnosticsSheet(c),
            borderRadius: BorderRadius.circular(18),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _geminiSurface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isConnected
                      ? AppColors.primaryEmerald.withValues(alpha: 0.4)
                      : (isError
                            ? Colors.redAccent.withValues(alpha: 0.45)
                            : Colors.white.withValues(alpha: 0.08)),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isTesting)
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: Colors.amber,
                      ),
                    )
                  else
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: dotColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                  const SizedBox(width: 6),
                  Text(
                    sessionLabel,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Pill bật/tắt chế độ Chỉ đổi tên Việt -> Trung để copy tự tìm
          InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              c.setTitleTranslateOnly(!c.titleTranslateOnly);
            },
            borderRadius: BorderRadius.circular(18),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: c.titleTranslateOnly
                    ? _geminiBlue.withValues(alpha: 0.18)
                    : _geminiSurface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: c.titleTranslateOnly
                      ? _geminiBlue.withValues(alpha: 0.65)
                      : Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.translate_rounded,
                    size: 13.5,
                    color: c.titleTranslateOnly
                        ? Colors.lightBlueAccent
                        : AppColors.textSecondary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Tên Việt → Trung',
                    style: TextStyle(
                      color: c.titleTranslateOnly
                          ? Colors.white
                          : AppColors.textSecondary,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Pill chọn Nguồn phim (gọn 1 dòng)
          PopupMenuButton<String>(
            color: _geminiSurface,
            initialValue: c.sourceFilter,
            onSelected: (slug) {
              HapticFeedback.selectionClick();
              c.setSourceFilter(slug);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: '', child: Text('Tất cả nguồn')),
              PopupMenuItem(
                value: 'category/real-drama',
                child: Text('🎬 Phim Người thật'),
              ),
              PopupMenuItem(
                value: 'category/comic-drama',
                child: Text('🎨 Hoạt hình / Anime'),
              ),
              PopupMenuItem(
                value: 'category/ai-drama',
                child: Text('🤖 Phim AI'),
              ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: c.sourceFilter.isNotEmpty
                    ? AppColors.primaryEmerald.withValues(alpha: 0.16)
                    : _geminiSurface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: c.sourceFilter.isNotEmpty
                      ? AppColors.primaryEmerald.withValues(alpha: 0.5)
                      : Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.filter_list_rounded,
                    size: 13.5,
                    color: AppColors.textSecondary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    sourceLabel,
                    style: TextStyle(
                      color: c.sourceFilter.isNotEmpty
                          ? Colors.white
                          : AppColors.textSecondary,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 2),
                  const Icon(
                    Icons.arrow_drop_down_rounded,
                    size: 16,
                    color: AppColors.textMuted,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Pill chọn Số lượng gợi ý
          PopupMenuButton<int>(
            color: _geminiSurface,
            onSelected: (val) {
              HapticFeedback.selectionClick();
              if (val == -1) {
                _pickCustomCountDialog();
              } else {
                c.setPreferredCount(val);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 3, child: Text('3 phim')),
              PopupMenuItem(value: 5, child: Text('5 phim')),
              PopupMenuItem(value: 10, child: Text('10 phim')),
              PopupMenuItem(value: 15, child: Text('15 phim')),
              PopupMenuItem(value: -1, child: Text('Nhập số tùy chỉnh...')),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: c.preferredCount != null
                    ? AppColors.accentGold.withValues(alpha: 0.15)
                    : _geminiSurface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: c.preferredCount != null
                      ? AppColors.accentGold.withValues(alpha: 0.5)
                      : Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    countLabel,
                    style: TextStyle(
                      color: c.preferredCount != null
                          ? AppColors.accentGold
                          : AppColors.textSecondary,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 2),
                  const Icon(
                    Icons.arrow_drop_down_rounded,
                    size: 16,
                    color: AppColors.textMuted,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoticeOrKeyBanner(HongguoAssistantController c) {
    final needsKey = !c.hasApiKeys;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 8, 14, 2),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: _geminiSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            needsKey ? Icons.vpn_key_outlined : Icons.error_outline_rounded,
            color: Colors.redAccent,
            size: 19,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              needsKey
                  ? 'Chưa có Gemini API Key. Hãy dán key để bật Trợ lý Live.'
                  : (c.errorBanner ?? 'Lỗi kết nối Gemini Live.'),
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
                height: 1.35,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: needsKey
                ? _openQuickKeyDialog
                : () => _showSessionDiagnosticsSheet(c),
            child: Text(
              needsKey ? 'Nhập Key' : 'Chi tiết',
              style: const TextStyle(
                color: Colors.lightBlueAccent,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ),
          if (!needsKey)
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(
                Icons.close_rounded,
                size: 16,
                color: AppColors.textMuted,
              ),
              onPressed: c.clearErrorBanner,
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
            'Học đường thanh xuân, nữ chính mạnh mẽ, tình yêu ngọt ngào',
        prompt:
            'Tìm cho mình ${c.preferredCount ?? 5} phim học đường thanh xuân, nữ chính mạnh mẽ, tình yêu ngọt ngào.',
      ),
      (
        icon: Icons.smart_toy_rounded,
        color: AppColors.primaryEmerald,
        title: 'Tìm Phim AI / Hoạt hình theo thể loại',
        subtitle: 'Mạt thế sinh tồn, hệ thống, tu tiên huyền huyễn',
        prompt:
            'Tìm ${c.preferredCount ?? 5} phim AI hoặc hoạt hình thể loại mạt thế sinh tồn hoặc hệ thống kịch tính.',
      ),
      (
        icon: Icons.leaderboard_rounded,
        color: AppColors.accentGold,
        title: 'Tra cứu Bảng Xếp Hạng Hồng Quả',
        subtitle: 'Phim mới ra, Điểm cao uy tín, Nhiều người sưu tầm',
        prompt:
            'Lấy giúp mình Top ${c.preferredCount ?? 5} phim trong BXH Điểm cao uy tín và tóm tắt nhanh từng bộ.',
      ),
      (
        icon: Icons.translate_rounded,
        color: _geminiBlue,
        title: 'Đổi mô tả Việt → tên Trung (tự copy tìm)',
        subtitle:
            'Gợi ý tên tiếng Trung để tự tìm kiếm, không đề xuất thẻ phim',
        prompt:
            'Mình mô tả phim ngắn: "tổng tài giả nghèo cưới vợ thử lòng, sau lộ thân phận bảo vệ vợ". Hãy gợi ý tên tiếng Trung để mình tự copy tìm (không cần đề xuất phim).',
      ),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 16),
      children: [
        ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            colors: [_geminiBlue, _geminiPurple, AppColors.primaryEmerald],
          ).createShader(bounds),
          child: const Text(
            'Xin chào',
            style: TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Hỏi mình bất cứ gu phim nào trên Hồng Quả bằng tiếng Việt.',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13.5,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 22),
        for (final p in presets)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              onTap: () => _submitText(p.prompt),
              borderRadius: BorderRadius.circular(18),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 13,
                ),
                decoration: BoxDecoration(
                  color: _geminiSurface,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        color: p.color.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(p.icon, color: p.color, size: 19),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.title,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
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
    final modelShort = _shortModelLabel(c.selectedModelId);
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      itemCount: c.messages.length,
      itemBuilder: (ctx, i) {
        final msg = c.messages[i];
        if (msg.isSystemNotice) {
          return Center(
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 6),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              decoration: BoxDecoration(
                color: _geminiSurface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
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
              margin: const EdgeInsets.only(left: 52, top: 6, bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: _geminiPillSurface,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                  bottomLeft: Radius.circular(20),
                  bottomRight: Radius.circular(6),
                ),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: Text(
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

        // Gemini Assistant Turn + Rich Movie Cards
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
                      colors: [_geminiBlue, _geminiPurple],
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
                  accentColor: _geminiBlue,
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
                'Hãy tổng hợp và so sánh hết cốt truyện của toàn bộ danh sách phim vừa rồi, dùng tên Hán Việt tự nhiên (tuyệt đối không dùng Pinyin), chỉ ra phim sát mô tả của mình nhất và tóm tắt chi tiết bằng tiếng Việt.',
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: AppColors.darkBackground,
      child: Row(
        children: [
          if (c.isAiSpeaking)
            const Icon(
              Icons.graphic_eq_rounded,
              size: 16,
              color: _geminiBlue,
            )
          else
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: _geminiBlue,
              ),
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              c.isAiSpeaking && c.busyLabel.isEmpty
                  ? 'Gemini đang đọc câu trả lời...'
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
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
      color: AppColors.darkBackground,
      child: SizedBox(
        height: 30,
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
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
                      backgroundColor: _geminiBlue.withValues(alpha: 0.2),
                      side: BorderSide(color: _geminiBlue.withValues(alpha: 0.7)),
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
    );
  }

  Widget _buildInputBar(HongguoAssistantController c) {
    final hasText = _inputController.text.trim().isNotEmpty;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
      decoration: BoxDecoration(
        color: _geminiSurface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: c.isMicActive
              ? Colors.redAccent.withValues(alpha: 0.6)
              : Colors.white.withValues(alpha: 0.12),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _inputController,
              textInputAction: TextInputAction.send,
              maxLines: 4,
              minLines: 1,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submitText(),
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                height: 1.35,
              ),
              decoration: InputDecoration(
                hintText: c.isMicActive
                    ? 'Đang nghe... chạm nút đỏ để dừng'
                    : (c.titleTranslateOnly
                          ? 'Mô tả phim tiếng Việt để lấy tên tiếng Trung tự copy tìm...'
                          : 'Hỏi Gemini về phim Hồng Quả...'),
                hintStyle: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 13.5,
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 9,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Nút Micro Live Voice kiểu Gemini
          GestureDetector(
            onTap: () {
              HapticFeedback.mediumImpact();
              c.toggleMic();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.isMicActive ? Colors.redAccent : _geminiPillSurface,
                border: Border.all(
                  color: c.isMicActive
                      ? Colors.redAccent.shade100
                      : Colors.white.withValues(alpha: 0.08),
                  width: c.isMicActive ? (1.5 + c.micLevel * 2.0) : 1.0,
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
                c.isMicActive ? Icons.stop_rounded : Icons.mic_none_rounded,
                color: c.isMicActive ? Colors.white : AppColors.textPrimary,
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: hasText ? () => _submitText() : null,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hasText ? _geminiBlue : _geminiPillSurface,
              ),
              child: Icon(
                Icons.arrow_upward_rounded,
                size: 20,
                color: hasText ? Colors.white : AppColors.textMuted,
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
