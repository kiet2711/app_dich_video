import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../data/repository/settings_repository.dart';
import '../hongguo_resolver.dart';
import '../video_cache_manager.dart';
import 'hongguo_cloud_account_service.dart';
import 'hongguo_discovery_service.dart';
import 'hongguo_local_engine.dart';
import 'hongguo_similar_engine.dart';

/// Dữ liệu của một trang trong Feed Shorts / Lướt Hồng Quả.
class FeedDramaPageItem {
  final HongguoDramaDetail detail;
  final int episodeIndex;
  final String vid;

  const FeedDramaPageItem({
    required this.detail,
    required this.episodeIndex,
    required this.vid,
  });
}

/// Nguồn phát video trực tiếp (URL hoặc file cache + CENC key + VideoInfo).
class HongguoFeedPreparedSource {
  final String url;
  final String? decryptionKey;
  final Map<String, String> headers;
  final HongguoVideoInfo? videoInfo;
  final String vid;
  final String seriesId;
  final int episodeIndex;
  final DateTime resolvedAt;
  final bool isLocalFile;

  HongguoFeedPreparedSource({
    required this.url,
    this.decryptionKey,
    this.headers = const {},
    this.videoInfo,
    this.vid = '',
    this.seriesId = '',
    this.episodeIndex = 1,
    DateTime? resolvedAt,
    this.isLocalFile = false,
  }) : resolvedAt = resolvedAt ?? DateTime.now();

  bool get isFresh {
    if (url.isEmpty) return false;
    if (isLocalFile) return true;
    // Bỏ qua URL proxy localhost cũ khi mở phiên mới nếu cần tạo lại proxy URL.
    if (url.startsWith('http://127.0.0.1:') ||
        url.startsWith('http://localhost:')) {
      return false;
    }
    return DateTime.now().difference(resolvedAt) < const Duration(minutes: 15);
  }
}

/// Bộ nhớ đệm nhẹ giữ "cái đáy" cho chế độ Lướt kiểu TikTok giữa các lần thoát/mở lại,
/// đồng thời hỗ trợ nạp sẵn danh sách + URL tập đầu tiên ngay khi mở ứng dụng.
///
/// Dung lượng RAM chỉ ~2–5 MB (metadata danh sách phim, vị trí cuộn, URL phát),
/// không giữ decoder/player native (~50–120 MB/player) khi đã thoát màn hình Lướt.
class HongguoFeedSessionCache {
  HongguoFeedSessionCache._();

  static final HongguoFeedSessionCache instance = HongguoFeedSessionCache._();

  static const String tabFollow = 'follow';
  static const String tabComic = 'comic';
  static const String tabReal = 'real';
  static const String tabDiscover = 'discover';

  static const Map<String, String> defaultStreamHeaders = <String, String>{
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0',
    'Referer': 'https://novel.snssdk.com/',
  };

  final math.Random _rng = math.Random();
  Future<void>? _inflightWarmup;

  bool hasWarmedInitialTab = false;
  String? lastWarmupError;
  String? warmedAccountUserId;

  String get currentAccountUserId =>
      HongguoCloudAccountService.instance.state.value.credentials?.userId ?? '';

  bool isCacheValidForCurrentAccount() {
    if (warmedAccountUserId == null) return true;
    return warmedAccountUserId == currentAccountUserId;
  }

  void invalidateCache() {
    hasWarmedInitialTab = false;
    lastWarmupError = null;
    warmedAccountUserId = null;
    for (final list in tabItems.values) {
      list.clear();
    }
    tabIndices[tabFollow] = 0;
    tabIndices[tabComic] = 0;
    tabIndices[tabReal] = 0;
    tabIndices[tabDiscover] = 0;
    comicCursor = null;
    realCursor = null;
    comicSelectionOverride = null;
    realSelectionOverride = null;
    followSeedOffset = 0;
    preparedSources.clear();
    lastPositionMsByMediaKey.clear();
  }

  String currentTab = tabDiscover;
  final Map<String, List<FeedDramaPageItem>> tabItems = {
    tabFollow: <FeedDramaPageItem>[],
    tabComic: <FeedDramaPageItem>[],
    tabReal: <FeedDramaPageItem>[],
    tabDiscover: <FeedDramaPageItem>[],
  };
  final Map<String, int> tabIndices = {
    tabFollow: 0,
    tabComic: 0,
    tabReal: 0,
    tabDiscover: 0,
  };

  HongguoDiscoveryCursor? comicCursor;
  HongguoDiscoveryCursor? realCursor;
  HongguoDiscoverySelection? comicSelectionOverride;
  HongguoDiscoverySelection? realSelectionOverride;
  int followSeedOffset = 0;

  final Map<String, HongguoFeedPreparedSource> preparedSources = {};
  final Map<String, int> lastPositionMsByMediaKey = {};

  bool get isWarmupInFlight => _inflightWarmup != null;

  bool get hasAnyDiscoverItems =>
      tabItems.values.any((items) => items.isNotEmpty);

  static String normalizeTab(String key) {
    return switch (key) {
      tabFollow || tabComic || tabReal || tabDiscover => key,
      _ => tabDiscover,
    };
  }

  static String mediaKeyFor(FeedDramaPageItem item) =>
      '${item.detail.seriesId}:${item.episodeIndex}';

  static HongguoDramaDetail dramaItemToDetail(HongguoDramaItem drama) {
    return HongguoDramaDetail(
      seriesId: drama.seriesId,
      title: drama.title,
      cover: drama.cover,
      intro: drama.intro,
      totalEpisodes: drama.episodeCount,
      tags: drama.tags,
      sourceCategory: drama.sourceCategory,
      categoryIds: drama.categoryIds,
      episodes: [
        for (var i = 0; i < drama.vidList.length; i++)
          HongguoEpisodeItem(
            index: i + 1,
            vid: drama.vidList[i],
            title: 'Tập ${i + 1}',
          ),
      ],
    );
  }

  FeedDramaPageItem createFeedDramaItem(HongguoDramaItem drama) {
    final detail = dramaItemToDetail(drama);
    final totalEp = drama.episodeCount > 0
        ? drama.episodeCount
        : (drama.vidList.isNotEmpty ? drama.vidList.length : 1);
    final maxEp = math.min(10, totalEp);
    final randomEp = maxEp > 1 ? (_rng.nextInt(maxEp) + 1) : 1;
    final vid = (drama.vidList.length >= randomEp)
        ? drama.vidList[randomEp - 1]
        : (drama.vidList.isNotEmpty ? drama.vidList.first : '');
    return FeedDramaPageItem(detail: detail, episodeIndex: randomEp, vid: vid);
  }

  List<HongguoDramaItem> prioritizeUnwatchedDramas(
    List<HongguoDramaItem> dramas, {
    required Set<String> seenSeriesIds,
    bool strictFilter = false,
  }) {
    if (dramas.isEmpty || seenSeriesIds.isEmpty) return dramas;

    final unwatched = <HongguoDramaItem>[];
    final watched = <HongguoDramaItem>[];

    for (final d in dramas) {
      if (seenSeriesIds.contains(d.seriesId)) {
        watched.add(d);
      } else {
        unwatched.add(d);
      }
    }

    if (unwatched.length >= 6 || strictFilter) {
      return unwatched;
    }

    final shuffledWatched = List<HongguoDramaItem>.from(watched)..shuffle(_rng);
    return [...unwatched, ...shuffledWatched];
  }

  /// Chờ lần nạp ngầm khởi động nếu đang chạy. Không làm treo UI nếu có lỗi mạng.
  Future<void> waitForWarmupIfRunning() async {
    final future = _inflightWarmup;
    if (future == null) return;
    try {
      await future;
    } catch (_) {}
  }

  /// Nạp ngầm danh sách Feed + URL nguồn video đầu tiên ngay khi mở app.
  Future<void> warmupOnAppStart({bool forceRefresh = false}) {
    if (_inflightWarmup != null) return _inflightWarmup!;
    final future = _performWarmup(forceRefresh: forceRefresh);
    _inflightWarmup = future;
    future.whenComplete(() {
      if (identical(_inflightWarmup, future)) {
        _inflightWarmup = null;
      }
    });
    return future;
  }

  Future<void> _performWarmup({required bool forceRefresh}) async {
    try {
      // Bắt buộc nạp xong tài khoản/Cookie Hồng Quả trước khi lấy đề xuất
      // để luồng Đề xuất & Mạn kịch/Người thật luôn cá nhân hóa đúng theo tài khoản.
      await HongguoCloudAccountService.instance.initialize();
      final activeUserId = currentAccountUserId;
      if (warmedAccountUserId != null && warmedAccountUserId != activeUserId) {
        invalidateCache();
      }
      warmedAccountUserId = activeUserId;

      final settings = await SettingsRepository.getInstance();
      final targetTab = normalizeTab(
        hasAnyDiscoverItems ? currentTab : settings.hongguoFeedTab,
      );
      if (!forceRefresh &&
          hasWarmedInitialTab &&
          (tabItems[targetTab]?.isNotEmpty ?? false)) {
        await _warmFirstItemIfNeeded(
          targetTab,
          preferredQuality: settings.hongguoPreferredQuality,
        );
        return;
      }

      if (!hasAnyDiscoverItems) {
        currentTab = targetTab;
      }

      final existingTarget = tabItems[targetTab] ?? <FeedDramaPageItem>[];
      if (!forceRefresh && existingTarget.isNotEmpty) {
        hasWarmedInitialTab = true;
        await _warmFirstItemIfNeeded(
          targetTab,
          preferredQuality: settings.hongguoPreferredQuality,
        );
        return;
      }

      final seenIds = settings.hongguoSeenSeriesIds.toSet();
      List<FeedDramaPageItem> warmedItems = <FeedDramaPageItem>[];

      if (targetTab == tabFollow) {
        final res = await HongguoSimilarEngine.instance.getFollowFeedList(
          seedOffset: followSeedOffset,
        );
        warmedItems = res.items.map(createFeedDramaItem).toList();
      } else if (targetTab == tabComic || targetTab == tabReal) {
        final isComic = targetTab == tabComic;
        final kind = isComic
            ? HongguoGenreKind.comicSeries
            : HongguoGenreKind.realPlay;
        final overrideSel = isComic
            ? comicSelectionOverride
            : realSelectionOverride;
        final selection =
            overrideSel ?? HongguoDiscoverySelection(genreKind: kind);
        final page = await HongguoDiscoveryService.instance.fetchDiscovery(
          selection,
          seenIds: seenIds,
          useDefaultFeedSort: overrideSel == null,
        );
        if (isComic) {
          comicCursor = page.nextCursor;
        } else {
          realCursor = page.nextCursor;
        }
        final sorted = prioritizeUnwatchedDramas(
          page.items,
          seenSeriesIds: seenIds,
        );
        warmedItems = sorted.map(createFeedDramaItem).toList();
      } else {
        final list = await HongguoSimilarEngine.instance
            .getPersonalizedDiscoverList(resetCursor: false);
        final sorted = prioritizeUnwatchedDramas(
          list,
          seenSeriesIds: seenIds,
        );
        warmedItems = sorted.map(createFeedDramaItem).toList();
      }

      // Chỉ ghi nếu trong lúc chờ API user chưa tự mở feed và tự nạp tab này.
      if (forceRefresh || (tabItems[targetTab]?.isEmpty ?? true)) {
        tabItems[targetTab] = warmedItems;
        tabIndices[targetTab] = 0;
      }

      hasWarmedInitialTab = true;
      lastWarmupError = null;

      await _warmFirstItemIfNeeded(
        targetTab,
        preferredQuality: settings.hongguoPreferredQuality,
      );
    } catch (e) {
      lastWarmupError = e.toString();
      debugPrint('[HongguoFeedWarmup] Lỗi warmup khởi động: $e');
    }
  }

  Future<void> _warmFirstItemIfNeeded(
    String tabKey, {
    required String preferredQuality,
  }) async {
    final items = tabItems[tabKey];
    if (items == null || items.isEmpty) return;
    final idx = (tabIndices[tabKey] ?? 0).clamp(0, items.length - 1);
    var targetItem = items[idx];

    try {
      if (targetItem.vid.isEmpty ||
          targetItem.vid == targetItem.detail.seriesId ||
          targetItem.detail.episodes.isEmpty ||
          targetItem.detail.episodes.length < targetItem.episodeIndex) {
        final fullDetail = await HongguoResolver().getDramaDetail(
          targetItem.detail.seriesId,
        );
        if (fullDetail.episodes.isNotEmpty) {
          final epIdx = targetItem.episodeIndex.clamp(
            1,
            fullDetail.episodes.length,
          );
          targetItem = FeedDramaPageItem(
            detail: fullDetail,
            episodeIndex: epIdx,
            vid: fullDetail.episodes[epIdx - 1].vid,
          );
          if (idx < items.length &&
              items[idx].detail.seriesId == fullDetail.seriesId) {
            items[idx] = targetItem;
          }
        }
      }

      if (targetItem.vid.isEmpty) return;

      final key = mediaKeyFor(targetItem);
      final existing = preparedSources[key];
      if (existing != null && existing.isFresh) return;

      final cachedFile = await VideoCacheManager.findCachedFile(
        url: '',
        seriesId: targetItem.detail.seriesId,
        episodeIndex: targetItem.episodeIndex,
      );
      if (cachedFile != null &&
          cachedFile.existsSync() &&
          cachedFile.lengthSync() > 1024 * 50) {
        putPreparedSource(
          key,
          HongguoFeedPreparedSource(
            url: cachedFile.path,
            vid: targetItem.vid,
            seriesId: targetItem.detail.seriesId,
            episodeIndex: targetItem.episodeIndex,
            isLocalFile: true,
          ),
        );
        return;
      }

      final info = await HongguoLocalEngine.resolveVideoInfo(
        targetItem.vid,
        preferredQuality: preferredQuality,
      );
      if (info.realMainUrl.isNotEmpty) {
        putPreparedSource(
          key,
          HongguoFeedPreparedSource(
            url: info.realMainUrl,
            decryptionKey: info.isDrmProtected ? info.contentKeyHex : null,
            videoInfo: info,
            vid: targetItem.vid,
            seriesId: targetItem.detail.seriesId,
            episodeIndex: targetItem.episodeIndex,
            headers: defaultStreamHeaders,
          ),
        );
      }
    } catch (e) {
      debugPrint('[HongguoFeedWarmup] Bỏ qua lỗi warmup video đầu: $e');
    }
  }

  void putPreparedSource(String key, HongguoFeedPreparedSource source) {
    if (!source.isFresh) return;
    preparedSources.remove(key);
    preparedSources[key] = source;
    while (preparedSources.length > 8) {
      preparedSources.remove(preparedSources.keys.first);
    }
  }

  void savePositionMs(String mediaKey, int positionMs) {
    if (positionMs < 0) return;
    lastPositionMsByMediaKey.remove(mediaKey);
    if (positionMs > 0) {
      lastPositionMsByMediaKey[mediaKey] = positionMs;
    }
    while (lastPositionMsByMediaKey.length > 30) {
      lastPositionMsByMediaKey.remove(lastPositionMsByMediaKey.keys.first);
    }
  }

  /// Lưu trạng thái phiên Lướt hiện tại vào RAM để lần sau mở lại khôi phục tức thì.
  void saveSessionState({
    required String activeTab,
    required int activeIndex,
    required List<FeedDramaPageItem> activeFeedItems,
    required List<FeedDramaPageItem> followItems,
    required List<FeedDramaPageItem> comicItems,
    required List<FeedDramaPageItem> realItems,
    required List<FeedDramaPageItem> discoverItems,
    required Map<String, int> indices,
    required HongguoDiscoveryCursor? comicCursor,
    required HongguoDiscoveryCursor? realCursor,
    required HongguoDiscoverySelection? comicSelectionOverride,
    required HongguoDiscoverySelection? realSelectionOverride,
    required int followSeedOffset,
    required Map<String, HongguoFeedPreparedSource> sources,
    String? activeMediaKey,
    int? activePositionMs,
  }) {
    final normalizedTab = normalizeTab(activeTab);
    currentTab = normalizedTab;

    tabItems[tabFollow] = List<FeedDramaPageItem>.from(followItems);
    tabItems[tabComic] = List<FeedDramaPageItem>.from(comicItems);
    tabItems[tabReal] = List<FeedDramaPageItem>.from(realItems);
    tabItems[tabDiscover] = List<FeedDramaPageItem>.from(discoverItems);
    if (activeFeedItems.isNotEmpty) {
      tabItems[normalizedTab] = List<FeedDramaPageItem>.from(activeFeedItems);
    }

    for (final entry in indices.entries) {
      tabIndices[normalizeTab(entry.key)] = entry.value;
    }
    if (activeFeedItems.isNotEmpty) {
      tabIndices[normalizedTab] = activeIndex.clamp(
        0,
        activeFeedItems.length - 1,
      );
    }

    this.comicCursor = comicCursor;
    this.realCursor = realCursor;
    this.comicSelectionOverride = comicSelectionOverride;
    this.realSelectionOverride = realSelectionOverride;
    this.followSeedOffset = followSeedOffset;

    for (final entry in sources.entries) {
      if (entry.value.isFresh) {
        putPreparedSource(entry.key, entry.value);
      }
    }

    if (activeMediaKey != null && activePositionMs != null) {
      savePositionMs(activeMediaKey, activePositionMs);
    }
  }
}
