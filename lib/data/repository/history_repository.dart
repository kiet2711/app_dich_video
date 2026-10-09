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

      // 3. Kiểm tra nếu là video nằm trong thư mục video_cache, media hoặc supportDir
      final supportDir = await getApplicationSupportDirectory();
      if (path.contains('video_cache')) {
        final filename = path.split(RegExp(r'[/\\]')).last;
        final candidate = File('${supportDir.path}/video_cache/$filename');
        if (await candidate.exists()) return candidate.path;
      }
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

  /// Tìm đường dẫn video tối ưu nhất cho một HistoryItem:
  /// 1. Nếu videoPath là file cục bộ và còn tồn tại -> dùng ngay
  /// 2. Tìm trong cache video với seriesId và episodeIndex (cho Hồng Quả) hoặc bvid (cho Bilibili)
  /// 3. Fallback resolvePath(item.videoPath)
  static Future<String> resolveItemVideoPath(HistoryItem item) async {
    // 1. Nếu videoPath là file cục bộ trên máy và còn tồn tại
    if (item.videoPath.isNotEmpty &&
        !item.videoPath.startsWith('http://') &&
        !item.videoPath.startsWith('https://')) {
      final resolved = await resolvePath(item.videoPath);
      final file = File(resolved);
      if (await file.exists() && await file.length() > 1024 * 50) {
        return resolved;
      }
    }

    // 2. Tìm trong thư mục video_cache thông qua VideoCacheManager
    try {
      final cached = await VideoCacheManager.findCachedFile(
        url: item.videoPath,
        seriesId: item.seriesId,
        episodeIndex: item.extractedEpisodeIndex,
      );
      if (cached != null && await cached.exists() && await cached.length() > 1024 * 50) {
        return cached.path;
      }
    } catch (_) {}

    // 3. Nếu là video Bilibili trực tuyến: Ưu tiên trả về link web video BV...
    // để tránh các URL stream CDN của Bilibili bị hết hạn token (403 Forbidden) sau vài giờ
    final bvMatch = RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false).firstMatch(item.videoPath) ??
        RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false).firstMatch(item.id) ??
        RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false).firstMatch(item.title);
    if (bvMatch != null &&
        (item.videoPath.startsWith('http://') ||
            item.videoPath.startsWith('https://') ||
            item.videoPath.isEmpty)) {
      return 'https://www.bilibili.com/video/${bvMatch.group(0)}';
    }

    // 4. Fallback resolvePath thông thường
    return await resolvePath(item.videoPath);
  }

  /// Lưu phụ đề và video vào lịch sử.
  /// Tự động sao chép file SRT và JSON vào thư mục tài liệu của ứng dụng để tránh bị mất.
  Future<HistoryItem> saveHistory({
    required String videoPath,
    required String title,
    required SubtitleDocument document,
    int durationMs = 0,
    int? lastPositionMs,
    String? ttsVoice,
    String? seriesId,
    String? seriesCover,
    String? coverUrl,
    int? episodeIndex,
    int? totalEpisodes,
    bool isPrefetch = false,
  }) async {
    final docs = await getApplicationDocumentsDirectory();
    final savedSubtitlesDir = Directory('${docs.path}/saved_subtitles');
    if (!await savedSubtitlesDir.exists()) {
      await savedSubtitlesDir.create(recursive: true);
    }

    final items = getHistory();
    final bvidMatch = RegExp(r'BV[a-zA-Z0-9]+', caseSensitive: false).firstMatch(videoPath)?.group(0);
    final normalizedSeriesId = seriesId?.trim();
    final hasEpisodeIdentity = normalizedSeriesId != null &&
        normalizedSeriesId.isNotEmpty &&
        episodeIndex != null &&
        episodeIndex > 0;
    final existing = items.where((it) {
      if (hasEpisodeIdentity &&
          it.seriesId == normalizedSeriesId &&
          it.extractedEpisodeIndex == episodeIndex) {
        return true;
      }
      if (it.videoPath == videoPath) return true;
      if (bvidMatch != null && it.videoPath.contains(bvidMatch)) return true;
      return false;
    }).firstOrNull;
    final id = existing?.id ?? DateTime.now().millisecondsSinceEpoch.toString();

    final srtFile = existing != null
        ? File(await resolvePath(existing.srtPath))
        : File('${savedSubtitlesDir.path}/sub_$id.srt');
    final docFile = File('${savedSubtitlesDir.path}/sub_$id.capsub.json');

    await srtFile.writeAsString(document.toSrtString(), flush: true);
    await docFile.writeAsString(jsonEncode(document.toJson()), flush: true);

    final docKey = TtsCacheHelper.getDocKey(document);

    bool isGenericTitle(String? t) {
      if (t == null || t.trim().isEmpty) return true;
      final clean = t.trim().toLowerCase();
      final withoutExt = clean.replaceAll(RegExp(r'\.mp4$', caseSensitive: false), '').trim();
      return withoutExt == 'video' ||
          withoutExt == 'video import' ||
          withoutExt.startsWith('video online') ||
          withoutExt.startsWith('bili_') ||
          withoutExt.startsWith('video_') ||
          withoutExt.startsWith('hg_');
    }

    var cleanTitle = title.replaceAll(RegExp(r'\.mp4$', caseSensitive: false), '').trim();
    if (isGenericTitle(cleanTitle)) {
      if (existing != null && !isGenericTitle(existing.title)) {
        cleanTitle = existing.title;
      } else if (cleanTitle.isEmpty) {
        cleanTitle = existing?.title ?? 'Video';
      }
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    // Nếu là prefetch dịch ngầm: không gán lastWatchedAt và không cướp timestamp của tập đang xem dở
    final lastWatchedAt = existing?.lastWatchedAt ?? (isPrefetch ? null : now);
    final timestamp = existing?.timestamp ?? (isPrefetch ? (now - 1000) : now);

    final item = HistoryItem(
      id: id,
      title: cleanTitle,
      originalTitle: existing?.originalTitle ?? cleanTitle,
      translatedTitle: existing?.translatedTitle,
      videoPath: videoPath,
      srtPath: srtFile.path,
      documentPath: docFile.path,
      timestamp: timestamp,
      durationMs: durationMs > 0 ? durationMs : (existing?.durationMs ?? 0),
      sentenceCount: document.items.length,
      ttsVoice: ttsVoice ?? existing?.ttsVoice,
      docKey: docKey,
      lastPositionMs: lastPositionMs ?? existing?.lastPositionMs ?? 0,
      lastWatchedAt: lastWatchedAt,
      seriesId: seriesId ?? existing?.seriesId,
      seriesCover: coverUrl ?? seriesCover ?? existing?.seriesCover,
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
    bool isSameItem(HistoryItem candidate) {
      final sameSeriesEpisode = item.seriesId != null &&
          item.seriesId!.isNotEmpty &&
          candidate.seriesId == item.seriesId &&
          candidate.extractedEpisodeIndex == item.extractedEpisodeIndex;
      return candidate.id == item.id ||
          candidate.videoPath == item.videoPath ||
          sameSeriesEpisode;
    }

    final replaced = items.where(isSameItem).toList();
    items.removeWhere(isSameItem);
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

  Future<void> markWatched(String id) async {
    final items = getHistory();
    final index = items.indexWhere((item) => item.id == id);
    if (index == -1) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    items[index] = items[index].copyWith(
      lastWatchedAt: now,
      timestamp: now,
    );
    await _save(items);
  }

  Future<void> updatePlaybackPosition(
    String id,
    int positionMs, {
    int? durationMs,
  }) async {
    final items = getHistory();
    final index = items.indexWhere((item) => item.id == id);
    if (index == -1) return;
    final current = items[index];
    final effectiveDuration = (durationMs != null && durationMs > 0)
        ? durationMs
        : current.durationMs;
    final nonNegativePosition = positionMs < 0 ? 0 : positionMs;
    final safePosition = effectiveDuration > 0
        ? nonNegativePosition.clamp(0, effectiveDuration)
        : nonNegativePosition;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (current.lastPositionMs == safePosition &&
        current.lastWatchedAt != null &&
        (current.durationMs == effectiveDuration || effectiveDuration <= 0)) {
      return;
    }
    items[index] = current.copyWith(
      lastPositionMs: safePosition,
      durationMs: effectiveDuration,
      lastWatchedAt: now,
      timestamp: now,
    );
    await _save(items);
  }

  /// Cập nhật tiến độ xem cho video dựa trên videoPath / BVID / ID lịch sử
  /// Dành cho Bilibili và các video đơn lẻ khi phát trực tiếp hoặc từ lịch sử
  Future<bool> updatePlaybackPositionForVideo({
    required String videoPath,
    required int positionMs,
    int? durationMs,
    String? title,
    String? coverUrl,
    bool createIfMissing = false,
  }) async {
    final items = getHistory();
    final bvid = RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false).firstMatch(videoPath)?.group(0);

    final index = items.indexWhere((item) {
      if (item.videoPath == videoPath || item.id == videoPath) return true;
      if (bvid != null) {
        if (item.videoPath.contains(bvid) || item.id.contains(bvid)) return true;
        final itemBv = RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false).firstMatch(item.title)?.group(0);
        if (itemBv != null && itemBv.toLowerCase() == bvid.toLowerCase()) return true;
      }
      return false;
    });

    final now = DateTime.now().millisecondsSinceEpoch;
    final nonNegativePosition = positionMs < 0 ? 0 : positionMs;

    if (index != -1) {
      final current = items[index];
      final effectiveDuration = (durationMs != null && durationMs > 0)
          ? durationMs
          : current.durationMs;
      final safePosition = effectiveDuration > 0
          ? nonNegativePosition.clamp(0, effectiveDuration)
          : nonNegativePosition;

      if (current.lastPositionMs == safePosition &&
          current.lastWatchedAt != null &&
          (current.durationMs == effectiveDuration || effectiveDuration <= 0)) {
        return true;
      }

      items[index] = current.copyWith(
        lastPositionMs: safePosition,
        durationMs: effectiveDuration,
        lastWatchedAt: now,
        timestamp: now,
        seriesCover: (current.seriesCover == null || current.seriesCover!.isEmpty)
            ? coverUrl
            : current.seriesCover,
      );
      await _save(items);
      return true;
    }

    if (createIfMissing && nonNegativePosition > 2000) {
      final effectiveDuration = (durationMs != null && durationMs > 0) ? durationMs : 0;
      final safePosition = effectiveDuration > 0
          ? nonNegativePosition.clamp(0, effectiveDuration)
          : nonNegativePosition;
      await saveHistory(
        videoPath: videoPath,
        title: (title != null && title.trim().isNotEmpty) ? title.trim() : 'Bilibili Video',
        document: SubtitleDocument(),
        coverUrl: coverUrl,
        durationMs: effectiveDuration,
        lastPositionMs: safePosition,
      );
      return true;
    }

    return false;
  }

  /// Cập nhật đúng tập đang phát trong một bộ Hồng Quả. URL video có thể đổi
  /// theo phiên nên không dùng videoPath làm định danh cho trường hợp này.
  Future<bool> updateSeriesPlaybackPosition({
    required String seriesId,
    required int episodeIndex,
    required int positionMs,
    int? durationMs,
    String? seriesTitle,
  }) async {
    if (seriesId.trim().isEmpty || episodeIndex <= 0) return false;
    final items = getHistory();
    final normalizedTitle = seriesTitle?.trim().toLowerCase();
    final index = items.indexWhere((item) {
      final sameSeriesId = item.seriesId == seriesId;
      final legacyTitleMatch =
          (item.seriesId == null || item.seriesId!.isEmpty) &&
          normalizedTitle != null &&
          normalizedTitle.isNotEmpty &&
          item.extractedSeriesTitle.trim().toLowerCase() == normalizedTitle;
      return (sameSeriesId || legacyTitleMatch) &&
          item.extractedEpisodeIndex == episodeIndex;
    });
    if (index == -1) return false;

    final current = items[index];
    final effectiveDuration = durationMs != null && durationMs > 0
        ? durationMs
        : current.durationMs;
    final nonNegativePosition = positionMs < 0 ? 0 : positionMs;
    final safePosition = effectiveDuration > 0
        ? nonNegativePosition.clamp(0, effectiveDuration)
        : nonNegativePosition;
    final now = DateTime.now().millisecondsSinceEpoch;
    items[index] = current.copyWith(
      durationMs: effectiveDuration,
      lastPositionMs: safePosition,
      lastWatchedAt: now,
      timestamp: now,
    );
    await _save(items);
    return true;
  }

  Future<bool> markSeriesEpisodeWatched({
    required String seriesId,
    required int episodeIndex,
    String? seriesTitle,
  }) async {
    if (seriesId.trim().isEmpty || episodeIndex <= 0) return false;
    final items = getHistory();
    final normalizedTitle = seriesTitle?.trim().toLowerCase();
    final index = items.indexWhere((item) {
      final sameSeriesId = item.seriesId == seriesId;
      final legacyTitleMatch =
          (item.seriesId == null || item.seriesId!.isEmpty) &&
          normalizedTitle != null &&
          normalizedTitle.isNotEmpty &&
          item.extractedSeriesTitle.trim().toLowerCase() == normalizedTitle;
      return (sameSeriesId || legacyTitleMatch) &&
          item.extractedEpisodeIndex == episodeIndex;
    });
    if (index == -1) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    items[index] = items[index].copyWith(
      lastWatchedAt: now,
      timestamp: now,
    );
    await _save(items);
    return true;
  }

  Future<void> updateVideoPath(String oldPath, String newPath) async {
    final items = getHistory();
    final bvid = RegExp(r'BV[a-zA-Z0-9]+', caseSensitive: false).firstMatch(oldPath)?.group(0);
    var changed = false;
    for (var i = 0; i < items.length; i++) {
      if (items[i].videoPath == oldPath ||
          (bvid != null && items[i].videoPath.contains(bvid))) {
        items[i] = items[i].copyWith(videoPath: newPath);
        changed = true;
      }
    }
    if (changed) {
      await _save(items);
    }
  }

  Future<void> updateTitleForVideo(String videoPath, String newTitle) async {
    final clean = newTitle.replaceAll(RegExp(r'\.mp4$', caseSensitive: false), '').trim();
    if (clean.isEmpty) return;
    final bvid = RegExp(r'BV[a-zA-Z0-9]+', caseSensitive: false).firstMatch(videoPath)?.group(0);

    final items = getHistory();
    var changed = false;
    for (var i = 0; i < items.length; i++) {
      final matchesPath = items[i].videoPath == videoPath ||
          (bvid != null && items[i].videoPath.contains(bvid));
      if (matchesPath) {
        if (items[i].title != clean || items[i].originalTitle != clean) {
          items[i] = items[i].copyWith(
            title: clean,
            originalTitle: clean,
          );
          changed = true;
        }
      }
    }
    if (changed) {
      await _save(items);
    }
  }

  Future<void> updateCoverForVideo(String idOrVideoPath, String newCoverUrl) async {
    final clean = newCoverUrl.trim();
    if (clean.isEmpty) return;
    final bvid = RegExp(r'BV[a-zA-Z0-9]+', caseSensitive: false).firstMatch(idOrVideoPath)?.group(0);

    final items = getHistory();
    var changed = false;
    for (var i = 0; i < items.length; i++) {
      final matches = items[i].id == idOrVideoPath ||
          items[i].videoPath == idOrVideoPath ||
          (bvid != null && items[i].videoPath.contains(bvid));
      if (matches) {
        if (items[i].seriesCover != clean) {
          items[i] = items[i].copyWith(seriesCover: clean);
          changed = true;
        }
      }
    }
    if (changed) {
      await _save(items);
    }
  }

  Future<void> updateTranslatedTitle(String idOrVideoPath, String translatedTitle) async {
    final clean = translatedTitle.replaceAll(RegExp(r'\.mp4$', caseSensitive: false), '').trim();
    if (clean.isEmpty) return;
    final bvid = RegExp(r'BV[a-zA-Z0-9]+', caseSensitive: false).firstMatch(idOrVideoPath)?.group(0);

    final items = getHistory();
    var changed = false;
    for (var i = 0; i < items.length; i++) {
      final matches = items[i].id == idOrVideoPath ||
          items[i].videoPath == idOrVideoPath ||
          items[i].title == idOrVideoPath ||
          (bvid != null && items[i].videoPath.contains(bvid));
      if (matches) {
        items[i] = items[i].copyWith(
          translatedTitle: clean,
          originalTitle: items[i].originalTitle ?? items[i].title,
        );
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

  /// Xóa hàng loạt các mục lịch sử cùng lúc (tối ưu hóa lưu trữ và cập nhật UI một lần)
  Future<void> deleteItems(Iterable<String> ids) async {
    final idSet = ids.toSet();
    if (idSet.isEmpty) return;
    final items = getHistory();
    final removed = items.where((it) => idSet.contains(it.id)).toList();
    if (removed.isEmpty) return;
    items.removeWhere((it) => idSet.contains(it.id));
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

    // 5. Xóa file video tải về trong cache của Hồng Quả nếu có
    if (item.seriesId != null && item.seriesId!.isNotEmpty) {
      try {
        await VideoCacheManager.deleteHongguoEpisodeCache(
          seriesId: item.seriesId!,
          episodeIndex: item.extractedEpisodeIndex,
        );
      } catch (_) {}
    }
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
