import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../model/watch_later_item.dart';

class WatchLaterRepository {
  static const String _key = 'capsub_watch_later';
  static final ValueNotifier<List<WatchLaterItem>> watchLaterNotifier =
      ValueNotifier<List<WatchLaterItem>>([]);

  final SharedPreferences prefs;

  WatchLaterRepository(this.prefs) {
    watchLaterNotifier.value = getItems();
  }

  static Future<WatchLaterRepository> getInstance() async {
    final sp = await SharedPreferences.getInstance();
    final repo = WatchLaterRepository(sp);
    watchLaterNotifier.value = repo.getItems();
    return repo;
  }

  List<WatchLaterItem> getItems() {
    final raw = prefs.getStringList(_key);
    if (raw == null) return [];
    final items = <WatchLaterItem>[];
    for (final s in raw) {
      try {
        final map = jsonDecode(s) as Map<String, dynamic>;
        items.add(WatchLaterItem.fromJson(map));
      } catch (_) {}
    }
    // Sắp xếp mới nhất lên đầu
    items.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return items;
  }

  bool isWatchLater(String id) {
    if (id.isEmpty) return false;
    final cleanId = _normalizeId(id);
    return getItems().any((it) => _normalizeId(it.id) == cleanId || it.targetUrl.contains(cleanId));
  }

  String _normalizeId(String id) {
    return id.replaceAll(RegExp(r'^(bili_|hg_)'), '').trim();
  }

  Future<bool> toggleWatchLater(WatchLaterItem item) async {
    final cleanId = _normalizeId(item.id);
    final current = getItems();
    final existsIndex = current.indexWhere((it) => _normalizeId(it.id) == cleanId || it.targetUrl == item.targetUrl);

    if (existsIndex >= 0) {
      // Đã có -> Xóa đi
      current.removeAt(existsIndex);
      await _save(current);
      return false;
    } else {
      // Chưa có -> Thêm vào đầu
      current.insert(0, item);
      await _save(current);
      return true;
    }
  }

  Future<void> addItem(WatchLaterItem item) async {
    final cleanId = _normalizeId(item.id);
    final current = getItems();
    current.removeWhere((it) => _normalizeId(it.id) == cleanId || it.targetUrl == item.targetUrl);
    current.insert(0, item);
    await _save(current);
  }

  Future<void> removeItem(String id) async {
    final cleanId = _normalizeId(id);
    final current = getItems();
    current.removeWhere((it) => _normalizeId(it.id) == cleanId || it.targetUrl.contains(cleanId));
    await _save(current);
  }

  Future<void> updateTranslatedTitle(String id, String translatedTitle) async {
    final cleanId = _normalizeId(id);
    final current = getItems();
    final index = current.indexWhere((it) => _normalizeId(it.id) == cleanId);
    if (index >= 0) {
      current[index] = current[index].copyWith(translatedTitle: translatedTitle);
      await _save(current);
    }
  }

  Future<void> clearAll() async {
    await prefs.remove(_key);
    watchLaterNotifier.value = [];
  }

  Future<void> _save(List<WatchLaterItem> items) async {
    final list = items.map((it) => jsonEncode(it.toJson())).toList();
    await prefs.setStringList(_key, list);
    watchLaterNotifier.value = List.unmodifiable(items);
  }
}
