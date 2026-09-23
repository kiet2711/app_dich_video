import 'package:flutter/material.dart';

import '../../domain/tts/tts_generation_manager.dart';
import '../theme/app_theme.dart';

class TtsErrorReviewDialog extends StatefulWidget {
  final List<TtsFailedItem> failedItems;
  final int threadCount;
  final int geminiThreadCount;
  final bool geminiApiKeysAvailable;
  final Future<void> Function(int itemId, String editedText) onRetryOne;
  final Future<void> Function(Map<int, String> editedTexts) onRetryAll;
  final Future<Map<int, String>> Function(
    Map<int, String> items,
    void Function(double progress, String message) onProgress,
  )
  onTranslateWithGemini;
  final Future<String> Function(int itemId, String text)
  onTranslateSingleWithGemini;
  final Future<void> Function() onSkipErrors;

  const TtsErrorReviewDialog({
    super.key,
    required this.failedItems,
    required this.threadCount,
    required this.geminiThreadCount,
    required this.geminiApiKeysAvailable,
    required this.onRetryOne,
    required this.onRetryAll,
    required this.onTranslateWithGemini,
    required this.onTranslateSingleWithGemini,
    required this.onSkipErrors,
  });

  @override
  State<TtsErrorReviewDialog> createState() => _TtsErrorReviewDialogState();
}

class _TtsErrorReviewDialogState extends State<TtsErrorReviewDialog> {
  late final Map<int, TextEditingController> _controllers;
  final Set<int> _translatingIds = {};
  bool _isRetrying = false;
  bool _isTranslatingAll = false;
  double _translationProgress = 0;
  String _translationMessage = '';

  bool get _isBusy => _isRetrying || _isTranslatingAll;

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final failure in widget.failedItems)
        failure.itemId: TextEditingController(text: failure.text),
    };
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Map<int, String> get _editedTexts => {
    for (final entry in _controllers.entries)
      entry.key: entry.value.text.trim(),
  };

  Future<void> _translateOne(int itemId) async {
    final controller = _controllers[itemId];
    if (controller == null || controller.text.trim().isEmpty) return;
    setState(() => _translatingIds.add(itemId));
    try {
      final translated = await widget.onTranslateSingleWithGemini(
        itemId,
        controller.text.trim(),
      );
      if (mounted && translated.trim().isNotEmpty) {
        controller.text = translated.trim();
      }
    } finally {
      if (mounted) setState(() => _translatingIds.remove(itemId));
    }
  }

  Future<void> _translateAll() async {
    if (!widget.geminiApiKeysAvailable) return;
    setState(() {
      _isTranslatingAll = true;
      _translationProgress = 0.05;
      _translationMessage = 'Đang chuẩn bị dịch các câu lỗi...';
    });
    try {
      final translated = await widget.onTranslateWithGemini(_editedTexts, (
        progress,
        message,
      ) {
        if (!mounted) return;
        setState(() {
          _translationProgress = progress;
          _translationMessage = message;
        });
      });
      if (!mounted) return;
      setState(() {
        for (final entry in translated.entries) {
          _controllers[entry.key]?.text = entry.value;
        }
      });
    } finally {
      if (mounted) setState(() => _isTranslatingAll = false);
    }
  }

  Future<void> _retryOne(int itemId) async {
    final text = _controllers[itemId]?.text.trim() ?? '';
    if (text.isEmpty) return;
    setState(() => _isRetrying = true);
    try {
      await widget.onRetryOne(itemId, text);
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _isRetrying = false);
    }
  }

  Future<void> _retryAll() async {
    setState(() => _isRetrying = true);
    try {
      await widget.onRetryAll(_editedTexts);
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _isRetrying = false);
    }
  }

  Future<void> _skipErrors() async {
    setState(() => _isRetrying = true);
    try {
      await widget.onSkipErrors();
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _isRetrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isBusy,
      child: AlertDialog(
        backgroundColor: AppColors.darkCard,
        insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titlePadding: const EdgeInsets.fromLTRB(18, 18, 12, 8),
        title: Row(
          children: [
            const Icon(Icons.warning_amber, color: Color(0xFFFFB74D)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Xử lý ${widget.failedItems.length} câu tạo giọng lỗi',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            IconButton(
              onPressed: _isBusy ? null : () => Navigator.pop(context),
              icon: const Icon(Icons.close, color: Colors.grey),
            ),
          ],
        ),
        contentPadding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Bạn có thể sửa nội dung, dùng Gemini dịch lại rồi thử tạo giọng.',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ),
              if (_isTranslatingAll) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: _translationProgress,
                  color: const Color(0xFFA5B4FC),
                  backgroundColor: Colors.white12,
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _translationMessage,
                    style: const TextStyle(
                      color: Color(0xFFA5B4FC),
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: widget.failedItems.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final failure = widget.failedItems[index];
                    final translating = _translatingIds.contains(
                      failure.itemId,
                    );
                    return Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F2029),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF3B3540)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Câu #${failure.itemId}: ${failure.reason}',
                            style: const TextStyle(
                              color: Color(0xFFFFB74D),
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _controllers[failure.itemId],
                            enabled: !_isBusy && !translating,
                            minLines: 1,
                            maxLines: 3,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              filled: true,
                              fillColor: const Color(0xFF14151B),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                          const SizedBox(height: 7),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed:
                                      !widget.geminiApiKeysAvailable ||
                                          _isBusy ||
                                          translating
                                      ? null
                                      : () => _translateOne(failure.itemId),
                                  icon: translating
                                      ? const SizedBox.square(
                                          dimension: 13,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.translate, size: 14),
                                  label: Text(
                                    translating ? 'Đang dịch...' : 'Dịch AI',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _isBusy || translating
                                      ? null
                                      : () => _retryOne(failure.itemId),
                                  icon: const Icon(Icons.refresh, size: 14),
                                  label: const Text(
                                    'Thử lại câu này',
                                    style: TextStyle(fontSize: 11),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        actions: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: !widget.geminiApiKeysAvailable || _isBusy
                  ? null
                  : _translateAll,
              icon: const Icon(Icons.auto_awesome, size: 17),
              label: Text(
                widget.geminiApiKeysAvailable
                    ? 'Dịch lại tất cả bằng Gemini '
                          '(${widget.geminiThreadCount} luồng)'
                    : 'Dịch Gemini (Chưa cấu hình API Key)',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF5965D8),
                foregroundColor: Colors.white,
              ),
            ),
          ),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isBusy ? null : _retryAll,
              icon: const Icon(Icons.refresh, size: 17),
              label: Text(
                _isRetrying
                    ? 'Đang tạo âm thanh...'
                    : 'Thử tạo lại tất cả (${widget.threadCount} luồng)',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryEmerald,
                foregroundColor: Colors.black,
              ),
            ),
          ),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: _isBusy ? null : _skipErrors,
              child: const Text(
                'Bỏ qua các câu lỗi và tiếp tục',
                style: TextStyle(color: Color(0xFFFFB74D)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
