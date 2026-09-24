import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/api/groq_key_checker.dart';
import '../../domain/ai/ai_model_registry.dart';
import '../theme/app_theme.dart';

class GroqKeyTestDialog extends StatefulWidget {
  final List<String> apiKeys;
  final String initialModelId;
  final ValueChanged<List<String>>? onRemoveDeadKeys;

  const GroqKeyTestDialog({
    super.key,
    required this.apiKeys,
    this.initialModelId = 'openai/gpt-oss-120b',
    this.onRemoveDeadKeys,
  });

  @override
  State<GroqKeyTestDialog> createState() => _GroqKeyTestDialogState();
}

class _GroqKeyTestDialogState extends State<GroqKeyTestDialog> {
  bool _isLoading = true;
  late String _selectedModel;
  List<GroqKeyCheckResult> _results = [];
  final Set<int> _recheckingIndices = {};

  @override
  void initState() {
    super.initState();
    _selectedModel = widget.initialModelId.trim().isEmpty
        ? 'openai/gpt-oss-120b'
        : widget.initialModelId.trim();
    _startCheckAll();
  }

  Future<void> _startCheckAll() async {
    setState(() {
      _isLoading = true;
      _results = [];
    });

    final res = await GroqKeyChecker.checkAllKeys(
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

    final updated = await GroqKeyChecker.checkKey(
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
              ? 'Đã loại bỏ $removedCount key Groq không khả dụng, giữ lại ${aliveKeys.length} key sẵn sàng dịch!'
              : 'Tất cả các key Groq đều đang hoạt động tốt!',
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
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 680),
        decoration: BoxDecoration(
          color: AppColors.darkSurface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.cardBorder, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 16, 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.electric_bolt_rounded,
                      color: Colors.amber,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Kiểm tra Groq API Key',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Ping trực tiếp máy chủ LPU siêu tốc',
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
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
            ),

            // Model selector row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF13141B),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: Row(
                  children: [
                    const Text(
                      'Model test:',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: AiModelRegistry.groqModels.any((m) => m.id == _selectedModel)
                              ? _selectedModel
                              : 'openai/gpt-oss-120b',
                          isExpanded: true,
                          dropdownColor: const Color(0xFF1E202A),
                          icon: const Icon(
                            Icons.keyboard_arrow_down,
                            color: Colors.amber,
                            size: 18,
                          ),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                          items: AiModelRegistry.groqModels.map((m) {
                            return DropdownMenuItem(
                              value: m.id,
                              child: Text(
                                '${m.displayName}${m.isRecommended ? ' ★' : ''}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
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
            ),
            const SizedBox(height: 10),

            // Summary Bar
            if (!_isLoading && _results.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF13141B),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.cardBorder),
                  ),
                  child: Row(
                    children: [
                      _buildSummaryChip(
                        icon: Icons.check_circle_rounded,
                        color: AppColors.primaryEmerald,
                        label: '$aliveCount Sống',
                      ),
                      const SizedBox(width: 12),
                      _buildSummaryChip(
                        icon: Icons.cancel_rounded,
                        color: Colors.redAccent,
                        label: '$deadCount Chết',
                      ),
                      const Spacer(),
                      Text(
                        'Tổng: ${_results.length} key',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            const SizedBox(height: 8),
            const Divider(color: AppColors.cardBorder, height: 1),

            // Content List / Loading
            Expanded(
              child: _isLoading
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 36,
                            height: 36,
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.amber,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Đang gọi thử Groq LPU ($_selectedModel)...',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Đang ping thử nghiệm ${widget.apiKeys.length} key...',
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      itemCount: _results.length,
                      separatorBuilder: (_, index) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final result = _results[index];
                        final isRechecking = _recheckingIndices.contains(index);
                        return _buildKeyItem(result, index, isRechecking);
                      },
                    ),
            ),

            const Divider(color: AppColors.cardBorder, height: 1),

            // Bottom Actions
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: AppColors.cardBorder),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Kiểm tra lại', style: TextStyle(fontSize: 12)),
                    onPressed: _isLoading ? null : _startCheckAll,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: deadCount > 0
                            ? const Color(0xFFE53935)
                            : AppColors.primaryEmerald,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      icon: Icon(
                        deadCount > 0
                            ? Icons.delete_sweep_rounded
                            : Icons.check_rounded,
                        size: 18,
                      ),
                      label: Text(
                        deadCount > 0
                            ? 'Xoá $deadCount key chết'
                            : 'Đóng & Giữ lại key',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      onPressed: _isLoading
                          ? null
                          : () {
                              if (deadCount > 0) {
                                _removeDeadKeys();
                              } else {
                                Navigator.of(context).pop();
                              }
                            },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryChip({
    required IconData icon,
    required Color color,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKeyItem(
    GroqKeyCheckResult result,
    int index,
    bool isRechecking,
  ) {
    final isAlive = result.isAlive;
    final color = isAlive ? AppColors.primaryEmerald : Colors.redAccent;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF13141B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isAlive
              ? AppColors.primaryEmerald.withValues(alpha: 0.2)
              : Colors.redAccent.withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isAlive ? Icons.check_circle_rounded : Icons.cancel_rounded,
                color: color,
                size: 16,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  result.maskedKey,
                  style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'monospace',
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (isAlive)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.primaryEmerald.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${result.latencyMs}ms',
                    style: const TextStyle(
                      color: AppColors.primaryEmerald,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.copy_rounded, size: 14, color: Colors.white38),
                tooltip: 'Sao chép Key',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: result.key));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Đã sao chép API Key vào khay nhớ tạm!'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
              if (isRechecking)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.amber),
                  ),
                )
              else
                IconButton(
                  icon: const Icon(Icons.refresh_rounded, size: 15, color: Colors.white38),
                  tooltip: 'Kiểm tra lại key này',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  onPressed: () => _recheckSingle(index),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            result.message,
            style: TextStyle(
              color: isAlive ? Colors.white60 : Colors.redAccent.shade100,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
