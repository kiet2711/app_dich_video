import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../data/model/history_item.dart';
import '../../data/model/subtitle_document.dart';
import '../../data/repository/history_repository.dart';
import '../player/video_player_screen.dart';
import '../theme/app_theme.dart';

class HistoryScreen extends StatefulWidget {
  final void Function(String videoPath, SubtitleDocument doc)? onOpenInTts;

  const HistoryScreen({super.key, this.onOpenInTts});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  HistoryRepository? _historyRepo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = await HistoryRepository.getInstance();
    if (mounted) {
      setState(() {
        _historyRepo = repo;
      });
    }
  }

  Future<void> _openItem(HistoryItem item) async {
    final srtFile = File(item.srtPath);
    if (!await srtFile.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không tìm thấy tệp phụ đề SRT cũ')),
        );
      }
      return;
    }

    SubtitleDocument doc;
    final documentFile =
        item.documentPath == null ? null : File(item.documentPath!);
    if (documentFile != null && await documentFile.exists()) {
      final json =
          jsonDecode(await documentFile.readAsString()) as Map<String, dynamic>;
      doc = SubtitleDocument.fromJson(json);
    } else {
      final srtText = await srtFile.readAsString();
      doc = SubtitleDocument.parseSrt(srtText);
    }

    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (ctx) =>
              VideoPlayerScreen(videoPath: item.videoPath, document: doc),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.darkBackground,
      appBar: AppBar(
        backgroundColor: AppTheme.darkBackground,
        elevation: 0,
        title: Row(
          children: const [
            Icon(Icons.history, color: AppTheme.primaryEmerald, size: 22),
            SizedBox(width: 8),
            Text(
              'Lịch Sử & Player',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
      body: ValueListenableBuilder<List<HistoryItem>>(
        valueListenable: HistoryRepository.historyNotifier,
        builder: (context, items, _) {
          if (items.isEmpty) {
            return const Center(
              child: Text(
                'Chưa có lịch sử xử lý video nào',
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final it = items[index];
              final dateStr = DateTime.fromMillisecondsSinceEpoch(it.timestamp)
                  .toString()
                  .substring(0, 16);
              final durStr = it.durationMs > 0
                  ? '${it.durationMs ~/ 1000}s • '
                  : '';

              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.darkCard,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.cardBorder),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF64B5F6).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.movie_outlined,
                        color: Color(0xFF64B5F6),
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            it.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '$durStr$dateStr',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.play_circle_fill,
                        color: AppTheme.primaryEmerald,
                        size: 28,
                      ),
                      tooltip: 'Xem video',
                      onPressed: () => _openItem(it),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        color: Colors.redAccent,
                        size: 20,
                      ),
                      tooltip: 'Xóa',
                      onPressed: () async {
                        await _historyRepo?.deleteItem(it.id);
                      },
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
