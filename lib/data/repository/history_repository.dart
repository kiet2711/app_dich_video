import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../model/history_item.dart';

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
      return list
          .map((e) => HistoryItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
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
      await _deleteIfExists(old.srtPath);
      if (old.documentPath != null) await _deleteIfExists(old.documentPath!);
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
