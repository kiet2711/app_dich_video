import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../model/history_item.dart';
import '../model/subtitle_document.dart';
import '../../domain/media/media_storage.dart';
import '../../domain/media/video_cache_manager.dart';
import '../../domain/tts/tts_cache_helper.dart';

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
    await repo.migrateHistoryPaths();
    historyNotifier.value = repo.getHistory();
    return repo;
  }

  /// Tự động sửa đường dẫn khi iOS thay đổi UUID sau mỗi lần cập nhật ứng dụng
  /// và tự động phát file offline nếu video online đã được tải vào cache
  static Future<String> resolvePath(String path) async {
    if (path.isEmpty || MediaStorage.isContentUri(path)) {
      return path;
    }
    if (path.startsWith('http://') || path.startsWith('https://')) {
      final cached = await VideoCacheManager.findCachedFile(url: path);
      if (cached != null && await cached.exists()) {
        return cached.path;
      }
      return path;
    }
    final file = File(path);
    if (await file.exists()) return path;

    try {
      final docs = await getApplicationDocumentsDirectory();
      final docsPath = docs.path;

      // 1. Kiểm tra nếu là file trong saved_subtitles
      if (path.contains('saved_subtitles')) {
        final filename = path.split(RegExp(r'[/\\]')).last;
        final candidate = File('$docsPath/saved_subtitles/$filename');
        if (await candidate.exists()) return candidate.path;
      }

      // 2. Kiểm tra nếu đường dẫn cũ có /Documents/
      if (path.contains('/Documents/')) {
        final relative = path.substring(
          path.indexOf('/Documents/') + '/Documents/'.length,
        );
        final candidate = File('$docsPath/$relative');
        if (await candidate.exists()) return candidate.path;
      }

      // 3. Kiểm tra nếu là video nằm trong thư mục media hoặc supportDir
      final supportDir = await getApplicationSupportDirectory();
      if (path.contains('/media/')) {
        final filename = path.split(RegExp(r'[/\\]')).last;
        final candidate = File('${supportDir.path}/media/$filename');
        if (await candidate.exists()) return candidate.path;
      }

      // 4. Kiểm tra nếu là file trong tmp/ (iOS temporary directory)
      final tempDir = await getTemporaryDirectory();
      if (path.contains('/tmp/')) {
        final filename = path.split(RegExp(r'[/\\]')).last;
        final candidate = File('${tempDir.path}/$filename');
        if (await candidate.exists()) return candidate.path;
      }
    } catch (_) {}

    return path;
  }

  /// Tự động dò quét và khôi phục các đường dẫn file bị lệch UUID do iOS cập nhật
  Future<void> migrateHistoryPaths() async {
    final items = getHistory();
    var hasChanges = false;
    final updatedList = <HistoryItem>[];

    for (final item in items) {
      var updated = item;
      final newSrt = await resolvePath(item.srtPath);
      if (newSrt != item.srtPath && await File(newSrt).exists()) {
        updated = updated.copyWith(srtPath: newSrt);
        hasChanges = true;
      }

      if (item.documentPath != null) {
        final newDoc = await resolvePath(item.documentPath!);
        if (newDoc != item.documentPath && await File(newDoc).exists()) {
          updated = updated.copyWith(documentPath: newDoc);
          hasChanges = true;
        }
      }

      final newVideo = await resolvePath(item.videoPath);
      if (newVideo != item.videoPath &&
          !MediaStorage.isContentUri(newVideo) &&
          await File(newVideo).exists()) {
        updated = updated.copyWith(videoPath: newVideo);
        hasChanges = true;
      }

      updatedList.add(updated);
    }

    if (hasChanges) {
      await _save(updatedList);
    }
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
    String? seriesId,
    String? seriesCover,
    int? episodeIndex,
    int? totalEpisodes,
  }) async {
    final docs = await getApplicationDocumentsDirectory();
    final savedSubtitlesDir = Directory('${docs.path}/saved_subtitles');
    if (!await savedSubtitlesDir.exists()) {
      await savedSubtitlesDir.create(recursive: true);
    }

    var effectiveVideoPath = videoPath;
    if (effectiveVideoPath.startsWith('http://') || effectiveVideoPath.startsWith('https://')) {
      final cached = await VideoCacheManager.findCachedFile(url: effectiveVideoPath);
      if (cached != null && await cached.exists()) {
        effectiveVideoPath = cached.path;
      }
    }

    final items = getHistory();
    final existing = items.where((it) => it.videoPath == effectiveVideoPath || it.videoPath == videoPath).firstOrNull;
    final id = existing?.id ?? DateTime.now().millisecondsSinceEpoch.toString();

    final srtFile = existing != null
        ? File(await resolvePath(existing.srtPath))
        : File('${savedSubtitlesDir.path}/sub_$id.srt');
    final docFile = File('${savedSubtitlesDir.path}/sub_$id.capsub.json');

    await srtFile.writeAsString(document.toSrtString(), flush: true);
    await docFile.writeAsString(jsonEncode(document.toJson()), flush: true);

    final docKey = TtsCacheHelper.getDocKey(document);

    final item = HistoryItem(
      id: id,
      title: title.isNotEmpty ? title : (existing?.title ?? 'Video'),
      videoPath: effectiveVideoPath,
      srtPath: srtFile.path,
      documentPath: docFile.path,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      durationMs: durationMs > 0 ? durationMs : (existing?.durationMs ?? 0),
      sentenceCount: document.items.length,
      ttsVoice: ttsVoice ?? existing?.ttsVoice,
      docKey: docKey,
      lastPositionMs: existing?.lastPositionMs ?? 0,
      seriesId: seriesId ?? existing?.seriesId,
      seriesCover: seriesCover ?? existing?.seriesCover,
      episodeIndex: episodeIndex ?? existing?.episodeIndex,
      totalEpisodes: totalEpisodes ?? existing?.totalEpisodes,
    );

    await addItem(item);
    return item;
  }

  /// Nạp SubtitleDocument an toàn từ HistoryItem (tự động khôi phục đường dẫn nếu iOS đổi UUID)
  Future<SubtitleDocument?> loadSubtitleDocument(HistoryItem item) async {
    if (item.documentPath != null) {
      final resolvedDoc = await resolvePath(item.documentPath!);
      final docFile = File(resolvedDoc);
      if (await docFile.exists()) {
        try {
          final content = await docFile.readAsString();
          return SubtitleDocument.fromJson(
            jsonDecode(content) as Map<String, dynamic>,
          );
        } catch (_) {}
      }
    }

    final resolvedSrt = await resolvePath(item.srtPath);
    final srtFile = File(resolvedSrt);
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

  Future<void> updatePlaybackPosition(String id, int positionMs) async {
    final items = getHistory();
    final index = items.indexWhere((item) => item.id == id);
    if (index == -1) return;
    final nonNegativePosition = positionMs < 0 ? 0 : positionMs;
    final safePosition = items[index].durationMs > 0
        ? nonNegativePosition.clamp(0, items[index].durationMs)
        : nonNegativePosition;
    if (items[index].lastPositionMs == safePosition) return;
    items[index] = items[index].copyWith(lastPositionMs: safePosition);
    await _save(items);
  }

  Future<void> updateVideoPath(String oldPath, String newPath) async {
    final items = getHistory();
    var changed = false;
    for (var i = 0; i < items.length; i++) {
      if (items[i].videoPath == oldPath) {
        items[i] = items[i].copyWith(videoPath: newPath);
        changed = true;
      }
    }
    if (changed) {
      await _save(items);
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
    // 1. Xóa file phụ đề .srt
    final resolvedSrt = await resolvePath(item.srtPath);
    await _deleteIfExists(resolvedSrt);

    // 2. Xóa toàn bộ thư mục cache âm thanh TTS (tts_cache/<docKey>) của video này
    try {
      final doc = await loadSubtitleDocument(item);
      await TtsCacheHelper.deleteDocCache(
        doc ?? SubtitleDocument(),
        item.docKey,
      );
      if (doc != null) {
        for (final sub in doc.items) {
          if (sub.audioFilePath != null && sub.audioFilePath!.isNotEmpty) {
            await _deleteIfExists(sub.audioFilePath!);
          }
        }
      }
    } catch (_) {}

    // 3. Xóa file tài liệu cấu trúc .capsub.json
    if (item.documentPath != null) {
      final resolvedDoc = await resolvePath(item.documentPath!);
      await _deleteIfExists(resolvedDoc);
    }

    // 4. Xóa bản sao video nội bộ nếu video được lưu trong thư mục media của app
    // và không còn bản ghi lịch sử nào khác đang dùng video này
    try {
      final remaining = getHistory();
      final isVideoStillUsed = remaining.any(
        (it) => it.id != item.id && it.videoPath == item.videoPath,
      );
      if (!isVideoStillUsed && !MediaStorage.isContentUri(item.videoPath)) {
        final supportDir = await getApplicationSupportDirectory();
        final mediaDir = Directory(
          '${supportDir.path}${Platform.pathSeparator}media',
        );
        if (item.videoPath.startsWith(mediaDir.path)) {
          await _deleteIfExists(item.videoPath);
        }
      }
    } catch (_) {}
  }

  Future<void> _deleteIfExists(String path) async {
    if (path.isEmpty ||
        MediaStorage.isContentUri(path) ||
        path.startsWith('http://') ||
        path.startsWith('https://')) {
      return;
    }
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
