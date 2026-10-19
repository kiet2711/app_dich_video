import 'package:flutter/material.dart';

import '../../data/model/subtitle_document.dart';
import '../../data/model/subtitle_item.dart';

class TranscriptSheet extends StatefulWidget {
  final SubtitleDocument document;
  final int currentPositionMs;
  final void Function(int targetMs) onSeekTo;

  const TranscriptSheet({
    super.key,
    required this.document,
    required this.currentPositionMs,
    required this.onSeekTo,
  });

  @override
  State<TranscriptSheet> createState() => _TranscriptSheetState();
}

class _TranscriptSheetState extends State<TranscriptSheet> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToActiveItem(animated: false);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToActiveItem({bool animated = true}) {
    if (!mounted || !_scrollController.hasClients) return;
    final items = widget.document.items;
    final activeIndex = items.indexWhere(
      (item) =>
          widget.currentPositionMs >= item.startMs &&
          widget.currentPositionMs <= item.endMs,
    );
    if (activeIndex >= 0) {
      final targetOffset = (activeIndex * 68.0 - 120.0).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      if (animated) {
        _scrollController.animateTo(
          targetOffset,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scrollController.jumpTo(targetOffset);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.document.items;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey[600],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                const Icon(Icons.subtitles, color: Colors.blueAccent),
                const SizedBox(width: 8),
                Text(
                  'Kịch bản phụ đề (${items.length} câu)',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.my_location_rounded, color: Colors.blueAccent, size: 20),
                  tooltip: 'Cuộn tới câu đang phát',
                  onPressed: () => _scrollToActiveItem(animated: true),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white12),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final isActive =
                    widget.currentPositionMs >= item.startMs &&
                    widget.currentPositionMs <= item.endMs;

                return InkWell(
                  onTap: () => widget.onSeekTo(item.startMs),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    color: isActive
                        ? Colors.blue.withValues(alpha: 0.2)
                        : Colors.transparent,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          SubtitleItem.msToSrt(item.startMs).substring(3, 8),
                          style: TextStyle(
                            color: isActive ? Colors.blueAccent : Colors.grey,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.getDisplayText('translated'),
                                style: TextStyle(
                                  color: isActive
                                      ? Colors.white
                                      : Colors.white70,
                                  fontSize: 14,
                                  fontWeight: isActive
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                              if (item.originalText.isNotEmpty &&
                                  item.originalText != item.translatedText)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    item.originalText,
                                    style: const TextStyle(
                                      color: Colors.grey,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                            ],
                          ),
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
}
