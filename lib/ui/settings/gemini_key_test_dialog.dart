import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/api/gemini_key_checker.dart';
import '../theme/app_theme.dart';

class GeminiKeyTestDialog extends StatefulWidget {
  final List<String> apiKeys;
  final ValueChanged<List<String>>? onRemoveDeadKeys;

  const GeminiKeyTestDialog({
    super.key,
    required this.apiKeys,
    this.onRemoveDeadKeys,
  });

  @override
  State<GeminiKeyTestDialog> createState() => _GeminiKeyTestDialogState();
}

class _GeminiKeyTestDialogState extends State<GeminiKeyTestDialog> {
  bool _isLoading = true;
  List<GeminiKeyCheckResult> _results = [];
  final Set<int> _recheckingIndices = {};

  @override
  void initState() {
    super.initState();
    _startCheckAll();
  }

  Future<void> _startCheckAll() async {
    setState(() {
      _isLoading = true;
      _results = [];
    });

    final res = await GeminiKeyChecker.checkAllKeys(widget.apiKeys);
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

    final updated = await GeminiKeyChecker.checkKey(_results[index].key);
    if (!mounted) return;

    setState(() {
      _recheckingIndices.remove(index);
      _results[index] = updated;
    });
  }

  void _removeDeadKeys() {
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
              ? 'Đã loại bỏ $removedCount key chết, giữ lại ${aliveKeys.length} key hoạt động!'
              : 'Tất cả các key đều đang hoạt động tốt!',
        ),
        backgroundColor: AppColors.primaryEmerald,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final aliveCount = _results.where((r) => r.isAlive).length;
    final deadCount = _results.where((r) => !r.isAlive).length;

    return Dialog(
      backgroundColor: AppColors.darkSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppColors.cardBorder),
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
                      color: AppColors.primaryEmerald.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.bolt_rounded,
                      color: AppColors.primaryEmerald,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Kiểm tra Gemini API Key',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Xác thực trạng thái sống / chết với máy chủ Google',
                          style: TextStyle(color: Colors.white60, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Summary Bar
              if (!_isLoading && _results.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF13141B),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.cardBorder),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildSummaryItem(
                        label: 'Tổng số key',
                        count: '${_results.length}',
                        color: Colors.white70,
                      ),
                      Container(width: 1, height: 24, color: AppColors.cardBorder),
                      _buildSummaryItem(
                        label: '🟢 Hoạt động',
                        count: '$aliveCount',
                        color: AppColors.primaryEmerald,
                      ),
                      Container(width: 1, height: 24, color: AppColors.cardBorder),
                      _buildSummaryItem(
                        label: '🔴 Chết / Lỗi',
                        count: '$deadCount',
                        color: deadCount > 0 ? Colors.redAccent : Colors.white38,
                      ),
                    ],
                  ),
                ),

              const SizedBox(height: 12),

              // Main Body (List or Loading)
              Expanded(
                child: _isLoading
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(
                              color: AppColors.primaryEmerald,
                            ),
                            SizedBox(height: 16),
                            Text(
                              'Đang kiểm tra kết nối với Google...',
                              style: TextStyle(color: Colors.white70, fontSize: 13),
                            ),
                          ],
                        ),
                      )
                    : _results.isEmpty
                        ? const Center(
                            child: Text(
                              'Không có API Key nào để kiểm tra.',
                              style: TextStyle(color: Colors.white54),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _results.length,
                            separatorBuilder: (_, _) => const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final item = _results[index];
                              final isChecking = _recheckingIndices.contains(index);
                              return _buildKeyItemCard(index, item, isChecking);
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
                          backgroundColor: Colors.redAccent.withValues(alpha: 0.15),
                          foregroundColor: Colors.redAccent,
                          side: const BorderSide(color: Colors.redAccent, width: 1),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                        label: Text(
                          'Xoá $deadCount key chết',
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
                        foregroundColor: AppColors.primaryEmerald,
                        side: const BorderSide(color: AppColors.primaryEmerald),
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
          style: const TextStyle(color: Colors.white54, fontSize: 11),
        ),
      ],
    );
  }

  Widget _buildKeyItemCard(
    int index,
    GeminiKeyCheckResult item,
    bool isChecking,
  ) {
    Color statusColor;
    IconData statusIcon;
    String statusBadge;

    switch (item.status) {
      case GeminiKeyStatus.alive:
        statusColor = AppColors.primaryEmerald;
        statusIcon = Icons.check_circle_rounded;
        statusBadge = 'SỐNG (${item.latencyMs}ms)';
        break;
      case GeminiKeyStatus.dead:
        statusColor = Colors.redAccent;
        statusIcon = Icons.cancel_rounded;
        statusBadge = 'CHẾT (400)';
        break;
      case GeminiKeyStatus.permissionDenied:
        statusColor = Colors.orangeAccent;
        statusIcon = Icons.block_rounded;
        statusBadge = 'CHẶN QUYỀN (403)';
        break;
      case GeminiKeyStatus.quotaExceeded:
        statusColor = Colors.amber;
        statusIcon = Icons.warning_amber_rounded;
        statusBadge = 'HẾT HẠN NGẠCH (429)';
        break;
      case GeminiKeyStatus.networkError:
        statusColor = Colors.blueGrey;
        statusIcon = Icons.wifi_off_rounded;
        statusBadge = 'LỖI MẠNG';
        break;
      case GeminiKeyStatus.unknown:
        statusColor = Colors.grey;
        statusIcon = Icons.help_outline_rounded;
        statusBadge = 'LỖI KHÁC';
        break;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E202A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: item.isAlive
              ? AppColors.cardBorder
              : statusColor.withValues(alpha: 0.4),
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
                  color: statusColor.withValues(alpha: 0.15),
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
                icon: const Icon(Icons.copy_rounded, size: 16, color: Colors.white54),
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
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.primaryEmerald,
                  ),
                )
              else
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  icon: const Icon(
                    Icons.refresh_rounded,
                    size: 18,
                    color: Colors.white54,
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
            style: const TextStyle(
              color: Colors.white,
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
                  ? Colors.white60
                  : statusColor.withValues(alpha: 0.9),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
