import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/ai/ai_model_registry.dart';
import '../../domain/ai/live/gemini_live_client.dart';
import '../theme/app_theme.dart';

const geminiBlue = Color(0xFF4285F4);
const geminiPurple = Color(0xFF9B72CB);
const geminiSurface = Color(0xFF171B24);
const geminiPillSurface = Color(0xFF212633);

String shortLiveModelLabel(String modelId) {
  return switch (modelId) {
    'gemini-3.8-live' => '3.8 Live',
    'gemini-3.8-live-extended-thinking' => '3.8 Thinking',
    'gemini-3.1-flash-live-preview' => '3 Flash Live',
    _ => modelId,
  };
}

({IconData icon, String badge, String detail}) liveModelPresentation(
  AiModelInfo m, {
  String thinkingDetail =
      'Suy luận sâu, đối chiếu nhiều lớp dữ liệu và tổng hợp nội dung kỹ hơn.',
}) {
  return switch (m.id) {
    'gemini-3.8-live' => (
      icon: Icons.auto_awesome_rounded,
      badge: 'Cân bằng',
      detail: 'Tốc độ nhanh, gọi hàm chính xác và hội thoại tự nhiên.',
    ),
    'gemini-3.8-live-extended-thinking' => (
      icon: Icons.psychology_rounded,
      badge: 'Suy luận sâu',
      detail: thinkingDetail,
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

Future<void> showLiveQuickApiKeyDialog(
  BuildContext context, {
  required Future<void> Function(String rawKeys) onSaveKeys,
}) async {
  final ctrl = TextEditingController();
  final saved = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: geminiSurface,
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
            backgroundColor: geminiBlue,
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
    await onSaveKeys(saved);
  }
}

Future<int?> showLiveCountPickerDialog(
  BuildContext context, {
  required int initialCount,
  required String title,
}) async {
  final ctrl = TextEditingController(text: initialCount.toString());
  final res = await showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: geminiSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
      ),
      title: Text(
        title,
        style: const TextStyle(color: AppColors.textPrimary, fontSize: 16),
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
            backgroundColor: geminiBlue,
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
  return res;
}

Future<void> showLiveModelPickerSheet(
  BuildContext context, {
  required String selectedModelId,
  required LiveConnectionDiagnostics? diagnostics,
  required String subtitle,
  required String thinkingDetail,
  required ValueChanged<String> onSelectModel,
}) async {
  HapticFeedback.selectionClick();
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetCtx) {
      final available = diagnostics?.availableBidiModels ?? const [];
      return Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 22),
        decoration: BoxDecoration(
          color: geminiSurface,
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
                'Chọn mô hình Gemini Live',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 14),
              for (final m in AiModelRegistry.geminiLiveModels) ...[
                Builder(
                  builder: (_) {
                    final selected = selectedModelId == m.id;
                    final meta = liveModelPresentation(
                      m,
                      thinkingDetail: thinkingDetail,
                    );
                    final candidates =
                        AiModelRegistry.liveModelCandidateIds[m.id] ?? [m.id];
                    final isDiscovered =
                        available.isNotEmpty && candidates.any(available.contains);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: InkWell(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          Navigator.pop(sheetCtx);
                          onSelectModel(m.id);
                        },
                        borderRadius: BorderRadius.circular(18),
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: selected
                                ? geminiBlue.withValues(alpha: 0.14)
                                : geminiPillSurface.withValues(alpha: 0.65),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: selected
                                  ? geminiBlue.withValues(alpha: 0.75)
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
                                        ? [geminiBlue, geminiPurple]
                                        : [
                                            Colors.white.withValues(alpha: 0.08),
                                            Colors.white.withValues(alpha: 0.04),
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
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
                                                ? geminiBlue.withValues(
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
                                        if (isDiscovered) ...[
                                          const SizedBox(width: 6),
                                          const Icon(
                                            Icons.verified_rounded,
                                            size: 13,
                                            color: AppColors.primaryEmerald,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              if (selected)
                                const Padding(
                                  padding: EdgeInsets.only(left: 8, top: 6),
                                  child: Icon(
                                    Icons.check_circle_rounded,
                                    color: geminiBlue,
                                    size: 20,
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

Future<void> showLiveDiagnosticsSheet(
  BuildContext context, {
  required String selectedModelId,
  required String resolvedModelId,
  required String apiVersion,
  required bool isConnected,
  required bool isConnecting,
  required bool hasApiKeys,
  required int apiKeyCount,
  required String maskedActiveKey,
  required LiveConnectionDiagnostics? diagnostics,
  required Future<void> Function() onReconnect,
}) async {
  HapticFeedback.selectionClick();
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setModalState) {
          final isOk = isConnected;
          return Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
            decoration: BoxDecoration(
              color: geminiSurface,
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
                        isOk
                            ? Icons.check_circle_rounded
                            : isConnecting
                                ? Icons.sync_rounded
                                : Icons.error_outline_rounded,
                        color: isOk
                            ? AppColors.primaryEmerald
                            : isConnecting
                                ? Colors.amberAccent
                                : AppColors.textMuted,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Trạng thái phiên Gemini Live',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Đóng'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(ctx).size.height * 0.48,
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _diagRow(
                            'API Key đang dùng',
                            hasApiKeys
                                ? '$apiKeyCount key · ${maskedActiveKey.isEmpty ? "chờ kết nối" : maskedActiveKey}'
                                : 'Chưa có key nào',
                          ),
                          _diagRow('Model đã chọn', selectedModelId),
                          _diagRow(
                            'Model máy chủ khớp',
                            resolvedModelId.isNotEmpty
                                ? '$resolvedModelId ($apiVersion)'
                                : (diagnostics?.resolvedModelId.isNotEmpty == true
                                    ? '${diagnostics!.resolvedModelId} (${diagnostics.apiVersion})'
                                    : 'Chưa kết nối'),
                          ),
                          if (diagnostics != null) ...[
                            _diagRow('Hồ sơ bắt tay', diagnostics.profileLabel),
                            _diagRow('Độ trễ', '${diagnostics.latencyMs} ms'),
                            _diagRow('Ghi chú', diagnostics.summaryMessage),
                          ],
                          if (diagnostics != null &&
                              diagnostics.availableBidiModels.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            const Text(
                              'Các model hỗ trợ Live API trên key của bạn:',
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
                                for (final m in diagnostics.availableBidiModels)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: m == resolvedModelId
                                          ? AppColors.primaryEmerald.withValues(
                                              alpha: 0.18,
                                            )
                                          : geminiPillSurface,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: m == resolvedModelId
                                            ? AppColors.primaryEmerald
                                            : Colors.white.withValues(alpha: 0.08),
                                      ),
                                    ),
                                    child: Text(
                                      m,
                                      style: TextStyle(
                                        color: m == resolvedModelId
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
                          if (diagnostics != null &&
                              diagnostics.attemptLogs.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            const Text(
                              'Nhật ký bắt tay:',
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
                                diagnostics.attemptLogs.join('\n'),
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
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: geminiBlue,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: isConnecting
                          ? null
                          : () async {
                              await onReconnect();
                              if (ctx.mounted) setModalState(() {});
                            },
                      icon: const Icon(Icons.refresh_rounded, size: 19),
                      label: Text(
                        isConnected ? 'Làm mới phiên Live' : 'Kết nối lại',
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
          width: 138,
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

class LiveAssistantNoticeBanner extends StatelessWidget {
  final bool hasApiKeys;
  final String? errorBanner;
  final VoidCallback onQuickKey;
  final VoidCallback onOpenSettings;
  final VoidCallback onDismissError;

  const LiveAssistantNoticeBanner({
    super.key,
    required this.hasApiKeys,
    required this.errorBanner,
    required this.onQuickKey,
    required this.onOpenSettings,
    required this.onDismissError,
  });

  @override
  Widget build(BuildContext context) {
    final isMissingKey = !hasApiKeys;
    final text = errorBanner ??
        'Chưa có Gemini API Key. Hãy nhập nhanh hoặc vào Cài đặt ➔ Gemini.';

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: (isMissingKey ? Colors.amberAccent : const Color(0xFFEF4444))
            .withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: (isMissingKey ? Colors.amberAccent : const Color(0xFFEF4444))
              .withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isMissingKey ? Icons.vpn_key_rounded : Icons.error_outline_rounded,
                size: 16,
                color: isMissingKey ? Colors.amberAccent : const Color(0xFFEF4444),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.close_rounded,
                  size: 16,
                  color: AppColors.textMuted,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                onPressed: onDismissError,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              TextButton.icon(
                onPressed: onQuickKey,
                icon: const Icon(Icons.key_rounded, size: 15),
                label: const Text('Nhập nhanh Key', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.amberAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(width: 6),
              TextButton.icon(
                onPressed: onOpenSettings,
                icon: const Icon(Icons.settings_rounded, size: 15),
                label: const Text('Cài đặt Gemini', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.lightBlueAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class LiveAssistantActionPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color accent;
  final VoidCallback onTap;

  const LiveAssistantActionPill({
    super.key,
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

class LiveAssistantInputBar extends StatelessWidget {
  final TextEditingController textController;
  final bool isMicActive;
  final double micLevel;
  final bool isBusy;
  final String hintText;
  final VoidCallback onSend;
  final VoidCallback onToggleMic;

  const LiveAssistantInputBar({
    super.key,
    required this.textController,
    required this.isMicActive,
    required this.micLevel,
    required this.isBusy,
    required this.hintText,
    required this.onSend,
    required this.onToggleMic,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: geminiSurface,
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                decoration: BoxDecoration(
                  color: geminiPillSurface,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: isMicActive
                        ? AppColors.primaryEmerald.withValues(alpha: 0.7)
                        : Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                child: TextField(
                  controller: textController,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13.5,
                  ),
                  decoration: InputDecoration(
                    hintText: isMicActive
                        ? '🎙️ Đang nghe bạn nói... (bấm Mic để gửi)'
                        : hintText,
                    hintStyle: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12.5,
                    ),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Live Mic Button
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onToggleMic,
                borderRadius: BorderRadius.circular(24),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: isMicActive
                        ? const LinearGradient(
                            colors: [AppColors.primaryEmerald, geminiBlue],
                          )
                        : null,
                    color: isMicActive ? null : geminiPillSurface,
                    border: Border.all(
                      color: isMicActive
                          ? Colors.white.withValues(alpha: 0.4)
                          : Colors.white.withValues(alpha: 0.12),
                      width: isMicActive ? (1.5 + micLevel * 2.5) : 1,
                    ),
                  ),
                  child: Icon(
                    isMicActive ? Icons.stop_rounded : Icons.mic_rounded,
                    color: isMicActive ? Colors.black : AppColors.textPrimary,
                    size: 21,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            // Send Text Button
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onSend,
                borderRadius: BorderRadius.circular(24),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [geminiBlue, geminiPurple],
                    ),
                  ),
                  child: Icon(
                    isBusy ? Icons.hourglass_top_rounded : Icons.send_rounded,
                    color: Colors.white,
                    size: 19,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
