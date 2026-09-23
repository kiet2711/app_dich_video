import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/model/history_item.dart';
import '../../data/model/subtitle_document.dart';
import '../../data/repository/history_repository.dart';
import '../player/video_player_screen.dart';
import '../settings/settings_screen.dart';
import '../theme/app_theme.dart';
import 'import_subtitle_dialog.dart';

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
    final repo = _historyRepo ?? await HistoryRepository.getInstance();
    final doc = await repo.loadSubtitleDocument(item);
    if (doc == null || doc.items.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không tìm thấy tệp phụ đề SRT cũ')),
        );
      }
      return;
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

  Future<void> _openInTts(HistoryItem item) async {
    if (widget.onOpenInTts == null) return;
    final repo = _historyRepo ?? await HistoryRepository.getInstance();
    final doc = await repo.loadSubtitleDocument(item);
    if (doc == null || doc.items.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không tìm thấy tệp phụ đề để lồng tiếng')),
        );
      }
      return;
    }

    widget.onOpenInTts!(item.videoPath, doc);
  }

  Future<void> _exportSrt(HistoryItem item) async {
    final srtFile = File(item.srtPath);
    if (!await srtFile.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tệp phụ đề SRT không còn tồn tại.')),
        );
      }
      return;
    }

    try {
      // ignore: deprecated_member_use
      await Share.shareXFiles(
        [XFile(srtFile.path)],
        subject: 'Phụ đề: ${item.title}',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Lỗi chia sẻ file: $e')));
      }
    }
  }

  Future<void> _confirmDelete(HistoryItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.darkCard,
        title: const Text('Xóa lịch sử', style: TextStyle(color: Colors.white)),
        content: Text(
          'Bạn có chắc chắn muốn xóa bản ghi "${item.title}" không?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xóa', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _historyRepo?.deleteItem(item.id);
    }
  }

  Future<void> _confirmClearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.darkCard,
        title: const Text('Xóa toàn bộ lịch sử', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Thao tác này sẽ xóa toàn bộ danh sách lịch sử, các file phụ đề và dữ liệu âm thanh đã tạo. Bạn có chắc chắn không?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xóa tất cả', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _historyRepo?.clearAll();
    }
  }

  void _showImportSubtitleDialog() {
    showDialog(
      context: context,
      builder: (ctx) => ImportSubtitleDialog(
        onSuccessPlay: (videoPath, doc) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (c) =>
                  VideoPlayerScreen(videoPath: videoPath, document: doc),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dateFormatter = DateFormat('dd/MM/yyyy HH:mm');

    return Scaffold(
      backgroundColor: AppTheme.darkBackground,
      appBar: AppBar(
        backgroundColor: AppTheme.darkBackground,
        elevation: 0,
        title: Row(
          children: const [
            Icon(Icons.video_library, color: AppTheme.primaryEmerald, size: 24),
            SizedBox(width: 10),
            Text(
              'Trình Phát & Lịch Sử',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white70),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (ctx) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Banner "Nhập Video & Phụ Đề Có Sẵn" (Chuẩn bản gốc Android)
            InkWell(
              onTap: _showImportSubtitleDialog,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.darkCard,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.cardBorder),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: AppTheme.primaryEmerald.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.input,
                        color: AppTheme.primaryEmerald,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Nhập Video & Phụ Đề Có Sẵn',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            'Xem với phụ đề rời hoặc dịch file sub gốc bằng AI',
                            style: TextStyle(color: Colors.grey, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, color: Colors.grey),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),

            // Tiêu đề danh sách & Nút xóa tất cả
            ValueListenableBuilder<List<HistoryItem>>(
              valueListenable: HistoryRepository.historyNotifier,
              builder: (context, items, _) {
                return Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'DANH SÁCH ĐÃ DỊCH (${items.length})',
                      style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                    if (items.isNotEmpty)
                      TextButton.icon(
                        onPressed: _confirmClearAll,
                        icon: const Icon(
                          Icons.delete_sweep_outlined,
                          size: 16,
                          color: Colors.grey,
                        ),
                        label: const Text(
                          'Xóa tất cả',
                          style: TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 10),

            // Danh sách Video
            ValueListenableBuilder<List<HistoryItem>>(
              valueListenable: HistoryRepository.historyNotifier,
              builder: (context, items, _) {
                if (items.isEmpty) {
                  return Container(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    alignment: Alignment.center,
                    child: Column(
                      children: const [
                        Icon(
                          Icons.history,
                          color: Colors.white24,
                          size: 56,
                        ),
                        SizedBox(height: 12),
                        Text(
                          'Chưa có video nào trong lịch sử',
                          style: TextStyle(color: Colors.white70, fontSize: 15),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Các video tạo phụ đề xong sẽ hiển thị tại đây để xem lại',
                          style: TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.separated(
                  physics: const NeverScrollableScrollPhysics(),
                  shrinkWrap: true,
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final it = items[index];
                    final dateStr = dateFormatter.format(
                      DateTime.fromMillisecondsSinceEpoch(it.timestamp),
                    );
                    final hasVoice =
                        it.ttsVoice != null && it.ttsVoice!.isNotEmpty;

                    return Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppTheme.darkCard,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppTheme.cardBorder),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Hàng 1: Tiêu đề video + Nút Xóa
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  it.title,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              InkWell(
                                onTap: () => _confirmDelete(it),
                                child: const Padding(
                                  padding: EdgeInsets.all(4),
                                  child: Icon(
                                    Icons.delete_outline,
                                    color: Colors.grey,
                                    size: 20,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),

                          // Hàng 2: Badges (Số câu, Giọng lồng tiếng, Thời gian)
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E2029),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '${it.sentenceCount > 0 ? it.sentenceCount : '?'} câu',
                                  style: const TextStyle(
                                    color: AppTheme.primaryEmerald,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: hasVoice
                                      ? const Color(0xFF132F24)
                                      : const Color(0xFF252631),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  hasVoice
                                      ? '🎤 ${it.ttsVoice}'
                                      : 'Chưa lồng tiếng',
                                  style: TextStyle(
                                    color: hasVoice
                                        ? AppTheme.primaryEmerald
                                        : Colors.grey,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                              Text(
                                dateStr,
                                style: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),

                          // Hàng 3: Các nút hành động (Xem video, Lồng tiếng, Xuất SRT)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  ElevatedButton.icon(
                                    onPressed: () => _openItem(it),
                                    icon: const Icon(
                                      Icons.play_arrow,
                                      size: 18,
                                      color: AppTheme.primaryEmerald,
                                    ),
                                    label: const Text(
                                      'Xem Video',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF252631),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 8,
                                      ),
                                    ),
                                  ),
                                  if (widget.onOpenInTts != null) ...[
                                    const SizedBox(width: 8),
                                    OutlinedButton.icon(
                                      onPressed: () => _openInTts(it),
                                      icon: const Icon(
                                        Icons.record_voice_over,
                                        size: 16,
                                        color: AppTheme.primaryEmerald,
                                      ),
                                      label: Text(
                                        hasVoice ? 'Đổi giọng' : 'Lồng tiếng',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                        ),
                                      ),
                                      style: OutlinedButton.styleFrom(
                                        side: const BorderSide(
                                          color: AppTheme.cardBorder,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 8,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.file_download_outlined,
                                  color: Colors.white70,
                                  size: 22,
                                ),
                                tooltip: 'Xuất file SRT',
                                onPressed: () => _exportSrt(it),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
