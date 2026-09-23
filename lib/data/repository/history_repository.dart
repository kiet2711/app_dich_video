import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../model/history_item.dart';
import '../model/subtitle_document.dart';

class HistoryRepository {
  static const String _key = 'capsub_history';
  static final ValueNotifier<List<HistoryItem>> historyNotifier =
      ValueNotifier<List<HistoryItem>>([]);
  final SharedPreferences prefs;

  HistoryRepository(this.prefs) {
    historyNotifier.value = getHistory();
  }

  static Future<HistoryRepository> getInstance() async {
    final sp = await SharedPreferences.getInstance();
    final repo = HistoryRepository(sp);
    historyNotifier.value = repo.getHistory();
    return repo;
  }

  List<HistoryItem> getHistory() {
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final items = list
          .map((e) => HistoryItem.fromJson(e as Map<String, dynamic>))
          .toList();
      items.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return items;
    } catch (_) {
      return [];
    }
  }

  /// Lưu phụ đề và video vào lịch sử.
  /// Tự động sao chép file SRT và JSON vào thư mục tài liệu của ứng dụng để tránh bị mất.
  Future<HistoryItem> saveHistory({
    required String videoPath,
    required String title,
    required SubtitleDocument document,
    int durationMs = 0,
    String? ttsVoice,
  }) async {
    final docs = await getApplicationDocumentsDirectory();
    final savedSubtitlesDir = Directory('${docs.path}/saved_subtitles');
    if (!await savedSubtitlesDir.exists()) {
      await savedSubtitlesDir.create(recursive: true);
    }

    final items = getHistory();
    final existing = items.where((it) => it.videoPath == videoPath).firstOrNull;
    final id = existing?.id ?? DateTime.now().millisecondsSinceEpoch.toString();

    final srtFile = existing != null
        ? File(existing.srtPath)
        : File('${savedSubtitlesDir.path}/sub_$id.srt');
    final docFile = File('${savedSubtitlesDir.path}/sub_$id.capsub.json');

    await srtFile.writeAsString(document.toSrtString(), flush: true);
    await docFile.writeAsString(jsonEncode(document.toJson()), flush: true);

    final item = HistoryItem(
      id: id,
      title: title.isNotEmpty ? title : (existing?.title ?? 'Video'),
      videoPath: videoPath,
      srtPath: srtFile.path,
      documentPath: docFile.path,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      durationMs: durationMs > 0 ? durationMs : (existing?.durationMs ?? 0),
      sentenceCount: document.items.length,
      ttsVoice: ttsVoice ?? existing?.ttsVoice,
    );

    await addItem(item);
    return item;
  }

  /// Nạp SubtitleDocument an toàn từ HistoryItem
  Future<SubtitleDocument?> loadSubtitleDocument(HistoryItem item) async {
    if (item.documentPath != null) {
      final docFile = File(item.documentPath!);
      if (await docFile.exists()) {
        try {
          final content = await docFile.readAsString();
          return SubtitleDocument.fromJson(
            jsonDecode(content) as Map<String, dynamic>,
          );
        } catch (_) {}
      }
    }

    final srtFile = File(item.srtPath);
    if (await srtFile.exists()) {
      try {
        final content = await srtFile.readAsString();
        return SubtitleDocument.parseSrt(content);
      } catch (_) {}
    }

    return null;
  }

  Future<void> addItem(HistoryItem item) async {
    final items = getHistory();
    final replaced = items
        .where((it) => it.id == item.id || it.videoPath == item.videoPath)
        .toList();
    items.removeWhere(
      (it) => it.id == item.id || it.videoPath == item.videoPath,
    );
    items.insert(0, item);
    if (items.length > 50) items.removeLast();
    await _save(items);
    for (final old in replaced) {
      if (old.srtPath != item.srtPath) {
        await _deleteIfExists(old.srtPath);
      }
      if (old.documentPath != null && old.documentPath != item.documentPath) {
        await _deleteIfExists(old.documentPath!);
      }
    }
  }

  Future<void> deleteItem(String id) async {
    final items = getHistory();
    final removed = items.where((it) => it.id == id).toList();
    items.removeWhere((it) => it.id == id);
    await _save(items);
    for (final item in removed) {
      await _deleteItemFiles(item);
    }
  }

  Future<void> clearAll() async {
    final items = getHistory();
    await prefs.remove(_key);
    historyNotifier.value = [];
    for (final item in items) {
      await _deleteItemFiles(item);
    }
  }

  Future<void> _save(List<HistoryItem> items) async {
    final raw = jsonEncode(items.map((e) => e.toJson()).toList());
    await prefs.setString(_key, raw);
    historyNotifier.value = List.unmodifiable(items);
  }

  Future<void> _deleteItemFiles(HistoryItem item) async {
    await _deleteIfExists(item.srtPath);
    if (item.documentPath != null) {
      await _deleteIfExists(item.documentPath!);
    }
  }

  Future<void> _deleteIfExists(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
