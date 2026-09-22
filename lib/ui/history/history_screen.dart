import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../data/model/history_item.dart';
import '../../data/model/subtitle_document.dart';
import '../../data/repository/history_repository.dart';
import '../player/video_player_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  HistoryRepository? _historyRepo;
  List<HistoryItem> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = await HistoryRepository.getInstance();
    setState(() {
      _historyRepo = repo;
      _items = repo.getHistory();
    });
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
    final documentFile = item.documentPath == null
        ? null
        : File(item.documentPath!);
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
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text(
          'Lịch sử đã dịch',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: _items.isEmpty
          ? const Center(
              child: Text(
                'Chưa có lịch sử xử lý video nào',
                style: TextStyle(color: Colors.white54),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _items.length,
              itemBuilder: (context, index) {
                final it = _items[index];
                return Card(
                  color: const Color(0xFF1E1E1E),
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: const Icon(
                      Icons.video_library,
                      color: Colors.blueAccent,
                    ),
                    title: Text(
                      it.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    subtitle: Text(
                      DateTime.fromMillisecondsSinceEpoch(it.timestamp)
                          .toString()
                          .substring(0, 16),
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        color: Colors.redAccent,
                      ),
                      onPressed: () async {
                        await _historyRepo?.deleteItem(it.id);
                        _load();
                      },
                    ),
                    onTap: () => _openItem(it),
                  ),
                );
              },
            ),
    );
  }
}
