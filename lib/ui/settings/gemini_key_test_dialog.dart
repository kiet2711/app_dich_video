import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/api/gemini_key_checker.dart';
import '../theme/app_theme.dart';

class GeminiKeyTestDialog extends StatefulWidget {
  final List<String> apiKeys;
  final String initialModelId;
  final ValueChanged<List<String>>? onRemoveDeadKeys;

  const GeminiKeyTestDialog({
    super.key,
    required this.apiKeys,
    this.initialModelId = 'gemini-3.5-flash-lite',
    this.onRemoveDeadKeys,
  });

  @override
  State<GeminiKeyTestDialog> createState() => _GeminiKeyTestDialogState();
}

class _GeminiKeyTestDialogState extends State<GeminiKeyTestDialog> {
  bool _isLoading = true;
  late String _selectedModel;
  List<GeminiKeyCheckResult> _results = [];
  final Set<int> _recheckingIndices = {};

  @override
  void initState() {
    super.initState();
    _selectedModel = widget.initialModelId.trim().isEmpty
        ? 'gemini-3.5-flash-lite'
        : widget.initialModelId.trim();
    _startCheckAll();
  }

  Future<void> _startCheckAll() async {
    setState(() {
      _isLoading = true;
      _results = [];
    });

    final res = await GeminiKeyChecker.checkAllKeys(
      widget.apiKeys,
      modelId: _selectedModel,
    );
    if (!mounted) return;

    setState(() {
      _results = res;
      _isLoading = false;
    });
  }

  Future<void> _recheckSingle(int index) async {
    if (index < 0 || index >= _results.length) return;
    setState(() {
      _recheckingIndices.add(index);
    });

    final updated = await GeminiKeyChecker.checkKey(
      _results[index].key,
      modelId: _selectedModel,
    );
    if (!mounted) return;

    setState(() {
      _recheckingIndices.remove(index);
      _results[index] = updated;
    });
  }

  void _removeDeadKeys() {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.settings);
    final aliveKeys = _results
        .where((r) => r.isAlive)
        .map((r) => r.key)
        .toList();

    widget.onRemoveDeadKeys?.call(aliveKeys);
    Navigator.of(context).pop();

    final removedCount = _results.length - aliveKeys.length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          removedCount > 0
              ? 'Đã loại bỏ $removedCount key không khả dụng, giữ lại ${aliveKeys.length} key sẵn sàng dịch!'
              : 'Tất cả các key đều đang hoạt động tốt!',
          style: TextStyle(color: palette.onColor(accent)),
        ),
        backgroundColor: accent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.settings);
    final aliveCount = _results.where((r) => r.isAlive).length;
    final deadCount = _results.where((r) => !r.isAlive).length;

    return Dialog(
      backgroundColor: palette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: palette.border),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.bolt_rounded,
                      color: accent,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Kiểm tra Gemini API Key',
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Gọi thử AI thực tế để phát hiện key chết hoặc lỗi 429',
                          style: TextStyle(color: palette.textSecondary, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: palette.textMuted, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Model selector row
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: palette.surfaceAlt,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: palette.border),
                ),
                child: Row(
                  children: [
                    Text(
                      'Model kiểm tra:',
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: ['gemini-3.5-flash-lite', 'gemini-3.1-flash-lite']
                                  .contains(_selectedModel)
                              ? _selectedModel
                              : 'gemini-3.5-flash-lite',
                          isExpanded: true,
                          dropdownColor: palette.surface,
                          icon: Icon(
                            Icons.keyboard_arrow_down,
                            color: accent,
                            size: 18,
                          ),
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'gemini-3.5-flash-lite',
                              child: Text(
                                '🤖 Gemini 3.5 Flash-Lite (RPD cao)',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            DropdownMenuItem(
                              value: 'gemini-3.1-flash-lite',
                              child: Text(
                                '🤖 Gemini 3.1 Flash-Lite (Khuyên dùng)',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                          onChanged: _isLoading
                              ? null
                              : (val) {
                                  if (val != null && val != _selectedModel) {
                                    setState(() {
                                      _selectedModel = val;
                                    });
                                    _startCheckAll();
                                  }
                                },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // Summary Bar
              if (!_isLoading && _results.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: palette.surfaceAlt,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: palette.border),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildSummaryItem(
                        palette: palette,
                        label: 'Tổng số key',
                        count: '${_results.length}',
                        color: palette.textPrimary,
                      ),
                      Container(width: 1, height: 24, color: palette.border),
                      _buildSummaryItem(
                        palette: palette,
                        label: '🟢 Sẵn sàng',
                        count: '$aliveCount',
                        color: accent,
                      ),
                      Container(width: 1, height: 24, color: palette.border),
                      _buildSummaryItem(
                        palette: palette,
                        label: '🔴 Lỗi / Hết ngạch',
                        count: '$deadCount',
                        color: deadCount > 0 ? Colors.redAccent : palette.textMuted,
                      ),
                    ],
                  ),
                ),

              const SizedBox(height: 10),

              // Main Body (List or Loading)
              Expanded(
                child: _isLoading
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: accent),
                            const SizedBox(height: 16),
                            Text(
                              'Đang gọi thử AI Google ($_selectedModel)...',
                              style: TextStyle(
                                color: palette.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      )
                    : _results.isEmpty
                        ? Center(
                            child: Text(
                              'Không có API Key nào để kiểm tra.',
                              style: TextStyle(color: palette.textMuted),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _results.length,
                            separatorBuilder: (_, _) => const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final item = _results[index];
                              final isChecking =
                                  _recheckingIndices.contains(index);
                              return _buildKeyItemCard(
                                palette,
                                accent,
                                index,
                                item,
                                isChecking,
                              );
                            },
                          ),
              ),

              const SizedBox(height: 16),

              // Bottom Actions
              Row(
                children: [
                  if (!_isLoading && deadCount > 0 && widget.onRemoveDeadKeys != null)
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent.withValues(alpha: 0.14),
                          foregroundColor: Colors.redAccent,
                          elevation: 0,
                          side: const BorderSide(color: Colors.redAccent, width: 1),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                        label: Text(
                          'Xoá $deadCount key lỗi',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        onPressed: _removeDeadKeys,
                      ),
                    ),
                  if (!_isLoading && deadCount > 0 && widget.onRemoveDeadKeys != null)
                    const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: accent,
                        side: BorderSide(color: accent),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text(
                        'Kiểm tra lại',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      onPressed: _isLoading ? null : _startCheckAll,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryItem({
    required AppThemePalette palette,
    required String label,
    required String count,
    required Color color,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          count,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(color: palette.textMuted, fontSize: 11),
        ),
      ],
    );
  }

  Widget _buildKeyItemCard(
    AppThemePalette palette,
    Color accent,
    int index,
    GeminiKeyCheckResult item,
    bool isChecking,
  ) {
    Color statusColor;
    IconData statusIcon;
    String statusBadge;

    switch (item.status) {
      case GeminiKeyStatus.alive:
        statusColor = accent;
        statusIcon = Icons.check_circle_rounded;
        statusBadge = 'SỐNG (${item.latencyMs}ms)';
        break;
      case GeminiKeyStatus.dead:
        statusColor = Colors.redAccent;
        statusIcon = Icons.cancel_rounded;
        statusBadge = 'CHẾT (400)';
        break;
      case GeminiKeyStatus.permissionDenied:
        statusColor =
            palette.isDark ? Colors.orangeAccent : const Color(0xFFEA580C);
        statusIcon = Icons.block_rounded;
        statusBadge = 'CHẶN QUYỀN (403)';
        break;
      case GeminiKeyStatus.quotaExceeded:
        statusColor = palette.isDark ? Colors.amber : const Color(0xFFD97706);
        statusIcon = Icons.warning_amber_rounded;
        statusBadge = 'HẾT HẠN NGẠCH (429)';
        break;
      case GeminiKeyStatus.networkError:
        statusColor = Colors.blueGrey;
        statusIcon = Icons.wifi_off_rounded;
        statusBadge = 'LỖI MẠNG';
        break;
      case GeminiKeyStatus.unknown:
        statusColor = palette.textMuted;
        statusIcon = Icons.help_outline_rounded;
        statusBadge = 'LỖI KHÁC';
        break;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: item.isAlive
              ? palette.border
              : statusColor.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Status Pill
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(statusIcon, color: statusColor, size: 14),
                    const SizedBox(width: 4),
                    Text(
                      statusBadge,
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              // Copy key button
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                icon: Icon(Icons.copy_rounded, size: 16, color: palette.textMuted),
                tooltip: 'Sao chép key',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: item.key));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Đã sao chép API Key vào bộ nhớ tạm!'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
              const SizedBox(width: 8),
              // Single recheck button
              if (isChecking)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: accent,
                  ),
                )
              else
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  icon: Icon(
                    Icons.refresh_rounded,
                    size: 18,
                    color: palette.textMuted,
                  ),
                  tooltip: 'Kiểm tra lại key này',
                  onPressed: () => _recheckSingle(index),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // Masked Key string
          Text(
            item.maskedKey,
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 13,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          // Message detail
          Text(
            item.message,
            style: TextStyle(
              color: item.isAlive
                  ? palette.textSecondary
                  : statusColor.withValues(alpha: 0.9),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
