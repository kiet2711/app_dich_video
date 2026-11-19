import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/model/history_item.dart';
import '../../data/model/subtitle_document.dart';
import '../../data/model/watch_later_item.dart';
import '../../data/repository/history_repository.dart';
import '../../data/repository/watch_later_repository.dart';
import '../../domain/ai/title_translator.dart';
import '../../domain/media/bilibili_resolver.dart';
import '../../domain/media/hongguo_resolver.dart';
import '../../domain/media/media_storage.dart';
import '../../domain/media/video_cache_manager.dart';
import '../../data/repository/settings_repository.dart';
import '../../player/global_player_manager.dart';
import '../settings/settings_screen.dart';
import '../storage/storage_cleaner_screen.dart';
import '../theme/app_theme.dart';
import 'import_subtitle_dialog.dart';
import '../hongguo/feed/hongguo_feed_screen.dart';

/// Mô hình nhóm các tập của một bộ phim trong Lịch sử
class DramaHistoryGroup {
  final String seriesKey;
  final String? seriesId;
  final String seriesTitle;
  final String? seriesCover;
  final int totalEpisodes;
  final List<HistoryItem> episodes;

  DramaHistoryGroup({
    required this.seriesKey,
    this.seriesId,
    required this.seriesTitle,
    this.seriesCover,
    this.totalEpisodes = 0,
    required this.episodes,
  });

  List<HistoryItem> get _watchedEpisodes {
    final watched = episodes.where((episode) {
      return (episode.lastWatchedAt != null && episode.lastWatchedAt! > 0) ||
          episode.lastPositionMs > 0;
    }).toList();
    watched.sort((a, b) {
      final aTime = a.lastWatchedAt ?? (a.lastPositionMs > 0 ? a.timestamp : 0);
      final bTime = b.lastWatchedAt ?? (b.lastPositionMs > 0 ? b.timestamp : 0);
      return bTime.compareTo(aTime);
    });
    return watched;
  }

  int get lastActivityTimestamp {
    final watched = _watchedEpisodes;
    if (watched.isNotEmpty) {
      return watched.first.lastWatchedAt ?? (watched.first.lastPositionMs > 0 ? watched.first.timestamp : 0);
    }
    return episodes.fold<int>(
      0,
      (latest, episode) => episode.timestamp > latest
          ? episode.timestamp
          : latest,
    );
  }

  /// Tập người dùng thực sự tương tác gần nhất. Các tập chỉ được dịch gối đầu
  /// không được phép lấn át tập đang xem dở.
  HistoryItem get latestWatchedEpisode {
    if (episodes.isEmpty) {
      throw StateError('Danh sách tập rỗng');
    }

    final watchedEpisodes = _watchedEpisodes;
    if (watchedEpisodes.isNotEmpty) {
      final lastWatched = watchedEpisodes.first;
      final isFinished = lastWatched.durationMs > 0
          ? lastWatched.lastPositionMs >= lastWatched.durationMs * 0.95
          : false;
      if (isFinished) {
        final nextEpIndex = lastWatched.extractedEpisodeIndex + 1;
        final nextEp = episodes.where((e) => e.extractedEpisodeIndex == nextEpIndex).firstOrNull;
        if (nextEp != null) {
          return nextEp;
        }
      }
      return lastWatched;
    }

    // Fallback: Nếu chưa có tập nào được xem thực tế, chọn tập nhỏ nhất.
    final sortedByEpisode = List<HistoryItem>.from(episodes)
      ..sort((a, b) => a.extractedEpisodeIndex.compareTo(b.extractedEpisodeIndex));
    return sortedByEpisode.first;
  }

  /// Tập có số thứ tự lớn nhất trong danh sách đã lưu
  int get maxEpisodeIndex {
    int maxIdx = 1;
    for (final ep in episodes) {
      final idx = ep.extractedEpisodeIndex;
      if (idx > maxIdx) maxIdx = idx;
    }
    return maxIdx;
  }
}

/// Phần tử hiển thị trên danh sách Lịch Sử (có thể là Nhóm Phim Bộ hoặc Video Đơn Lẻ)
class HistoryDisplayItem {
  final bool isDramaGroup;
  final DramaHistoryGroup? dramaGroup;
  final HistoryItem? singleItem;
  final int sortTimestamp;

  HistoryDisplayItem.drama(this.dramaGroup)
      : isDramaGroup = true,
        singleItem = null,
        sortTimestamp = dramaGroup!.lastActivityTimestamp;

  HistoryDisplayItem.single(this.singleItem)
      : isDramaGroup = false,
        dramaGroup = null,
        sortTimestamp = singleItem!.timestamp;
}

class HistoryScreen extends StatefulWidget {
  final void Function(String videoPath, SubtitleDocument doc, [String? title])? onOpenInTts;

  const HistoryScreen({super.key, this.onOpenInTts});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen>
    with SingleTickerProviderStateMixin {
  HistoryRepository? _historyRepo;
  final HongguoResolver _hongguoResolver = HongguoResolver();
  late TabController _historyTabController;
  String _watchLaterFilter = 'all';

  // Quản lý trạng thái hiển thị tiêu đề đã dịch tiếng Việt
  final Set<String> _showTranslatedItemIds = {};
  final Set<String> _translatingItemIds = {};
  final Set<String> _showTranslatedGroupKeys = {};
  final Set<String> _translatingGroupKeys = {};
  final Map<String, String> _groupTranslatedTitles = {};
  final Map<String, bool> _offlineAvailability = {};
  final Set<String> _probingOfflineIds = {};

  bool _isRemoteVideoPath(String path) =>
      path.startsWith('http://') || path.startsWith('https://');

  bool _isItemOffline(HistoryItem it) {
    final path = it.videoPath.trim();
    if (path.isNotEmpty) {
      if (MediaStorage.isContentUri(path)) return true;
      if (!_isRemoteVideoPath(path)) {
        if (File(path).existsSync()) return true;
      }
    }
    final cached = _offlineAvailability[it.id];
    if (cached != null) return cached;
    _probeOfflineAvailability(it);
    return false;
  }

  void _probeOfflineAvailability(HistoryItem it) {
    if (_probingOfflineIds.contains(it.id)) return;
    _probingOfflineIds.add(it.id);
    unawaited(_resolveOfflineAvailability(it));
  }

  Future<void> _resolveOfflineAvailability(HistoryItem it) async {
    final available = await _probeHistoryOfflineExists(it);
    _probingOfflineIds.remove(it.id);

    if (!mounted) return;
    final prev = _offlineAvailability[it.id];
    _offlineAvailability[it.id] = available;
    if (prev != available && available) {
      setState(() {});
    }
  }

  void _onHistoryNotifierChanged() {
    _offlineAvailability.clear();
    _probingOfflineIds.clear();
  }

  Future<void> _toggleTranslateTitle(HistoryItem it) async {
    final isShowing = _showTranslatedItemIds.contains(it.id);
    if (isShowing) {
      setState(() {
        _showTranslatedItemIds.remove(it.id);
      });
      return;
    }

    if (it.displayTranslatedTitle != null && it.displayTranslatedTitle!.isNotEmpty) {
      setState(() {
        _showTranslatedItemIds.add(it.id);
      });
      return;
    }

    setState(() {
      _translatingItemIds.add(it.id);
    });

    try {
      final translated = await TitleTranslator.translateTitle(it.displayOriginalTitle);
      if (translated != null && translated.isNotEmpty) {
        final repo = _historyRepo ?? await HistoryRepository.getInstance();
        await repo.updateTranslatedTitle(it.id, translated);
        if (mounted) {
          setState(() {
            _showTranslatedItemIds.add(it.id);
          });
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Không thể dịch tiêu đề lúc này. Vui lòng thử lại!'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _translatingItemIds.remove(it.id);
        });
      }
    }
  }

  Future<void> _toggleTranslateDramaTitle(DramaHistoryGroup group) async {
    final isShowing = _showTranslatedGroupKeys.contains(group.seriesKey);
    if (isShowing) {
      setState(() {
        _showTranslatedGroupKeys.remove(group.seriesKey);
      });
      return;
    }

    if (_groupTranslatedTitles.containsKey(group.seriesKey)) {
      setState(() {
        _showTranslatedGroupKeys.add(group.seriesKey);
      });
      return;
    }

    final firstTranslated = group.episodes
        .where((e) => e.displayTranslatedTitle != null && e.displayTranslatedTitle!.isNotEmpty)
        .firstOrNull;
    if (firstTranslated != null && firstTranslated.displayTranslatedTitle != null) {
      final match = RegExp(r'^(.*?)\s*-\s*(Tập|P)\s*\d+', caseSensitive: false)
          .firstMatch(firstTranslated.displayTranslatedTitle!);
      final clean = match != null ? match.group(1)!.trim() : firstTranslated.displayTranslatedTitle!;
      _groupTranslatedTitles[group.seriesKey] = clean;
      setState(() {
        _showTranslatedGroupKeys.add(group.seriesKey);
      });
      return;
    }

    setState(() {
      _translatingGroupKeys.add(group.seriesKey);
    });

    try {
      final translated = await TitleTranslator.translateTitle(group.seriesTitle);
      if (translated != null && translated.isNotEmpty) {
        _groupTranslatedTitles[group.seriesKey] = translated;
        if (mounted) {
          setState(() {
            _showTranslatedGroupKeys.add(group.seriesKey);
          });
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Không thể dịch tiêu đề lúc này. Vui lòng thử lại!'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _translatingGroupKeys.remove(group.seriesKey);
        });
      }
    }
  }

  // Quản lý chế độ đa chọn để xóa nhiều phim/video cùng lúc
  bool _isMultiSelectMode = false;
  final Set<String> _selectedItemKeys = {};

  String _getDisplayItemKey(HistoryDisplayItem item) {
    if (item.isDramaGroup) {
      return 'drama_${item.dramaGroup!.seriesKey}';
    } else {
      return 'single_${item.singleItem!.id}';
    }
  }

  void _enterMultiSelectMode([String? initialKey]) {
    HapticFeedback.mediumImpact();
    setState(() {
      _isMultiSelectMode = true;
      _selectedItemKeys.clear();
      if (initialKey != null) {
        _selectedItemKeys.add(initialKey);
      }
    });
  }

  void _exitMultiSelectMode() {
    setState(() {
      _isMultiSelectMode = false;
      _selectedItemKeys.clear();
    });
  }

  void _toggleItemSelection(String key) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_selectedItemKeys.contains(key)) {
        _selectedItemKeys.remove(key);
      } else {
        _selectedItemKeys.add(key);
        _isMultiSelectMode = true;
      }
    });
  }

  void _toggleSelectAll(List<HistoryDisplayItem> items) {
    HapticFeedback.selectionClick();
    setState(() {
      final allKeys = items.map(_getDisplayItemKey).toSet();
      if (allKeys.isNotEmpty && _selectedItemKeys.containsAll(allKeys)) {
        _selectedItemKeys.clear();
      } else {
        _selectedItemKeys.addAll(allKeys);
      }
    });
  }

  Future<void> _confirmDeleteSelected(List<HistoryDisplayItem> items) async {
    if (_selectedItemKeys.isEmpty) return;

    final selectedDisplayItems = items
        .where((it) => _selectedItemKeys.contains(_getDisplayItemKey(it)))
        .toList();
    final List<String> idsToDelete = [];
    int totalCount = 0;

    for (final dItem in selectedDisplayItems) {
      if (dItem.isDramaGroup) {
        final group = dItem.dramaGroup!;
        idsToDelete.addAll(group.episodes.map((e) => e.id));
        totalCount += group.episodes.length;
      } else {
        idsToDelete.add(dItem.singleItem!.id);
        totalCount += 1;
      }
    }

    final palette = AppThemePalette.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: palette.surface,
        title: Text('Xóa các mục đã chọn', style: TextStyle(color: palette.textPrimary)),
        content: Text(
          'Bạn có chắc chắn muốn xóa ${_selectedItemKeys.length} mục đã chọn (tổng cộng $totalCount tập phim / video) không?\n\nToàn bộ dữ liệu phụ đề và video offline tương ứng sẽ được dọn dẹp khỏi máy.',
          style: TextStyle(color: palette.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Hủy', style: TextStyle(color: palette.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Xóa ($totalCount)', style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final repo = _historyRepo ?? await HistoryRepository.getInstance();
      final count = _selectedItemKeys.length;
      _exitMultiSelectMode();
      await repo.deleteItems(idsToDelete);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Đã xóa $count mục ($totalCount tập / video) khỏi lịch sử')),
        );
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _historyTabController = TabController(length: 4, vsync: this);
    _historyTabController.addListener(() {
      if (_isMultiSelectMode) {
        _exitMultiSelectMode();
      } else if (mounted) {
        setState(() {});
      }
    });
    HistoryRepository.historyNotifier.addListener(_onHistoryNotifierChanged);
    _load();
  }

  @override
  void dispose() {
    HistoryRepository.historyNotifier.removeListener(_onHistoryNotifierChanged);
    _historyTabController.dispose();
    super.dispose();
  }

  bool _isHongguoItem(HistoryItem it) {
    // Nếu có dấu hiệu là video Bilibili thì không bao giờ gom vào Hồng Quả
    if (BilibiliResolver.isBilibiliUrl(it.videoPath) ||
        it.videoPath.toLowerCase().contains('bilibili') ||
        it.id.toLowerCase().contains('bili_') ||
        RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false).hasMatch(it.videoPath) ||
        RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false).hasMatch(it.id)) {
      return false;
    }
    if (it.isSeriesEpisode || (it.seriesId != null && it.seriesId!.isNotEmpty)) return true;
    final vp = it.videoPath.toLowerCase();
    final id = it.id.toLowerCase();
    return vp.contains('hongguo') ||
        vp.contains('pull-hls') ||
        vp.startsWith('hg_') ||
        id.startsWith('hg_');
  }

  bool _isBilibiliItem(HistoryItem it) {
    if (_isHongguoItem(it)) return false;
    if (BilibiliResolver.isBilibiliUrl(it.videoPath)) return true;
    final vp = it.videoPath.toLowerCase();
    final id = it.id.toLowerCase();
    return vp.contains('bilibili') ||
        vp.contains('bili_') ||
        id.contains('bili_') ||
        RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false).hasMatch(vp) ||
        RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false).hasMatch(it.title);
  }

  List<HistoryItem> _filterItemsForTab(List<HistoryItem> allItems, int tabIndex) {
    if (tabIndex == 0) {
      return allItems.where(_isHongguoItem).toList();
    } else if (tabIndex == 1) {
      return allItems.where(_isBilibiliItem).toList();
    } else if (tabIndex == 2) {
      return const [];
    } else {
      return allItems.where((it) => !_isHongguoItem(it) && !_isBilibiliItem(it)).toList();
    }
  }

  Future<void> _confirmClearTab(int tabIndex, List<HistoryItem> itemsInTab) async {
    if (tabIndex == 2) {
      await _confirmClearWatchLater();
      return;
    }
    final tabName = tabIndex == 0
        ? 'Phim Hồng Quả'
        : (tabIndex == 1 ? 'Bilibili' : 'Video máy & Link ngoài');
    final palette = AppThemePalette.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: palette.surface,
        title: Text(
          'Xóa lịch sử $tabName',
          style: TextStyle(color: palette.textPrimary),
        ),
        content: Text(
          'Thao tác này sẽ xóa ${itemsInTab.length} mục trong danh mục $tabName. Bạn có chắc chắn không?',
          style: TextStyle(color: palette.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Hủy', style: TextStyle(color: palette.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xóa', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final repo = _historyRepo ?? await HistoryRepository.getInstance();
      await repo.deleteItems(itemsInTab.map((it) => it.id));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Đã xóa ${itemsInTab.length} mục trong $tabName')),
        );
      }
    }
  }

  static Map<String, String>? _imageHeaders(String? url) {
    if (url == null) return null;
    final lower = url.toLowerCase();
    if (lower.contains('bilibili') ||
        lower.contains('hdslb.com') ||
        lower.contains('bilivideo')) {
      return const {
        'Referer': 'https://www.bilibili.com/',
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
      };
    }
    return null;
  }

  bool _isBackfillingCovers = false;

  Future<void> _backfillBilibiliCovers(HistoryRepository repo) async {
    if (_isBackfillingCovers) return;
    _isBackfillingCovers = true;
    try {
      final items = repo.getHistory();
      final itemsNeedingCover = items.where((it) {
        if (it.seriesCover != null && it.seriesCover!.trim().isNotEmpty) return false;
        final hasBv = RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false).hasMatch(it.videoPath) ||
            RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false).hasMatch(it.title);
        return hasBv || BilibiliResolver.isBilibiliUrl(it.videoPath);
      }).toList();

      if (itemsNeedingCover.isEmpty) return;

      final resolver = BilibiliResolver();
      final settings = await SettingsRepository.getInstance();

      for (final it in itemsNeedingCover) {
        try {
          final bvMatch = RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false).firstMatch(it.videoPath) ??
              RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false).firstMatch(it.title);
          final targetUrl = bvMatch != null
              ? 'https://www.bilibili.com/video/${bvMatch.group(0)}'
              : (it.videoPath.startsWith('http') ? it.videoPath : null);

          if (targetUrl == null) continue;

          final target = await resolver.resolveUrl(targetUrl);
          final details = await resolver.getVideoDetails(target, settings.bilibiliSessData);
          if (details.coverUrl != null && details.coverUrl!.isNotEmpty) {
            await repo.updateCoverForVideo(it.videoPath, details.coverUrl!);
            await repo.updateCoverForVideo(it.id, details.coverUrl!);
          }
        } catch (_) {
          // Bỏ qua nếu lỗi mạng
        }
      }
    } catch (_) {
    } finally {
      _isBackfillingCovers = false;
    }
  }

  Future<void> _load() async {
    final repo = await HistoryRepository.getInstance();
    if (mounted) {
      setState(() {
        _historyRepo = repo;
      });
    }
    _backfillBilibiliCovers(repo);
  }

  /// Gom nhóm các tập phim bộ lại thành 1 thẻ, giữ nguyên các video đơn lẻ
  List<HistoryDisplayItem> _groupHistoryItems(List<HistoryItem> items) {
    final Map<String, List<HistoryItem>> dramaMap = {};
    final List<HistoryItem> singleItems = [];

    for (final it in items) {
      if (it.isSeriesEpisode) {
        final normTitle = it.extractedSeriesTitle.toLowerCase().trim();
        final matchedSeriesId = items
            .where((o) =>
                o.isSeriesEpisode &&
                o.seriesId != null &&
                o.seriesId!.isNotEmpty &&
                o.extractedSeriesTitle.toLowerCase().trim() == normTitle)
            .firstOrNull
            ?.seriesId;
        final key = (it.seriesId != null && it.seriesId!.isNotEmpty)
            ? it.seriesId!
            : (matchedSeriesId ?? normTitle);
        dramaMap.putIfAbsent(key, () => []).add(it);
      } else {
        singleItems.add(it);
      }
    }

    final List<HistoryDisplayItem> displayList = [];

    dramaMap.forEach((key, epList) {
      epList.sort(
        (a, b) => a.extractedEpisodeIndex.compareTo(b.extractedEpisodeIndex),
      );
      final first = epList.first;
      String? seriesId = first.seriesId;
      String? seriesCover = first.seriesCover;
      int totalEp = first.totalEpisodes ?? 0;

      for (final e in epList) {
        if ((seriesId == null || seriesId.isEmpty) &&
            e.seriesId != null &&
            e.seriesId!.isNotEmpty) {
          seriesId = e.seriesId;
        }
        if ((seriesCover == null || seriesCover.isEmpty) &&
            e.seriesCover != null &&
            e.seriesCover!.isNotEmpty) {
          seriesCover = e.seriesCover;
        }
        if (e.totalEpisodes != null && e.totalEpisodes! > totalEp) {
          totalEp = e.totalEpisodes!;
        }
      }

      final group = DramaHistoryGroup(
        seriesKey: key,
        seriesId: seriesId,
        seriesTitle: first.extractedSeriesTitle,
        seriesCover: seriesCover,
        totalEpisodes: totalEp,
        episodes: epList,
      );

      displayList.add(HistoryDisplayItem.drama(group));
    });

    for (final single in singleItems) {
      displayList.add(HistoryDisplayItem.single(single));
    }

    displayList.sort((a, b) => b.sortTimestamp.compareTo(a.sortTimestamp));
    return displayList;
  }

  /// Mở video đơn lẻ thông thường (Bilibili hoặc video ngoài)
  Future<void> _openItem(HistoryItem item) async {
    final repo = _historyRepo ?? await HistoryRepository.getInstance();
    final doc = await repo.loadSubtitleDocument(item);
    final effectiveDoc = doc ?? SubtitleDocument();

    var resolvedVideo = await HistoryRepository.resolveItemVideoPath(item);

    // Nếu là video Bilibili trực tuyến và không phải file đã tải về máy:
    // Đảm bảo đưa về URL chuẩn dạng https://www.bilibili.com/video/BV...
    // để VideoPlayerScreen nạp stream mới nhất (tránh URL CDN bilivideo cũ bị hết hạn 403)
    final isBilibili = _isBilibiliItem(item);
    final isLocal = !resolvedVideo.startsWith('http://') && !resolvedVideo.startsWith('https://');
    if (isBilibili && !isLocal) {
      final bvMatch = RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false).firstMatch(item.videoPath) ??
          RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false).firstMatch(item.id) ??
          RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false).firstMatch(item.title);
      if (bvMatch != null) {
        resolvedVideo = 'https://www.bilibili.com/video/${bvMatch.group(0)}';
      }
    }

    await repo.markWatched(item.id);

    // Nếu đã xem hết video (>95%) thì xem lại từ đầu, ngược lại xem tiếp đoạn dở
    final isFinished = item.durationMs > 0 && item.lastPositionMs >= item.durationMs * 0.95;
    final resumePosition = isFinished ? 0 : item.lastPositionMs;

    if (mounted) {
      GlobalPlayerManager.instance.openPlayer(
        videoPath: resolvedVideo,
        document: effectiveDoc,
        title: item.title,
        coverUrl: item.coverUrl,
        initialPositionMs: resumePosition,
        onPlaybackPositionChanged: (positionMs) =>
            repo.updatePlaybackPosition(item.id, positionMs),
      );
    }
  }

  /// Mở một tập phim trong bộ phim:
  /// Khởi tạo và nạp HongguoDramaDetail để VideoPlayerScreen tự động kích hoạt
  /// prefetch manager chạy ngầm dịch tập kế tiếp ngay lập tức!
  Future<void> _openSeriesEpisode(
    HistoryItem item,
    DramaHistoryGroup group, {
    int? customEpisodeIndex,
  }) async {
    final repo = _historyRepo ?? await HistoryRepository.getInstance();
    final doc = await repo.loadSubtitleDocument(item);
    final resolvedVideo = await HistoryRepository.resolveItemVideoPath(item);
    final epIndex = customEpisodeIndex ?? item.extractedEpisodeIndex;

    // Đánh dấu tập này đang được người dùng mở xem thực tế
    await repo.markWatched(item.id);

    HongguoDramaDetail? dramaDetail;
    if (group.seriesId != null && group.seriesId!.isNotEmpty) {
      try {
        dramaDetail = await _hongguoResolver.getDramaDetail(group.seriesId!);
      } catch (_) {
        dramaDetail = HongguoDramaDetail(
          seriesId: group.seriesId!,
          title: group.seriesTitle,
          cover: group.seriesCover ?? '',
          intro: '',
          totalEpisodes: group.totalEpisodes > 0 ? group.totalEpisodes : 100,
          episodes: [],
        );
      }
    } else {
      try {
        final searchResults = await _hongguoResolver.search(group.seriesTitle);
        if (searchResults.isNotEmpty) {
          final matched = searchResults.firstWhere(
            (d) =>
                d.title.trim().toLowerCase() ==
                group.seriesTitle.trim().toLowerCase(),
            orElse: () => searchResults.first,
          );
          dramaDetail = await _hongguoResolver.getDramaDetail(matched.seriesId);
        }
      } catch (_) {}

      dramaDetail ??= HongguoDramaDetail(
        seriesId: '',
        title: group.seriesTitle,
        cover: group.seriesCover ?? '',
        intro: '',
        totalEpisodes: group.totalEpisodes > 0 ? group.totalEpisodes : 100,
        episodes: [],
      );
    }

    if (dramaDetail.episodes.isEmpty && group.episodes.isNotEmpty) {
      final fallbackEpisodes = group.episodes.map((e) {
        return HongguoEpisodeItem(
          index: e.extractedEpisodeIndex,
          vid: e.seriesId ?? '',
          title: e.title,
          isAccessible: true,
        );
      }).toList();
      fallbackEpisodes.sort((a, b) => a.index.compareTo(b.index));
      dramaDetail = HongguoDramaDetail(
        seriesId: dramaDetail.seriesId.isNotEmpty ? dramaDetail.seriesId : (group.seriesId ?? ''),
        title: dramaDetail.title.isNotEmpty ? dramaDetail.title : group.seriesTitle,
        cover: dramaDetail.cover.isNotEmpty ? dramaDetail.cover : (group.seriesCover ?? ''),
        intro: dramaDetail.intro,
        totalEpisodes: dramaDetail.totalEpisodes > 0
            ? dramaDetail.totalEpisodes
            : (group.totalEpisodes > 0 ? group.totalEpisodes : fallbackEpisodes.length),
        episodes: fallbackEpisodes,
      );
    }

    // Xử lý vị trí phát tiếp tục:
    // Nếu tập đã xem xong (>95% thời lượng hoặc còn dưới 1.5 giây), phát lại từ đầu (0ms)
    // Tránh tình trạng nạp ở cuối video rồi lập tức tự động chuyển sang tập khác!
    final isFinished = (item.durationMs > 0 && item.lastPositionMs >= item.durationMs * 0.95) ||
        (item.durationMs > 2000 && item.lastPositionMs >= item.durationMs - 1500);
    final resumePosition = isFinished ? 0 : item.lastPositionMs;

    GlobalPlayerManager.instance.openPlayer(
      videoPath: resolvedVideo,
      title: '${group.seriesTitle} - Tập $epIndex',
      document: doc ?? SubtitleDocument(),
      coverUrl: group.seriesCover ?? item.coverUrl,
      initialPositionMs: resumePosition,
      dramaDetail: dramaDetail,
      currentEpisodeIndex: epIndex,
      onPlaybackPositionChanged: (positionMs) =>
          repo.updatePlaybackPosition(item.id, positionMs),
    );
  }

  /// Mở một tập chưa từng xem trong bộ phim từ bảng chọn tập
  Future<void> _openUnwatchedDramaEpisode(
    int epIndex,
    DramaHistoryGroup group,
    HongguoDramaDetail detail,
  ) async {
    final accent = AppThemePalette.of(context).accentFor(AppTabId.history);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Center(
        child: CircularProgressIndicator(color: accent),
      ),
    );

    try {
      var vid = '';
      final matchedEp = detail.episodes.where((e) => e.index == epIndex).firstOrNull;
      if (matchedEp != null && matchedEp.vid.isNotEmpty) {
        vid = matchedEp.vid;
      } else if (detail.episodes.isNotEmpty && epIndex > 0 && epIndex <= detail.episodes.length) {
        vid = detail.episodes[epIndex - 1].vid;
      }
      final playUrl = await _hongguoResolver.getEpisodePlayUrl(
        detail.seriesId,
        vid.isNotEmpty ? vid : detail.seriesId,
        episodeIndex: epIndex,
      );

      if (!mounted) return;
      Navigator.pop(context); // Đóng loading

      GlobalPlayerManager.instance.openPlayer(
        videoPath: playUrl,
        title: '${detail.title} - Tập $epIndex',
        document: SubtitleDocument(),
        dramaDetail: detail,
        currentEpisodeIndex: epIndex,
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi tải video Tập $epIndex: $e')),
      );
    }
  }

  /// Điều hướng sang Trang Lướt Hồng Quả (Shorts / Feed) và tự tua đến vị trí đang xem dở
  Future<void> _openHongguoFeed({
    required String seriesTitle,
    String? seriesId,
    String? seriesCover,
    int? totalEpisodes,
    int episodeIndex = 1,
    int initialPositionMs = 0,
    HongguoDramaDetail? existingDetail,
  }) async {
    HongguoDramaDetail? dramaDetail = existingDetail;

    if (dramaDetail == null || dramaDetail.episodes.isEmpty) {
      final accent = AppThemePalette.of(context).accentFor(AppTabId.history);
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => Center(
          child: CircularProgressIndicator(color: accent),
        ),
      );

      try {
        if (seriesId != null && seriesId.isNotEmpty) {
          try {
            dramaDetail = await _hongguoResolver.getDramaDetail(seriesId);
          } catch (_) {}
        }

        if (dramaDetail == null || dramaDetail.episodes.isEmpty) {
          try {
            final searchResults = await _hongguoResolver.search(seriesTitle);
            if (searchResults.isNotEmpty) {
              final matched = searchResults.firstWhere(
                (d) =>
                    d.title.trim().toLowerCase() ==
                    seriesTitle.trim().toLowerCase(),
                orElse: () => searchResults.first,
              );
              dramaDetail = await _hongguoResolver.getDramaDetail(matched.seriesId);
            }
          } catch (_) {}
        }
      } finally {
        if (mounted) {
          Navigator.of(context, rootNavigator: true).pop();
        }
      }
    }

    dramaDetail ??= HongguoDramaDetail(
      seriesId: seriesId ?? '',
      title: seriesTitle,
      cover: seriesCover ?? '',
      intro: '',
      totalEpisodes:
          totalEpisodes != null && totalEpisodes > 0 ? totalEpisodes : 100,
      episodes: [],
    );

    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HongguoFeedScreen(
          initialDrama: dramaDetail,
          initialEpisodeIndex: episodeIndex,
          initialPositionMs: initialPositionMs,
        ),
      ),
    );

    // Khi người dùng bấm Back từ trang lướt về, cập nhật lại lịch sử
    if (mounted) {
      final repo = await HistoryRepository.getInstance();
      HistoryRepository.historyNotifier.value = repo.getHistory();
      setState(() {});
    }
  }

  /// Hiển thị Modal Bottom Sheet chọn chế độ xem phim Hồng Quả:
  /// Chế độ 1: Lướt Shorts Online (HongguoFeedScreen)
  /// Chế độ 2: Trình phát đầy đủ Player (VideoPlayerScreen)
  void _showHongguoPlaybackOptions({
    required DramaHistoryGroup group,
    HistoryItem? episodeItem,
    int? targetEpisodeIndex,
    HongguoDramaDetail? dramaDetail,
    WatchLaterItem? watchLaterItem,
  }) {
    final latest = group.latestWatchedEpisode;
    final targetItem = episodeItem ?? (group.episodes.isNotEmpty ? latest : null);
    final epNum = targetEpisodeIndex ?? (targetItem?.extractedEpisodeIndex ?? 1);
    final resumePosition = (targetItem != null &&
            targetItem.durationMs > 0 &&
            targetItem.lastPositionMs >= targetItem.durationMs * 0.95)
        ? 0
        : (targetItem?.lastPositionMs ?? 0);
    final isOnlineStream = targetItem?.isOnlineStream ?? false;
    final hasWatchingProgress = resumePosition > 0;

    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.history);
    final secondary = palette.secondaryFor(AppTabId.history);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        return Container(
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: palette.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: (group.seriesCover != null && group.seriesCover!.isNotEmpty)
                          ? Image.network(
                              group.seriesCover!,
                              headers: _imageHeaders(group.seriesCover),
                              cacheWidth: 120,
                              width: 44,
                              height: 58,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Container(
                                width: 44,
                                height: 58,
                                color: palette.surfaceAlt,
                                child: Icon(Icons.movie_rounded, color: palette.textMuted, size: 24),
                              ),
                            )
                          : Container(
                              width: 44,
                              height: 58,
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                Icons.movie_filter_rounded,
                                color: accent,
                                size: 24,
                              ),
                            ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            group.seriesTitle,
                            style: TextStyle(
                              color: palette.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: accent.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  'Tập $epNum',
                                  style: TextStyle(
                                    color: accent,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              if (hasWatchingProgress)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: secondary.withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    targetItem?.durationMs != null && targetItem!.durationMs > 0
                                        ? 'Đang xem: ${_formatMs(resumePosition)} / ${_formatMs(targetItem.durationMs)}'
                                        : 'Đang xem: ${_formatMs(resumePosition)}',
                                    style: TextStyle(
                                      color: secondary,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close_rounded, color: palette.textSecondary, size: 22),
                      onPressed: () => Navigator.pop(sheetContext),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  'CHỌN CHẾ ĐỘ XEM TIẾP',
                  style: TextStyle(
                    color: palette.textMuted,
                    fontSize: 11.5,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 12),

                // 1. Lướt Shorts Online
                InkWell(
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _openHongguoFeed(
                      seriesTitle: group.seriesTitle,
                      seriesId: group.seriesId,
                      seriesCover: group.seriesCover,
                      totalEpisodes: group.totalEpisodes,
                      episodeIndex: epNum,
                      initialPositionMs: resumePosition,
                      existingDetail: dramaDetail,
                    );
                  },
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: isOnlineStream
                          ? accent.withValues(alpha: 0.1)
                          : palette.surfaceAlt,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isOnlineStream
                            ? accent.withValues(alpha: 0.5)
                            : palette.border,
                        width: isOnlineStream ? 1.5 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.swipe_vertical_rounded,
                            color: accent,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    'Lướt Shorts Online',
                                    style: TextStyle(
                                      color: palette.textPrimary,
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  if (isOnlineStream) ...[
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                      decoration: BoxDecoration(
                                        color: accent.withValues(alpha: 0.16),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: accent.withValues(alpha: 0.5),
                                          width: 0.8,
                                        ),
                                      ),
                                      child: Text(
                                        'Lần trước',
                                        style: TextStyle(
                                          color: accent,
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'Vuốt dọc chuyển tập siêu mượt, tự động nhận phụ đề Vietsub và lồng tiếng AI',
                                style: TextStyle(
                                  color: palette.textSecondary,
                                  fontSize: 12,
                                  height: 1.25,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.arrow_forward_ios_rounded, color: palette.textMuted, size: 14),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),

                // 2. Trình phát đầy đủ (Player)
                InkWell(
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (targetItem != null) {
                      _openSeriesEpisode(
                        targetItem,
                        group,
                        customEpisodeIndex: epNum,
                      );
                    } else if (dramaDetail != null) {
                      _openUnwatchedDramaEpisode(epNum, group, dramaDetail);
                    } else if (watchLaterItem != null) {
                      _openWatchLaterHongguo(watchLaterItem, targetEpisodeIndex: epNum);
                    } else {
                      _openSeriesEpisode(
                        latest,
                        group,
                        customEpisodeIndex: epNum,
                      );
                    }
                  },
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: !isOnlineStream
                          ? secondary.withValues(alpha: 0.1)
                          : palette.surfaceAlt,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: !isOnlineStream
                            ? secondary.withValues(alpha: 0.5)
                            : palette.border,
                        width: !isOnlineStream ? 1.5 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: secondary.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.play_circle_fill_rounded,
                            color: secondary,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    'Trình phát đầy đủ (Player)',
                                    style: TextStyle(
                                      color: palette.textPrimary,
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  if (!isOnlineStream && hasWatchingProgress) ...[
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                      decoration: BoxDecoration(
                                        color: secondary.withValues(alpha: 0.16),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: secondary.withValues(alpha: 0.5),
                                          width: 0.8,
                                        ),
                                      ),
                                      child: Text(
                                        'Offline',
                                        style: TextStyle(
                                          color: secondary,
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'Xem video offline / cache, có thanh tua tiến độ, gối đầu tập tiếp theo',
                                style: TextStyle(
                                  color: palette.textSecondary,
                                  fontSize: 12,
                                  height: 1.25,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.arrow_forward_ios_rounded, color: palette.textMuted, size: 14),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openInTts(HistoryItem item) async {
    if (widget.onOpenInTts == null) return;
    final repo = _historyRepo ?? await HistoryRepository.getInstance();
    final doc = await repo.loadSubtitleDocument(item);
    if (doc == null || doc.items.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Không tìm thấy tệp phụ đề để lồng tiếng'),
          ),
        );
      }
      return;
    }

    final resolvedVideo = await HistoryRepository.resolvePath(item.videoPath);
    widget.onOpenInTts!(resolvedVideo, doc, item.title);
  }

  Future<void> _exportSrt(HistoryItem item) async {
    final resolvedSrt = await HistoryRepository.resolvePath(item.srtPath);
    final srtFile = File(resolvedSrt);
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
      await Share.shareXFiles([
        XFile(srtFile.path),
      ], subject: 'Phụ đề: ${item.title}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Lỗi chia sẻ file: $e')));
      }
    }
  }

  Future<void> _confirmDelete(HistoryItem item) async {
    final palette = AppThemePalette.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: palette.surface,
        title: Text('Xóa lịch sử', style: TextStyle(color: palette.textPrimary)),
        content: Text(
          'Bạn có chắc chắn muốn xóa bản ghi "${item.title}" không?',
          style: TextStyle(color: palette.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Hủy', style: TextStyle(color: palette.textMuted)),
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

  /// Xóa toàn bộ các tập của một bộ phim
  Future<void> _confirmDeleteDramaGroup(DramaHistoryGroup group) async {
    final palette = AppThemePalette.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: palette.surface,
        title: Text(
          'Xóa toàn bộ phim',
          style: TextStyle(color: palette.textPrimary),
        ),
        content: Text(
          'Bạn có chắc chắn muốn xóa tất cả ${group.episodes.length} tập của phim "${group.seriesTitle}" không?',
          style: TextStyle(color: palette.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Hủy', style: TextStyle(color: palette.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Xóa tất cả tập',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final ids = group.episodes.map((ep) => ep.id).toList();
      await _historyRepo?.deleteItems(ids);
    }
  }

  void _showImportSubtitleDialog() {
    showDialog(
      context: context,
      builder: (ctx) => ImportSubtitleDialog(
        onSuccessPlay: (videoPath, doc) {
          GlobalPlayerManager.instance.openPlayer(
            videoPath: videoPath,
            document: doc,
          );
        },
      ),
    );
  }

  String _formatMs(int ms) {
    if (ms <= 0) return '00:00';
    final d = Duration(milliseconds: ms);
    final min = d.inMinutes;
    final sec = d.inSeconds % 60;
    return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  /// Hiển thị Modal Bottom Sheet chi tiết danh sách các tập của bộ phim (hỗ trợ chọn nhiều tập để xóa)
  void _showDramaEpisodesSheet(DramaHistoryGroup group) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _DramaEpisodesSheetWidget(
        group: group,
        hongguoResolver: _hongguoResolver,
        onOpenEpisode: (ep, g, {customEpisodeIndex}) {
          Navigator.pop(ctx);
          _showHongguoPlaybackOptions(
            group: g,
            episodeItem: ep,
            targetEpisodeIndex: customEpisodeIndex ?? ep.extractedEpisodeIndex,
          );
        },
        onOpenUnwatchedEpisode: (epIndex, g, detail) {
          Navigator.pop(ctx);
          _showHongguoPlaybackOptions(
            group: g,
            targetEpisodeIndex: epIndex,
            dramaDetail: detail,
          );
        },
        onOpenTts: (ep) {
          Navigator.pop(ctx);
          _openInTts(ep);
        },
        onExportSrt: (ep) => _exportSrt(ep),
        onConfirmDeleteSingle: (ep) => _confirmDelete(ep),
        imageHeaders: _imageHeaders,
        formatMs: _formatMs,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dateFormatter = DateFormat('dd/MM/yyyy HH:mm');

    return ValueListenableBuilder<List<HistoryItem>>(
      valueListenable: HistoryRepository.historyNotifier,
      builder: (context, allItems, _) {
        return ValueListenableBuilder<List<WatchLaterItem>>(
          valueListenable: WatchLaterRepository.watchLaterNotifier,
          builder: (context, watchLaterItems, _) {
            final hgRaw = _filterItemsForTab(allItems, 0);
            final biliRaw = _filterItemsForTab(allItems, 1);
            final otherRaw = _filterItemsForTab(allItems, 3);

            final currentTabIndex = _historyTabController.index;
            final currentRawItems = currentTabIndex == 0
                ? hgRaw
                : (currentTabIndex == 1
                    ? biliRaw
                    : (currentTabIndex == 2 ? const <HistoryItem>[] : otherRaw));
            final currentDisplayItems = _groupHistoryItems(currentRawItems);

            final tabTitles = [
              'Phim Hồng Quả',
              'Bilibili',
              'Xem sau',
              'Video máy & Link ngoài',
            ];

        final palette = AppThemePalette.of(context);
        final accent = palette.accentFor(AppTabId.history);
        final secondary = palette.secondaryFor(AppTabId.history);
        final hgAccent = palette.accentFor(AppTabId.hongguo);
        final biliAccent = palette.accentFor(AppTabId.bilibili);
        const watchLaterAmber = Color(0xFFF59E0B);

        final activeTabColor = currentTabIndex == 0
            ? hgAccent
            : (currentTabIndex == 1
                ? biliAccent
                : (currentTabIndex == 2 ? watchLaterAmber : accent));

        final isAllSelected = currentDisplayItems.isNotEmpty &&
            _selectedItemKeys.length >= currentDisplayItems.length &&
            currentDisplayItems.every((item) => _selectedItemKeys.contains(_getDisplayItemKey(item)));

        return PopScope(
          canPop: !_isMultiSelectMode,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              _exitMultiSelectMode();
            }
          },
          child: AppTabBackdrop(
            tab: AppTabId.history,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              appBar: _isMultiSelectMode
                ? AppBar(
                    backgroundColor: palette.surface,
                    elevation: 0,
                    scrolledUnderElevation: 0,
                    bottom: PreferredSize(
                      preferredSize: const Size.fromHeight(1),
                      child: Divider(height: 1, color: palette.border),
                    ),
                    leading: IconButton(
                      icon: Icon(Icons.close_rounded, color: palette.textPrimary),
                      onPressed: _exitMultiSelectMode,
                      tooltip: 'Hủy chọn',
                    ),
                    title: Text(
                      'Đã chọn ${_selectedItemKeys.length}',
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: currentDisplayItems.isEmpty
                            ? null
                            : () => _toggleSelectAll(currentDisplayItems),
                        child: Text(
                          isAllSelected ? 'Bỏ chọn' : 'Tất cả',
                          style: TextStyle(
                            color: accent,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.delete_outline_rounded,
                          color: _selectedItemKeys.isEmpty
                              ? palette.textMuted.withValues(alpha: 0.4)
                              : Colors.redAccent,
                          size: 24,
                        ),
                        tooltip: 'Xóa mục đã chọn',
                        onPressed: _selectedItemKeys.isEmpty
                            ? null
                            : () => _confirmDeleteSelected(currentDisplayItems),
                      ),
                    ],
                  )
                : AppBar(
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    scrolledUnderElevation: 0,
                    toolbarHeight: 64,
                    title: Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [accent, secondary],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.history_rounded,
                            color: palette.onColor(accent),
                            size: 21,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Thư Viện & Lịch Sử',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.textPrimary,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                'Tự động nhớ đúng tập & giây đang xem',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.textMuted,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    actions: [
                      if (currentDisplayItems.isNotEmpty)
                        IconButton(
                          icon: Icon(Icons.checklist_rounded, color: palette.textSecondary),
                          tooltip: 'Chọn nhiều mục để xóa',
                          onPressed: () => _enterMultiSelectMode(),
                        ),
                      IconButton(
                        icon: Icon(Icons.cleaning_services_rounded, color: watchLaterAmber),
                        tooltip: 'Dọn dẹp bộ nhớ',
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (ctx) => const StorageCleanerScreen()),
                          );
                        },
                      ),
                      IconButton(
                        icon: Icon(Icons.settings_rounded, color: palette.textSecondary),
                        tooltip: 'Cài đặt hệ thống',
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
              padding: EdgeInsets.fromLTRB(
                16,
                10,
                16,
                palette.bottomContentPadding(extra: 18),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 4 Tabs Pill Selector
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: palette.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: palette.border),
                      boxShadow: palette.cardShadows,
                    ),
                    child: TabBar(
                      controller: _historyTabController,
                      dividerColor: Colors.transparent,
                      indicatorSize: TabBarIndicatorSize.tab,
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      padding: EdgeInsets.zero,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 10),
                      indicator: BoxDecoration(
                        color: activeTabColor.withValues(alpha: palette.isDark ? 0.24 : 0.14),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: activeTabColor,
                          width: 1.2,
                        ),
                      ),
                      labelColor: activeTabColor,
                      unselectedLabelColor: palette.textSecondary,
                      labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                      tabs: [
                        Tab(
                          icon: const Icon(Icons.movie_filter_rounded, size: 16),
                          text: 'Hồng Quả (${hgRaw.length})',
                        ),
                        Tab(
                          icon: const Icon(Icons.tv_rounded, size: 16),
                          text: 'Bilibili (${biliRaw.length})',
                        ),
                        Tab(
                          icon: const Icon(Icons.bookmark_rounded, size: 16),
                          text: 'Xem sau (${watchLaterItems.length})',
                        ),
                        Tab(
                          icon: const Icon(Icons.folder_open_rounded, size: 16),
                          text: 'Video & Khác (${otherRaw.length})',
                        ),
                      ],
                    ),
                  ),

                  // 1. Tab 2: Xem sau
                  if (currentTabIndex == 2)
                    _buildWatchLaterTab(context, watchLaterItems, allItems)
                  else ...[
                    // Hero "Đang xem gần nhất" Card
                    if (currentDisplayItems.isNotEmpty && !_isMultiSelectMode) ...[
                      _buildHeroResumeCard(currentDisplayItems.first, palette),
                      const SizedBox(height: 16),
                    ],

                    // Banner "Nhập Video & Phụ Đề Có Sẵn" (Hiển thị khi ở Tab Video & Khác)
                    if (currentTabIndex == 3) ...[
                    InkWell(
                      onTap: _isMultiSelectMode ? null : _showImportSubtitleDialog,
                      borderRadius: BorderRadius.circular(18),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: palette.surface,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: palette.border),
                          boxShadow: palette.cardShadows,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.14),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.input,
                                color: accent,
                                size: 24,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Nhập Video & Phụ Đề Có Sẵn',
                                    style: TextStyle(
                                      color: palette.textPrimary,
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    'Xem với phụ đề rời hoặc dịch file sub gốc bằng AI',
                                    style: TextStyle(color: palette.textSecondary, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            Icon(Icons.chevron_right, color: palette.textMuted),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Tiêu đề danh sách tab hiện tại & Nút xóa tab
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Text(
                          '${tabTitles[currentTabIndex].toUpperCase()} (${currentDisplayItems.length} MỤC)',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.textMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                      if (currentRawItems.isNotEmpty && !_isMultiSelectMode)
                        TextButton.icon(
                          onPressed: () => _confirmClearTab(currentTabIndex, currentRawItems),
                          icon: Icon(
                            Icons.delete_sweep_outlined,
                            size: 16,
                            color: palette.textMuted,
                          ),
                          label: Text(
                            'Xóa tab này',
                            style: TextStyle(color: palette.textMuted, fontSize: 12),
                          ),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Danh sách hoặc empty state
                  if (currentDisplayItems.isEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: palette.surface,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: palette.border),
                        boxShadow: palette.cardShadows,
                      ),
                      child: Column(
                        children: [
                          Icon(
                            currentTabIndex == 0
                                ? Icons.movie_filter_outlined
                                : (currentTabIndex == 1 ? Icons.tv_off_rounded : Icons.video_library_outlined),
                            color: palette.textMuted.withValues(alpha: 0.45),
                            size: 56,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            currentTabIndex == 0
                                ? 'Chưa có phim Hồng Quả nào trong lịch sử'
                                : (currentTabIndex == 1
                                    ? 'Chưa có video Bilibili nào trong lịch sử'
                                    : 'Chưa có video máy hoặc link ngoài nào'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: palette.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            currentTabIndex == 0
                                ? 'Xem phim tại tab "Phim Hồng Quả" để lưu lịch sử và tập đang xem'
                                : (currentTabIndex == 1
                                    ? 'Xem video tại tab "Bilibili" để lưu lại lịch sử xem'
                                    : 'Dùng nút Nhập Video ở trên để xem video từ máy hoặc link trực tiếp'),
                            textAlign: TextAlign.center,
                            style: TextStyle(color: palette.textSecondary, fontSize: 12),
                          ),
                        ],
                      ),
                    )
                  else
                    ListView.separated(
                      physics: const NeverScrollableScrollPhysics(),
                      shrinkWrap: true,
                      itemCount: currentDisplayItems.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final dItem = currentDisplayItems[index];
                        final key = _getDisplayItemKey(dItem);
                        final isSelected = _selectedItemKeys.contains(key);

                        if (dItem.isDramaGroup) {
                          return _buildDramaGroupCard(
                            dItem.dramaGroup!,
                            dateFormatter,
                            isSelected: isSelected,
                            isMultiSelectMode: _isMultiSelectMode,
                            onToggleSelect: () => _toggleItemSelection(key),
                            onEnterMultiSelect: () => _enterMultiSelectMode(key),
                          );
                        } else {
                          return _buildSingleItemCard(
                            dItem.singleItem!,
                            dateFormatter,
                            isSelected: isSelected,
                            isMultiSelectMode: _isMultiSelectMode,
                            onToggleSelect: () => _toggleItemSelection(key),
                            onEnterMultiSelect: () => _enterMultiSelectMode(key),
                          );
                        }
                      },
                    ),
                  ],
                ],
              ),
            ),
            ),
          ),
        );
      },
    );
  },
);
}

  Widget _buildHeroResumeCard(HistoryDisplayItem dItem, AppThemePalette palette) {
    final accent = palette.accentFor(AppTabId.history);
    final secondary = palette.secondaryFor(AppTabId.history);
    final onHero = palette.onColor(accent);

    final String title;
    final String subtitle;
    final String? coverUrl;
    final double? progress;
    final VoidCallback onPlay;

    if (dItem.isDramaGroup) {
      final group = dItem.dramaGroup!;
      final latest = group.latestWatchedEpisode;
      final latestEpNum = latest.extractedEpisodeIndex;
      final isTranslated = _showTranslatedGroupKeys.contains(group.seriesKey);
      final translated = _groupTranslatedTitles[group.seriesKey];
      title = isTranslated && translated != null && translated.isNotEmpty
          ? translated
          : group.seriesTitle;
      subtitle = latest.lastPositionMs > 0
          ? 'Tập $latestEpNum · Đã xem ${_formatMs(latest.lastPositionMs)}'
          : 'Tập $latestEpNum · Đã lưu ${group.episodes.length} tập';
      coverUrl = (group.seriesCover != null && group.seriesCover!.isNotEmpty)
          ? group.seriesCover
          : (latest.seriesCover ?? latest.coverUrl);
      progress = (latest.durationMs > 0 && latest.lastPositionMs > 0)
          ? (latest.lastPositionMs / latest.durationMs).clamp(0.0, 1.0)
          : null;
      onPlay = () => _showHongguoPlaybackOptions(
        group: group,
        episodeItem: latest,
        targetEpisodeIndex: latestEpNum,
      );
    } else {
      final it = dItem.singleItem!;
      final isTranslated = _showTranslatedItemIds.contains(it.id);
      final hasTranslated =
          it.displayTranslatedTitle != null && it.displayTranslatedTitle!.isNotEmpty;
      title = isTranslated && hasTranslated
          ? it.displayTranslatedTitle!
          : it.displayOriginalTitle;
      final isOffline = _isItemOffline(it);
      subtitle = it.lastPositionMs > 0
          ? (it.durationMs > 0
                ? '${_formatMs(it.lastPositionMs)} / ${_formatMs(it.durationMs)}'
                : _formatMs(it.lastPositionMs))
          : '${it.sentenceCount > 0 ? "Vietsub" : "Chưa vietsub"} · ${isOffline ? "Offline" : "Online"}';
      coverUrl = (it.seriesCover != null && it.seriesCover!.trim().isNotEmpty)
          ? it.seriesCover
          : it.coverUrl;
      progress = (it.durationMs > 0 && it.lastPositionMs > 0)
          ? (it.lastPositionMs / it.durationMs).clamp(0.0, 1.0)
          : null;
      onPlay = () {
        if (it.isOnlineStream || (it.seriesId != null && it.seriesId!.isNotEmpty)) {
          final dramaGroup = DramaHistoryGroup(
            seriesKey: it.seriesId ?? it.extractedSeriesTitle,
            seriesId: it.seriesId,
            seriesTitle: it.extractedSeriesTitle,
            seriesCover: it.seriesCover ?? it.coverUrl,
            totalEpisodes: it.totalEpisodes ?? 0,
            episodes: [it],
          );
          _showHongguoPlaybackOptions(
            group: dramaGroup,
            episodeItem: it,
            targetEpisodeIndex: it.extractedEpisodeIndex,
          );
        } else {
          _openItem(it);
        }
      };
    }

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [accent, secondary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.28),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPlay,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: (coverUrl != null && coverUrl.trim().isNotEmpty)
                      ? Image.network(
                          coverUrl,
                          headers: _imageHeaders(coverUrl),
                          cacheWidth: 160,
                          width: 56,
                          height: 76,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            width: 56,
                            height: 76,
                            color: onHero.withValues(alpha: 0.16),
                            child: Icon(Icons.play_circle_fill_rounded, color: onHero, size: 28),
                          ),
                        )
                      : Container(
                          width: 56,
                          height: 76,
                          color: onHero.withValues(alpha: 0.16),
                          child: Icon(Icons.play_circle_fill_rounded, color: onHero, size: 28),
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: onHero.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '▶ ĐANG XEM GẦN NHẤT',
                          style: TextStyle(
                            color: onHero,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: onHero,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: onHero.withValues(alpha: 0.86),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (progress != null) ...[
                        const SizedBox(height: 7),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 4,
                            backgroundColor: onHero.withValues(alpha: 0.22),
                            valueColor: AlwaysStoppedAnimation<Color>(onHero),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: onHero,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Xem tiếp',
                    style: TextStyle(
                      color: accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Card gom nhóm cho Phim Bộ (Hồng Quả / Short Drama)
  Widget _buildDramaGroupCard(
    DramaHistoryGroup group,
    DateFormat dateFormatter, {
    bool isSelected = false,
    bool isMultiSelectMode = false,
    VoidCallback? onToggleSelect,
    VoidCallback? onEnterMultiSelect,
  }) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.history);
    final onAccent = palette.onColor(accent);
    final amberText = palette.isDark ? AppTheme.accentGold : const Color(0xFFB45309);

    final latest = group.latestWatchedEpisode;
    final latestEpNum = latest.extractedEpisodeIndex;
    final dateStr = dateFormatter.format(
      DateTime.fromMillisecondsSinceEpoch(latest.timestamp),
    );

    return InkWell(
      onTap: isMultiSelectMode ? onToggleSelect : null,
      onLongPress: !isMultiSelectMode ? onEnterMultiSelect : null,
      borderRadius: BorderRadius.circular(18),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected
              ? accent.withValues(alpha: 0.12)
              : palette.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isSelected
                ? accent
                : (isMultiSelectMode
                    ? palette.border
                    : accent.withValues(alpha: 0.28)),
            width: isSelected ? 1.8 : 1.1,
          ),
          boxShadow: palette.cardShadows,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Hàng 1: Poster + Tiêu đề phim bộ + Nút xóa cả bộ
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isMultiSelectMode) ...[
                  Padding(
                    padding: const EdgeInsets.only(right: 10, top: 24),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSelected ? accent : Colors.transparent,
                        border: Border.all(
                          color: isSelected ? accent : palette.textMuted,
                          width: 2,
                        ),
                      ),
                      child: isSelected
                          ? Icon(Icons.check, size: 14, color: onAccent)
                          : null,
                    ),
                  ),
                ],
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: (group.seriesCover != null &&
                          group.seriesCover!.isNotEmpty)
                      ? Image.network(
                          group.seriesCover!,
                          headers: _imageHeaders(group.seriesCover),
                          cacheWidth: 150,
                          width: 52,
                          height: 70,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            width: 52,
                            height: 70,
                            color: palette.surfaceAlt,
                            child: Icon(Icons.movie, color: palette.textMuted),
                          ),
                        )
                      : Container(
                          width: 52,
                          height: 70,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.movie_filter_rounded,
                            color: accent,
                          ),
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Builder(
                        builder: (context) {
                          final isGroupTranslated = _showTranslatedGroupKeys.contains(group.seriesKey);
                          final translatedTitle = _groupTranslatedTitles[group.seriesKey];
                          final displayGroupTitle = isGroupTranslated && translatedTitle != null && translatedTitle.isNotEmpty
                              ? translatedTitle
                              : group.seriesTitle;
                          final isGroupTranslating = _translatingGroupKeys.contains(group.seriesKey);

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Tooltip(
                                      message: 'Chạm để sao chép',
                                      child: InkWell(
                                        onTap: isMultiSelectMode
                                            ? null
                                            : () {
                                                Clipboard.setData(ClipboardData(text: displayGroupTitle));
                                                ScaffoldMessenger.of(context).showSnackBar(
                                                  SnackBar(
                                                    content: Text('📋 Đã sao chép: "$displayGroupTitle"'),
                                                    duration: const Duration(seconds: 2),
                                                    behavior: SnackBarBehavior.floating,
                                                  ),
                                                );
                                              },
                                        borderRadius: BorderRadius.circular(4),
                                        child: Text(
                                          displayGroupTitle,
                                          style: TextStyle(
                                            color: palette.textPrimary,
                                            fontSize: 15,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  if (!isMultiSelectMode)
                                    InkWell(
                                      onTap: isGroupTranslating ? null : () => _toggleTranslateDramaTitle(group),
                                      borderRadius: BorderRadius.circular(8),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: isGroupTranslated
                                              ? accent.withValues(alpha: 0.14)
                                              : palette.surfaceAlt,
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(
                                            color: isGroupTranslated
                                                ? accent.withValues(alpha: 0.5)
                                                : palette.border,
                                          ),
                                        ),
                                        child: isGroupTranslating
                                            ? SizedBox(
                                                width: 10,
                                                height: 10,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: accent,
                                                ),
                                              )
                                            : Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    Icons.translate_rounded,
                                                    size: 11,
                                                    color: isGroupTranslated
                                                        ? accent
                                                        : palette.textSecondary,
                                                  ),
                                                  const SizedBox(width: 3),
                                                  Text(
                                                    isGroupTranslated ? 'Gốc' : 'Dịch',
                                                    style: TextStyle(
                                                      color: isGroupTranslated
                                                          ? accent
                                                          : palette.textSecondary,
                                                      fontSize: 10,
                                                      fontWeight: FontWeight.bold,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                      ),
                                    ),
                                ],
                              ),
                              if (isGroupTranslated && group.seriesTitle != displayGroupTitle) ...[
                                const SizedBox(height: 3),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '🇨🇳 Gốc: ${group.seriesTitle}',
                                        style: TextStyle(
                                          color: palette.textMuted,
                                          fontSize: 11,
                                          fontStyle: FontStyle.italic,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (!isMultiSelectMode)
                                      InkWell(
                                        onTap: () {
                                          Clipboard.setData(ClipboardData(text: group.seriesTitle));
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('📋 Đã sao chép: "${group.seriesTitle}"'),
                                              duration: const Duration(seconds: 2),
                                            ),
                                          );
                                        },
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                          child: Icon(Icons.copy_rounded, size: 12, color: palette.textMuted),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '🎬 Đã lưu ${group.episodes.length} tập',
                              style: TextStyle(
                                color: accent,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: palette.surfaceAlt,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'Gần nhất: Tập $latestEpNum',
                              style: TextStyle(
                                color: amberText,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        dateStr,
                        style: TextStyle(color: palette.textMuted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                if (!isMultiSelectMode)
                  InkWell(
                    onTap: () => _confirmDeleteDramaGroup(group),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.delete_outline,
                          color: palette.textMuted, size: 20),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // Hàng 2: Nút hành động chính
            IgnorePointer(
              ignoring: isMultiSelectMode,
              child: Row(
                children: [
                  // Nút Xem tiếp tập gần nhất
                  Expanded(
                    flex: 5,
                    child: ElevatedButton.icon(
                      onPressed: () => _showHongguoPlaybackOptions(
                        group: group,
                        episodeItem: latest,
                        targetEpisodeIndex: latestEpNum,
                      ),
                      icon: Icon(
                        Icons.play_arrow_rounded,
                        size: 20,
                        color: onAccent,
                      ),
                      label: Text(
                        latest.lastPositionMs > 0
                            ? 'Xem tiếp Tập $latestEpNum (${_formatMs(latest.lastPositionMs)})'
                            : 'Xem Tập $latestEpNum',
                        style: TextStyle(
                          color: onAccent,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: accent,
                        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        elevation: 0,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Nút mở danh sách các tập
                  Expanded(
                    flex: 4,
                    child: OutlinedButton.icon(
                      onPressed: () => _showDramaEpisodesSheet(group),
                      icon: Icon(
                        Icons.list_alt_rounded,
                        size: 18,
                        color: palette.textPrimary,
                      ),
                      label: Text(
                        'Tất cả tập (${group.episodes.length})',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: palette.border),
                        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
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
  }

  /// Card video đơn lẻ thông thường (Bilibili, Video máy, v.v.)
  Widget _buildSingleItemCard(
    HistoryItem it,
    DateFormat dateFormatter, {
    bool isSelected = false,
    bool isMultiSelectMode = false,
    VoidCallback? onToggleSelect,
    VoidCallback? onEnterMultiSelect,
  }) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.history);
    final onAccent = palette.onColor(accent);
    final watchingColor =
        palette.isDark ? AppTheme.accentGold : const Color(0xFFD97706);
    final onlineColor =
        palette.isDark ? Colors.purpleAccent.shade100 : const Color(0xFF7C3AED);

    final dateStr = dateFormatter.format(
      DateTime.fromMillisecondsSinceEpoch(it.timestamp),
    );
    final hasVoice = it.ttsVoice != null && it.ttsVoice!.isNotEmpty;
    final hasVietsub = it.sentenceCount > 0;
    final isOffline = _isItemOffline(it);
    final isFinished = it.durationMs > 0 && it.lastPositionMs >= it.durationMs * 0.95;
    final isWatching = it.lastPositionMs > 0 && !isFinished;

    final isShowingTranslated = _showTranslatedItemIds.contains(it.id);
    final hasTranslated = it.displayTranslatedTitle != null && it.displayTranslatedTitle!.isNotEmpty;
    final displayTitle = isShowingTranslated && hasTranslated
        ? it.displayTranslatedTitle!
        : it.displayOriginalTitle;
    final isTranslating = _translatingItemIds.contains(it.id);

    final hasCover = it.seriesCover != null && it.seriesCover!.trim().isNotEmpty;
    final isBilibiliVideo = BilibiliResolver.isBilibiliUrl(it.videoPath) ||
        RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false).hasMatch(it.videoPath) ||
        RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false).hasMatch(it.title);
    final showCoverSlot = hasCover || isBilibiliVideo;

    return InkWell(
      onTap: isMultiSelectMode ? onToggleSelect : () => _openItem(it),
      onLongPress: !isMultiSelectMode ? onEnterMultiSelect : null,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected
              ? accent.withValues(alpha: 0.12)
              : palette.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? accent : palette.border,
            width: isSelected ? 1.8 : 1,
          ),
          boxShadow: palette.cardShadows,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isMultiSelectMode) ...[
                  Padding(
                    padding: const EdgeInsets.only(right: 10, top: 24),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSelected ? accent : Colors.transparent,
                        border: Border.all(
                          color: isSelected ? accent : palette.textMuted,
                          width: 2,
                        ),
                      ),
                      child: isSelected
                          ? Icon(Icons.check, size: 14, color: onAccent)
                          : null,
                    ),
                  ),
                ],
              if (showCoverSlot) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Stack(
                    children: [
                      hasCover
                          ? Image.network(
                              it.seriesCover!,
                              headers: _imageHeaders(it.seriesCover),
                              cacheWidth: 150,
                              width: 52,
                              height: 70,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Container(
                                width: 52,
                                height: 70,
                                color: palette.surfaceAlt,
                                child: Icon(Icons.movie, color: palette.textMuted),
                              ),
                            )
                          : Container(
                              width: 52,
                              height: 70,
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                Icons.movie_filter_rounded,
                                color: accent,
                              ),
                            ),
                      if (it.lastPositionMs > 0 && it.durationMs > 0)
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: LinearProgressIndicator(
                            value: (it.lastPositionMs / it.durationMs).clamp(0.0, 1.0),
                            minHeight: 3.5,
                            backgroundColor: Colors.black54,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              it.lastPositionMs >= it.durationMs * 0.95
                                  ? accent
                                  : watchingColor,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
              Expanded(
                child: Tooltip(
                  message: 'Chạm để sao chép',
                  child: InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: displayTitle));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('📋 Đã sao chép: "$displayTitle"'),
                          duration: const Duration(seconds: 2),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    borderRadius: BorderRadius.circular(4),
                    child: Text(
                      displayTitle,
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Nút dịch / chuyển đổi tên phim
              InkWell(
                onTap: isTranslating ? null : () => _toggleTranslateTitle(it),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: (isShowingTranslated && hasTranslated)
                        ? accent.withValues(alpha: 0.14)
                        : palette.surfaceAlt,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (isShowingTranslated && hasTranslated)
                          ? accent.withValues(alpha: 0.5)
                          : palette.border,
                    ),
                  ),
                  child: isTranslating
                      ? SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: accent,
                          ),
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.translate_rounded,
                              size: 13,
                              color: (isShowingTranslated && hasTranslated)
                                  ? accent
                                  : palette.textSecondary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              (isShowingTranslated && hasTranslated) ? 'Gốc' : 'Dịch',
                              style: TextStyle(
                                color: (isShowingTranslated && hasTranslated)
                                    ? accent
                                    : palette.textSecondary,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
              if (!isMultiSelectMode) ...[
                const SizedBox(width: 6),
                InkWell(
                  onTap: () => _confirmDelete(it),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.delete_outline,
                      color: palette.textMuted,
                      size: 20,
                    ),
                  ),
                ),
              ],
                      ],
                    ),
                    if (isShowingTranslated && hasTranslated && it.displayOriginalTitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '🇨🇳 Gốc: ${it.displayOriginalTitle}',
                              style: TextStyle(
                                color: palette.textMuted,
                                fontSize: 12,
                                fontStyle: FontStyle.italic,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          InkWell(
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: it.displayOriginalTitle));
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Row(
                                    children: [
                                      Icon(Icons.check_circle, color: accent, size: 16),
                                      const SizedBox(width: 8),
                                      Expanded(child: Text('Đã sao chép: "${it.displayOriginalTitle}"')),
                                    ],
                                  ),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            },
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                              child: Icon(
                                Icons.copy_rounded,
                                size: 14,
                                color: palette.textMuted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      dateStr,
                      style: TextStyle(
                        color: palette.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (isWatching) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: watchingColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: watchingColor.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.history_rounded, size: 12, color: watchingColor),
                      const SizedBox(width: 4),
                      Text(
                        it.durationMs > 0
                            ? '${_formatMs(it.lastPositionMs)} / ${_formatMs(it.durationMs)}'
                            : _formatMs(it.lastPositionMs),
                        style: TextStyle(
                          color: watchingColor,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ] else if (isFinished) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle_outline_rounded, size: 12, color: accent),
                      const SizedBox(width: 4),
                      Text(
                        it.durationMs > 0
                            ? 'Đã xem xong (${_formatMs(it.durationMs)})'
                            : 'Đã xem xong',
                        style: TextStyle(
                          color: accent,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: !isOffline
                      ? onlineColor.withValues(alpha: 0.12)
                      : accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: !isOffline
                        ? onlineColor.withValues(alpha: 0.38)
                        : accent.withValues(alpha: 0.35),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      !isOffline
                          ? Icons.cloud_outlined
                          : Icons.download_done_rounded,
                      size: 11,
                      color: !isOffline ? onlineColor : accent,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      isOffline ? 'Offline' : 'Online',
                      style: TextStyle(
                        color: !isOffline ? onlineColor : accent,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: hasVietsub
                      ? accent.withValues(alpha: 0.12)
                      : palette.surfaceAlt,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  hasVietsub ? 'Vietsub' : 'Chưa vietsub',
                  style: TextStyle(
                    color: hasVietsub ? accent : palette.textMuted,
                    fontSize: 11,
                    fontWeight: hasVietsub ? FontWeight.w600 : FontWeight.normal,
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
                      ? accent.withValues(alpha: 0.12)
                      : palette.surfaceAlt,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  hasVoice ? '🎤 ${it.ttsVoice}' : 'Chưa lồng tiếng',
                  style: TextStyle(
                    color: hasVoice ? accent : palette.textMuted,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          IgnorePointer(
            ignoring: isMultiSelectMode,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      ElevatedButton.icon(
                        onPressed: () {
                          if (it.isOnlineStream || (it.seriesId != null && it.seriesId!.isNotEmpty)) {
                            final dramaGroup = DramaHistoryGroup(
                              seriesKey: it.seriesId ?? it.extractedSeriesTitle,
                              seriesId: it.seriesId,
                              seriesTitle: it.extractedSeriesTitle,
                              seriesCover: it.seriesCover ?? it.coverUrl,
                              totalEpisodes: it.totalEpisodes ?? 0,
                              episodes: [it],
                            );
                            _showHongguoPlaybackOptions(
                              group: dramaGroup,
                              episodeItem: it,
                              targetEpisodeIndex: it.extractedEpisodeIndex,
                            );
                          } else {
                            _openItem(it);
                          }
                        },
                        icon: Icon(
                          Icons.play_arrow_rounded,
                          size: 18,
                          color: isWatching
                              ? palette.onColor(watchingColor)
                              : (isFinished ? accent : onAccent),
                        ),
                        label: Text(
                          isWatching
                              ? 'Xem tiếp (${_formatMs(it.lastPositionMs)})'
                              : (isFinished ? 'Xem lại từ đầu' : 'Xem Video'),
                          style: TextStyle(
                            color: isWatching
                                ? palette.onColor(watchingColor)
                                : (isFinished ? palette.textPrimary : onAccent),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isWatching
                              ? watchingColor
                              : (isFinished ? palette.surfaceAlt : accent),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                      ),
                      if (widget.onOpenInTts != null)
                        OutlinedButton.icon(
                          onPressed: () => _openInTts(it),
                          icon: Icon(
                            Icons.record_voice_over,
                            size: 16,
                            color: accent,
                          ),
                          label: Text(
                            hasVoice ? 'Đổi giọng' : 'Lồng tiếng',
                            style: TextStyle(
                              color: palette.textPrimary,
                              fontSize: 12,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: palette.border),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.file_download_outlined,
                    color: palette.textSecondary,
                    size: 22,
                  ),
                  tooltip: 'Xuất file SRT',
                  onPressed: () => _exportSrt(it),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

  Future<void> _confirmClearWatchLater() async {
    final palette = AppThemePalette.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: palette.surface,
        title: Text('Xóa danh sách xem sau', style: TextStyle(color: palette.textPrimary)),
        content: Text(
          'Bạn có chắc chắn muốn xóa toàn bộ các mục trong danh sách Xem sau không?',
          style: TextStyle(color: palette.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Hủy', style: TextStyle(color: palette.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xóa tất cả', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final repo = await WatchLaterRepository.getInstance();
      await repo.clearAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã xóa toàn bộ danh sách Xem sau')),
        );
      }
    }
  }

  Future<void> _openWatchLaterItem(WatchLaterItem it, [List<HistoryItem>? historyItems]) async {
    if (historyItems != null) {
      final link = _resolveWatchLaterHistoryLink(it, historyItems);
      link.onPlay();
      return;
    }
    if (it.isHongguo) {
      await _openWatchLaterHongguo(it);
    } else {
      await _openWatchLaterBilibili(it);
    }
  }

  Future<void> _openWatchLaterHongguo(WatchLaterItem item, {int targetEpisodeIndex = 1}) async {
    final dramaId = item.seriesId ?? item.targetUrl;
    HongguoDramaDetail? dramaDetail;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Đang chuẩn bị ${item.title} - Tập $targetEpisodeIndex...',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 2),
      ),
    );

    try {
      dramaDetail = await _hongguoResolver.getDramaDetail(dramaId);
    } catch (_) {
      dramaDetail = HongguoDramaDetail(
        seriesId: dramaId,
        title: item.title,
        cover: item.coverUrl ?? '',
        intro: '',
        totalEpisodes: item.totalEpisodes ?? 100,
        episodes: [],
      );
    }

    var vid = '';
    if (dramaDetail.episodes.isNotEmpty && targetEpisodeIndex <= dramaDetail.episodes.length) {
      vid = dramaDetail.episodes[targetEpisodeIndex - 1].vid;
    }

    String effectiveVideoPath;
    try {
      effectiveVideoPath = await _hongguoResolver.getEpisodePlayUrl(
        dramaId,
        vid.isNotEmpty ? vid : dramaId,
        episodeIndex: targetEpisodeIndex,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Không thể lấy video tập $targetEpisodeIndex: $error'),
          backgroundColor: Colors.redAccent.shade700,
        ),
      );
      return;
    }

    final cached = await VideoCacheManager.findCachedFile(
      url: effectiveVideoPath,
      seriesId: dramaId,
      episodeIndex: targetEpisodeIndex,
    );
    if (cached != null && cached.existsSync() && cached.lengthSync() > 1000) {
      effectiveVideoPath = cached.path;
    }

    if (!mounted) return;
    GlobalPlayerManager.instance.openPlayer(
      videoPath: effectiveVideoPath,
      title: '${item.title} - Tập $targetEpisodeIndex',
      coverUrl: item.coverUrl,
      document: SubtitleDocument(),
      dramaDetail: dramaDetail,
      currentEpisodeIndex: targetEpisodeIndex,
    );
  }

  Future<void> _openWatchLaterBilibili(WatchLaterItem item) async {
    final url = item.targetUrl.startsWith('http')
        ? item.targetUrl
        : 'https://www.bilibili.com/video/${item.targetUrl}';
    GlobalPlayerManager.instance.openPlayer(
      videoPath: url,
      title: item.title,
      coverUrl: item.coverUrl,
      document: SubtitleDocument(),
    );
  }

  Widget _buildFilterChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    required Color color,
  }) {
    final palette = AppThemePalette.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: palette.isDark ? 0.24 : 0.14)
              : palette.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? color : palette.border,
            width: isSelected ? 1.2 : 0.9,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? color : palette.textSecondary,
            fontSize: 11.5,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildWatchLaterTab(
    BuildContext context,
    List<WatchLaterItem> allItems,
    List<HistoryItem> historyItems,
  ) {
    final palette = AppThemePalette.of(context);
    final hgAccent = palette.accentFor(AppTabId.hongguo);
    final biliAccent = palette.accentFor(AppTabId.bilibili);
    final amberColor = palette.isDark ? Colors.amber : const Color(0xFFD97706);

    final hgItems = allItems.where((it) => it.isHongguo).toList();
    final biliItems = allItems.where((it) => it.isBilibili).toList();

    final List<WatchLaterItem> filtered;
    if (_watchLaterFilter == 'hongguo') {
      filtered = hgItems;
    } else if (_watchLaterFilter == 'bilibili') {
      filtered = biliItems;
    } else {
      filtered = allItems;
    }

    final dateFormatter = DateFormat('dd/MM/yyyy HH:mm');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Thanh bộ lọc & nút xóa tất cả
        Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: Row(
                  children: [
                    _buildFilterChip(
                      label: 'Tất cả (${allItems.length})',
                      isSelected: _watchLaterFilter == 'all',
                      onTap: () => setState(() => _watchLaterFilter = 'all'),
                      color: amberColor,
                    ),
                    const SizedBox(width: 8),
                    _buildFilterChip(
                      label: 'Hồng Quả (${hgItems.length})',
                      isSelected: _watchLaterFilter == 'hongguo',
                      onTap: () => setState(() => _watchLaterFilter = 'hongguo'),
                      color: hgAccent,
                    ),
                    const SizedBox(width: 8),
                    _buildFilterChip(
                      label: 'Bilibili (${biliItems.length})',
                      isSelected: _watchLaterFilter == 'bilibili',
                      onTap: () => setState(() => _watchLaterFilter = 'bilibili'),
                      color: biliAccent,
                    ),
                  ],
                ),
              ),
            ),
            if (allItems.isNotEmpty) ...[
              const SizedBox(width: 6),
              TextButton.icon(
                onPressed: _confirmClearWatchLater,
                icon: Icon(Icons.delete_sweep_outlined, size: 16, color: palette.textMuted),
                label: Text('Xóa tất cả', style: TextStyle(color: palette.textMuted, fontSize: 12)),
                style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2)),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),

        if (filtered.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 20),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: palette.border),
              boxShadow: palette.cardShadows,
            ),
            child: Column(
              children: [
                Icon(
                  Icons.bookmark_border_rounded,
                  color: palette.textMuted.withValues(alpha: 0.45),
                  size: 56,
                ),
                const SizedBox(height: 14),
                Text(
                  allItems.isEmpty
                      ? 'Chưa có phim hoặc video nào trong Xem sau'
                      : 'Không có mục nào trong danh mục này',
                  style: TextStyle(color: palette.textPrimary, fontSize: 15, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  'Khi lướt phim ở Hồng Quả, video Bilibili hoặc trong trình phát, hãy chạm vào nút 🔖 Xem sau để lưu lại xem bất cứ lúc nào!',
                  style: TextStyle(color: palette.textSecondary, fontSize: 12, height: 1.4),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: filtered.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (ctx, i) {
              final it = filtered[i];
              return _buildWatchLaterCard(ctx, it, dateFormatter, historyItems);
            },
          ),
      ],
    );
  }

  _WatchLaterHistoryLink _resolveWatchLaterHistoryLink(
    WatchLaterItem it,
    List<HistoryItem> historyItems,
  ) {
    if (it.isHongguo) {
      final dramaId = it.seriesId ?? it.targetUrl;
      final matchingEpisodes = historyItems.where((h) {
        final hasDramaId = dramaId.isNotEmpty &&
            ((h.seriesId != null && h.seriesId == dramaId) ||
                h.videoPath.contains('/drama/$dramaId/') ||
                h.id.contains(dramaId));
        if (hasDramaId) return true;
        if (it.title.isNotEmpty &&
            (h.extractedSeriesTitle == it.title || h.title.startsWith(it.title))) {
          return true;
        }
        return false;
      }).toList();

      if (matchingEpisodes.isNotEmpty) {
        final dramaGroup = DramaHistoryGroup(
          seriesKey: dramaId.isNotEmpty ? dramaId : it.title,
          seriesTitle: it.title,
          seriesId: dramaId.isNotEmpty ? dramaId : null,
          seriesCover: it.coverUrl,
          totalEpisodes: (it.totalEpisodes != null && it.totalEpisodes! > 0)
              ? it.totalEpisodes!
              : matchingEpisodes.length,
          episodes: matchingEpisodes,
        );

        final latest = dramaGroup.latestWatchedEpisode;
        final latestEpNum = latest.extractedEpisodeIndex;
        final isFinished = latest.durationMs > 0 &&
            latest.lastPositionMs >= latest.durationMs * 0.95;
        final isWatching = latest.lastPositionMs > 0 && !isFinished;
        final progress = (latest.durationMs > 0 && isWatching)
            ? (latest.lastPositionMs / latest.durationMs).clamp(0.0, 1.0)
            : null;

        final String statusText;
        final String buttonText;
        final IconData buttonIcon;
        final VoidCallback onPlayAction;

        if (isWatching) {
          statusText = 'Tập $latestEpNum (${_formatMs(latest.lastPositionMs)})';
          buttonText = 'Xem tiếp Tập $latestEpNum (${_formatMs(latest.lastPositionMs)})';
          buttonIcon = Icons.play_arrow_rounded;
          onPlayAction = () => _showHongguoPlaybackOptions(
            group: dramaGroup,
            episodeItem: latest,
            targetEpisodeIndex: latestEpNum,
            watchLaterItem: it,
          );
        } else if (isFinished) {
          final nextEpNum = latestEpNum + 1;
          final nextEp = matchingEpisodes
              .where((e) => e.extractedEpisodeIndex == nextEpNum)
              .firstOrNull;
          statusText = 'Đã xem xong Tập $latestEpNum';
          buttonText = 'Xem tiếp Tập $nextEpNum';
          buttonIcon = Icons.skip_next_rounded;
          onPlayAction = () => _showHongguoPlaybackOptions(
            group: dramaGroup,
            episodeItem: nextEp,
            targetEpisodeIndex: nextEpNum,
            watchLaterItem: it,
          );
        } else {
          statusText = 'Đã lưu ${matchingEpisodes.length} tập trong máy';
          buttonText = 'Xem tiếp Tập $latestEpNum';
          buttonIcon = Icons.play_arrow_rounded;
          onPlayAction = () => _showHongguoPlaybackOptions(
            group: dramaGroup,
            episodeItem: latest,
            targetEpisodeIndex: latestEpNum,
            watchLaterItem: it,
          );
        }

        return _WatchLaterHistoryLink(
          hasHistory: true,
          isWatching: isWatching,
          isFinished: isFinished,
          statusText: statusText,
          buttonText: buttonText,
          buttonIcon: buttonIcon,
          dramaGroup: dramaGroup,
          progressPercent: progress,
          onPlay: onPlayAction,
        );
      } else {
        // Chưa có lịch sử tập nào của phim này
        final epCountText = (it.totalEpisodes != null && it.totalEpisodes! > 0)
            ? 'Phim bộ · Tổng ${it.totalEpisodes} tập'
            : 'Phim bộ Hồng Quả';
        return _WatchLaterHistoryLink(
          hasHistory: false,
          isWatching: false,
          isFinished: false,
          statusText: epCountText,
          buttonText: 'Xem ngay (Tập 1)',
          buttonIcon: Icons.play_arrow_rounded,
          onPlay: () {
            final dramaGroup = DramaHistoryGroup(
              seriesKey: dramaId.isNotEmpty ? dramaId : it.title,
              seriesTitle: it.title,
              seriesId: dramaId.isNotEmpty ? dramaId : null,
              seriesCover: it.coverUrl,
              totalEpisodes: (it.totalEpisodes != null && it.totalEpisodes! > 0)
                  ? it.totalEpisodes!
                  : 100,
              episodes: [],
            );
            _showHongguoPlaybackOptions(
              group: dramaGroup,
              targetEpisodeIndex: 1,
              watchLaterItem: it,
            );
          },
        );
      }
    } else {
      // Bilibili
      final bvidMatch = RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false)
          .firstMatch('${it.targetUrl} ${it.id} ${it.title}');
      final bvid = bvidMatch?.group(0);

      HistoryItem? matchedHistory;
      if (bvid != null && bvid.isNotEmpty) {
        matchedHistory = historyItems.where((h) =>
            h.videoPath.contains(bvid) ||
            h.id.contains(bvid) ||
            h.title.contains(bvid)).firstOrNull;
      }
      matchedHistory ??= historyItems.where((h) =>
          h.videoPath == it.targetUrl ||
          (it.title.isNotEmpty && h.title == it.title)).firstOrNull;

      if (matchedHistory != null) {
        final isFinished = matchedHistory.durationMs > 0 &&
            matchedHistory.lastPositionMs >= matchedHistory.durationMs * 0.95;
        final isWatching = matchedHistory.lastPositionMs > 0 && !isFinished;
        final progress = (matchedHistory.durationMs > 0 && isWatching)
            ? (matchedHistory.lastPositionMs / matchedHistory.durationMs).clamp(0.0, 1.0)
            : null;

        final String statusText;
        final String buttonText;
        final IconData buttonIcon;

        if (isWatching) {
          statusText = matchedHistory.durationMs > 0
              ? '${_formatMs(matchedHistory.lastPositionMs)} / ${_formatMs(matchedHistory.durationMs)}'
              : _formatMs(matchedHistory.lastPositionMs);
          buttonText = 'Xem tiếp (${_formatMs(matchedHistory.lastPositionMs)})';
          buttonIcon = Icons.play_arrow_rounded;
        } else if (isFinished) {
          statusText = matchedHistory.durationMs > 0
              ? 'Đã xem xong (${_formatMs(matchedHistory.durationMs)})'
              : 'Đã xem xong';
          buttonText = 'Xem lại từ đầu';
          buttonIcon = Icons.replay_rounded;
        } else {
          statusText = (it.author != null && it.author!.isNotEmpty)
              ? 'Kênh: ${it.author}'
              : 'Bilibili Video';
          buttonText = 'Xem video';
          buttonIcon = Icons.play_arrow_rounded;
        }

        final targetItem = matchedHistory;
        return _WatchLaterHistoryLink(
          hasHistory: true,
          isWatching: isWatching,
          isFinished: isFinished,
          statusText: statusText,
          buttonText: buttonText,
          buttonIcon: buttonIcon,
          progressPercent: progress,
          onPlay: () => _openItem(targetItem),
        );
      } else {
        final authorText = (it.author != null && it.author!.isNotEmpty)
            ? 'Kênh: ${it.author}'
            : 'Video Bilibili';
        return _WatchLaterHistoryLink(
          hasHistory: false,
          isWatching: false,
          isFinished: false,
          statusText: authorText,
          buttonText: 'Xem ngay',
          buttonIcon: Icons.play_arrow_rounded,
          onPlay: () => _openWatchLaterBilibili(it),
        );
      }
    }
  }

  Widget _buildWatchLaterCard(
    BuildContext context,
    WatchLaterItem it,
    DateFormat dateFormatter,
    List<HistoryItem> historyItems,
  ) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.history);
    final watchingColor =
        palette.isDark ? AppTheme.accentGold : const Color(0xFFD97706);

    final isHongguo = it.isHongguo;
    final sourceColor = isHongguo
        ? palette.accentFor(AppTabId.hongguo)
        : palette.accentFor(AppTabId.bilibili);
    final sourceLabel = isHongguo ? 'Hồng Quả' : 'Bilibili';
    final link = _resolveWatchLaterHistoryLink(it, historyItems);

    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: link.isWatching
              ? watchingColor.withValues(alpha: 0.45)
              : palette.border,
          width: link.isWatching ? 1.2 : 1,
        ),
        boxShadow: palette.cardShadows,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openWatchLaterItem(it, historyItems),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Ảnh bìa
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  children: [
                    SizedBox(
                      width: 82,
                      height: 108,
                      child: (it.coverUrl != null && it.coverUrl!.isNotEmpty)
                          ? Image.network(
                              it.coverUrl!,
                              headers: _imageHeaders(it.coverUrl),
                              cacheWidth: 200,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Container(
                                color: palette.surfaceAlt,
                                child: Icon(
                                  isHongguo ? Icons.movie_rounded : Icons.tv_rounded,
                                  color: palette.textMuted,
                                ),
                              ),
                            )
                          : Container(
                              color: palette.surfaceAlt,
                              child: Icon(
                                isHongguo ? Icons.movie_rounded : Icons.tv_rounded,
                                color: palette.textMuted,
                              ),
                            ),
                    ),
                    Positioned(
                      top: 4,
                      left: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: sourceColor.withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          sourceLabel,
                          style: TextStyle(
                            color: palette.onColor(sourceColor),
                            fontSize: 9.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    if (link.progressPercent != null)
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: LinearProgressIndicator(
                          value: link.progressPercent!,
                          minHeight: 3.5,
                          backgroundColor: Colors.black54,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            link.isFinished ? accent : watchingColor,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),

              // Thông tin
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      it.displayTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 6),

                    // Trạng thái liên kết lịch sử
                    if (link.isWatching)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                        decoration: BoxDecoration(
                          color: watchingColor.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: watchingColor.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.history_rounded, size: 12, color: watchingColor),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                link.statusText,
                                style: TextStyle(
                                  color: watchingColor,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      )
                    else if (link.isFinished)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: accent.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle_outline_rounded, size: 12, color: accent),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                link.statusText,
                                style: TextStyle(
                                  color: accent,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      Text(
                        link.statusText,
                        style: TextStyle(color: palette.textSecondary, fontSize: 11.5),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    const SizedBox(height: 4),

                    Text(
                      'Đã lưu: ${dateFormatter.format(DateTime.fromMillisecondsSinceEpoch(it.addedAt))}',
                      style: TextStyle(color: palette.textMuted, fontSize: 10.5),
                    ),
                    const SizedBox(height: 10),

                    // Nút thao tác
                    Row(
                      children: [
                        Expanded(
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              ElevatedButton.icon(
                                onPressed: () => _openWatchLaterItem(it, historyItems),
                                icon: Icon(link.buttonIcon, size: 16),
                                label: Text(
                                  link.buttonText,
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: link.isWatching ? watchingColor : sourceColor,
                                  foregroundColor: palette.onColor(
                                    link.isWatching ? watchingColor : sourceColor,
                                  ),
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  minimumSize: const Size(0, 32),
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                                ),
                              ),
                              if (link.dramaGroup != null)
                                OutlinedButton.icon(
                                  onPressed: () => _showDramaEpisodesSheet(link.dramaGroup!),
                                  icon: Icon(Icons.list_alt_rounded, size: 14, color: palette.textSecondary),
                                  label: Text(
                                    'Tập (${link.dramaGroup!.episodes.length})',
                                    style: TextStyle(fontSize: 11, color: palette.textSecondary),
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    side: BorderSide(color: palette.border),
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                    minimumSize: const Size(0, 32),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.delete_outline_rounded, color: palette.textMuted, size: 20),
                          tooltip: 'Xóa khỏi xem sau',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                          onPressed: () async {
                            final repo = await WatchLaterRepository.getInstance();
                            await repo.removeItem(it.id);
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).hideCurrentSnackBar();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Đã xóa "${it.title}" khỏi Xem sau'),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Thông tin liên kết giữa một mục Xem sau và Lịch sử xem
class _WatchLaterHistoryLink {
  final bool hasHistory;
  final bool isWatching;
  final bool isFinished;
  final String statusText;
  final String buttonText;
  final IconData buttonIcon;
  final VoidCallback onPlay;
  final DramaHistoryGroup? dramaGroup;
  final double? progressPercent;

  _WatchLaterHistoryLink({
    required this.hasHistory,
    required this.isWatching,
    required this.isFinished,
    required this.statusText,
    required this.buttonText,
    required this.buttonIcon,
    required this.onPlay,
    this.dramaGroup,
    this.progressPercent,
  });
}

/// Widget hiển thị Bottom Sheet danh sách tập của phim bộ, hỗ trợ xem và chọn nhiều tập để xóa
Future<bool> _probeHistoryOfflineExists(HistoryItem it) async {
  try {
    final path = it.videoPath.trim();
    if (path.isNotEmpty) {
      if (MediaStorage.isContentUri(path)) return true;
      final isRemote =
          path.startsWith('http://') || path.startsWith('https://');
      if (!isRemote) {
        final resolved = await HistoryRepository.resolvePath(path);
        final file = File(resolved);
        if (await file.exists() && await file.length() > 0) {
          return true;
        }
      }
    }

    final bvidMatch =
        RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false).firstMatch(path) ??
        RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false).firstMatch(it.id) ??
        RegExp(r'BV1[0-9a-zA-Z]{9}', caseSensitive: false).firstMatch(it.title);
    final bvid = bvidMatch?.group(0);
    final pageStr =
        RegExp(r'[?&]p=(\d+)', caseSensitive: false)
            .firstMatch(path)
            ?.group(1) ??
        '1';
    final bilibiliPage = int.tryParse(pageStr) ?? 1;

    final cachedFile = await VideoCacheManager.findCachedFile(
      url: path,
      seriesId: it.seriesId,
      episodeIndex: it.extractedEpisodeIndex,
      bvid: bvid,
      bilibiliPage: bvid != null ? bilibiliPage : null,
    );
    if (cachedFile != null &&
        await cachedFile.exists() &&
        await cachedFile.length() > 1024 * 50) {
      return true;
    }
  } catch (_) {}
  return false;
}

class _DramaEpisodesSheetWidget extends StatefulWidget {
  final DramaHistoryGroup group;
  final HongguoResolver hongguoResolver;
  final void Function(
    HistoryItem ep,
    DramaHistoryGroup group, {
    int? customEpisodeIndex,
  }) onOpenEpisode;
  final void Function(int epIndex, DramaHistoryGroup group, HongguoDramaDetail detail) onOpenUnwatchedEpisode;
  final void Function(HistoryItem ep) onOpenTts;
  final void Function(HistoryItem ep) onExportSrt;
  final void Function(HistoryItem ep) onConfirmDeleteSingle;
  final Map<String, String>? Function(String? url) imageHeaders;
  final String Function(int ms) formatMs;

  const _DramaEpisodesSheetWidget({
    required this.group,
    required this.hongguoResolver,
    required this.onOpenEpisode,
    required this.onOpenUnwatchedEpisode,
    required this.onOpenTts,
    required this.onExportSrt,
    required this.onConfirmDeleteSingle,
    required this.imageHeaders,
    required this.formatMs,
  });

  @override
  State<_DramaEpisodesSheetWidget> createState() => _DramaEpisodesSheetWidgetState();
}

class _DramaEpisodesSheetWidgetState extends State<_DramaEpisodesSheetWidget> {
  bool _isEpMultiSelect = false;
  final Set<String> _selectedEpIds = {};
  final Map<String, bool> _epOfflineAvailability = {};
  final Set<String> _probingEpIds = {};

  bool _isEpisodeOffline(HistoryItem ep) {
    final path = ep.videoPath.trim();
    if (path.isNotEmpty) {
      if (MediaStorage.isContentUri(path)) return true;
      if (!path.startsWith('http://') && !path.startsWith('https://')) {
        if (File(path).existsSync()) return true;
      }
    }
    final cached = _epOfflineAvailability[ep.id];
    if (cached != null) return cached;
    if (!_probingEpIds.contains(ep.id)) {
      _probingEpIds.add(ep.id);
      unawaited(() async {
        final ok = await _probeHistoryOfflineExists(ep);
        _probingEpIds.remove(ep.id);
        if (!mounted) return;
        final prev = _epOfflineAvailability[ep.id];
        _epOfflineAvailability[ep.id] = ok;
        if (prev != ok && ok) {
          setState(() {});
        }
      }());
    }
    return false;
  }

  void _enterEpMultiSelect([String? initialId]) {
    HapticFeedback.mediumImpact();
    setState(() {
      _isEpMultiSelect = true;
      _selectedEpIds.clear();
      if (initialId != null) {
        _selectedEpIds.add(initialId);
      }
    });
  }

  void _exitEpMultiSelect() {
    setState(() {
      _isEpMultiSelect = false;
      _selectedEpIds.clear();
    });
  }

  void _toggleEpSelection(String id) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_selectedEpIds.contains(id)) {
        _selectedEpIds.remove(id);
      } else {
        _selectedEpIds.add(id);
        _isEpMultiSelect = true;
      }
    });
  }

  void _toggleEpSelectAll(List<HistoryItem> episodes) {
    HapticFeedback.selectionClick();
    setState(() {
      final allIds = episodes.map((e) => e.id).toSet();
      if (allIds.isNotEmpty && _selectedEpIds.containsAll(allIds)) {
        _selectedEpIds.clear();
      } else {
        _selectedEpIds.addAll(allIds);
      }
    });
  }

  Future<void> _confirmDeleteSelectedEpisodes(List<HistoryItem> episodes) async {
    if (_selectedEpIds.isEmpty) return;
    final palette = AppThemePalette.of(context);
    final count = _selectedEpIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: palette.surface,
        title: Text('Xóa tập đã chọn', style: TextStyle(color: palette.textPrimary)),
        content: Text(
          'Bạn có chắc chắn muốn xóa $count tập đã chọn của phim "${widget.group.seriesTitle}" không?\n\nFile video offline và phụ đề tương ứng sẽ được dọn dẹp khỏi máy.',
          style: TextStyle(color: palette.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Hủy', style: TextStyle(color: palette.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Xóa ($count)', style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final idsToDelete = List<String>.from(_selectedEpIds);
      _exitEpMultiSelect();
      final repo = await HistoryRepository.getInstance();
      await repo.deleteItems(idsToDelete);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Đã xóa $count tập khỏi lịch sử')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.history);

    return ValueListenableBuilder<List<HistoryItem>>(
      valueListenable: HistoryRepository.historyNotifier,
      builder: (context, allItems, _) {
        // Lấy danh sách các tập hiện tại thuộc nhóm phim này
        final currentEpisodes = allItems
            .where((it) =>
                (widget.group.seriesId != null &&
                    widget.group.seriesId!.isNotEmpty &&
                    it.seriesId == widget.group.seriesId) ||
                it.extractedSeriesTitle == widget.group.seriesTitle)
            .toList()
          ..sort((a, b) => a.extractedEpisodeIndex.compareTo(b.extractedEpisodeIndex));

        // Nếu tất cả các tập đã bị xóa hết, tự động đóng sheet
        if (currentEpisodes.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Navigator.of(context).maybePop();
            }
          });
          return const SizedBox.shrink();
        }

        final currentGroup = DramaHistoryGroup(
          seriesKey: widget.group.seriesKey,
          seriesTitle: widget.group.seriesTitle,
          seriesId: widget.group.seriesId,
          seriesCover: widget.group.seriesCover,
          totalEpisodes: widget.group.totalEpisodes,
          episodes: currentEpisodes,
        );

        return DefaultTabController(
          length: 2,
          child: Container(
            height: MediaQuery.of(context).size.height * 0.85,
            decoration: BoxDecoration(
              color: palette.backgroundFor(AppTabId.history),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              children: [
                // Drag handle
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 8),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: palette.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                // Header phim
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: (currentGroup.seriesCover != null &&
                                currentGroup.seriesCover!.isNotEmpty)
                            ? Image.network(
                                currentGroup.seriesCover!,
                                headers: widget.imageHeaders(currentGroup.seriesCover),
                                cacheWidth: 150,
                                width: 56,
                                height: 74,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => Container(
                                  width: 56,
                                  height: 74,
                                  color: palette.surfaceAlt,
                                  child: Icon(
                                    Icons.movie,
                                    color: palette.textMuted,
                                  ),
                                ),
                              )
                            : Container(
                                width: 56,
                                height: 74,
                                color: palette.surfaceAlt,
                                child: Icon(
                                  Icons.movie,
                                  color: accent,
                                ),
                              ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              currentGroup.seriesTitle,
                              style: TextStyle(
                                color: palette.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: accent.withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    'Đã lưu ${currentEpisodes.length} tập',
                                    style: TextStyle(
                                      color: accent,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                if (currentGroup.totalEpisodes > 0)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: palette.surfaceAlt,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      'Tổng ${currentGroup.totalEpisodes} tập',
                                      style: TextStyle(
                                        color: palette.textSecondary,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Tab Bar
                TabBar(
                  indicatorColor: accent,
                  labelColor: accent,
                  unselectedLabelColor: palette.textMuted,
                  dividerColor: palette.border,
                  labelStyle: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                  tabs: [
                    Tab(text: 'TẬP ĐÃ LƯU (${currentEpisodes.length})'),
                    Tab(
                      text: currentGroup.totalEpisodes > 0
                          ? 'TẤT CẢ TẬP (${currentGroup.totalEpisodes})'
                          : 'TẤT CẢ TẬP',
                    ),
                  ],
                ),

                // Nội dung 2 tab
                Expanded(
                  child: TabBarView(
                    children: [
                      // TAB 1: Danh sách các tập đã lưu trong máy
                      _buildSavedEpisodesTab(currentEpisodes, currentGroup),

                      // TAB 2: Lướt tất cả các tập của phim từ server Hồng Quả
                      _buildAllDramaEpisodesView(currentGroup),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSavedEpisodesTab(List<HistoryItem> currentEpisodes, DramaHistoryGroup currentGroup) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.history);
    final onAccent = palette.onColor(accent);
    final onlineColor =
        palette.isDark ? Colors.purpleAccent.shade100 : const Color(0xFF7C3AED);

    final isAllSelected = currentEpisodes.isNotEmpty &&
        _selectedEpIds.length == currentEpisodes.length;

    return Column(
      children: [
        // Sub-toolbar cho Tab 1
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: _isEpMultiSelect ? palette.surfaceAlt : Colors.transparent,
          child: Row(
            children: [
              if (_isEpMultiSelect) ...[
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  icon: Icon(Icons.close_rounded, color: palette.textSecondary, size: 20),
                  onPressed: _exitEpMultiSelect,
                  tooltip: 'Hủy chọn',
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Đã chọn ${_selectedEpIds.length} tập',
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => _toggleEpSelectAll(currentEpisodes),
                  child: Text(
                    isAllSelected ? 'Bỏ chọn' : 'Tất cả',
                    style: TextStyle(
                      color: accent,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    minimumSize: Size.zero,
                  ),
                  onPressed: _selectedEpIds.isEmpty
                      ? null
                      : () => _confirmDeleteSelectedEpisodes(currentEpisodes),
                  icon: const Icon(Icons.delete_outline, size: 15, color: Colors.white),
                  label: Text(
                    'Xóa (${_selectedEpIds.length})',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ] else ...[
                Expanded(
                  child: Text(
                    'Danh sách tập có trong lịch sử (${currentEpisodes.length})',
                    style: TextStyle(color: palette.textMuted, fontSize: 12),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _enterEpMultiSelect(),
                  icon: Icon(Icons.checklist_rounded, size: 16, color: accent),
                  label: Text(
                    'Chọn nhiều tập',
                    style: TextStyle(
                      color: accent,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                  ),
                ),
              ],
            ],
          ),
        ),
        Divider(color: palette.border, height: 1),

        // Episode List
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            itemCount: currentEpisodes.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (ctx, i) {
              final ep = currentEpisodes[i];
              final epNum = ep.extractedEpisodeIndex;
              final durStr = widget.formatMs(ep.durationMs);
              final posStr = widget.formatMs(ep.lastPositionMs);
              final hasVoice = ep.ttsVoice != null && ep.ttsVoice!.isNotEmpty;
              final isSelected = _selectedEpIds.contains(ep.id);

              return InkWell(
                onTap: () {
                  if (_isEpMultiSelect) {
                    _toggleEpSelection(ep.id);
                  } else {
                    widget.onOpenEpisode(ep, currentGroup, customEpisodeIndex: epNum);
                  }
                },
                onLongPress: () {
                  if (!_isEpMultiSelect) {
                    _enterEpMultiSelect(ep.id);
                  }
                },
                borderRadius: BorderRadius.circular(14),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? accent.withValues(alpha: 0.12)
                        : palette.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isSelected ? accent : palette.border,
                      width: isSelected ? 1.6 : 1,
                    ),
                    boxShadow: palette.cardShadows,
                  ),
                  child: Row(
                    children: [
                      if (_isEpMultiSelect) ...[
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: 22,
                          height: 22,
                          margin: const EdgeInsets.only(right: 12),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isSelected ? accent : Colors.transparent,
                            border: Border.all(
                              color: isSelected ? accent : palette.textMuted,
                              width: 2,
                            ),
                          ),
                          child: isSelected
                              ? Icon(Icons.check, size: 14, color: onAccent)
                              : null,
                        ),
                      ],
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '$epNum',
                          style: TextStyle(
                            color: accent,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  'Tập $epNum',
                                  style: TextStyle(
                                    color: palette.textPrimary,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Builder(
                                  builder: (context) {
                                    final isEpOffline = _isEpisodeOffline(ep);
                                    return Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 1.5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: !isEpOffline
                                            ? onlineColor.withValues(alpha: 0.14)
                                            : accent.withValues(alpha: 0.14),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: !isEpOffline
                                              ? onlineColor.withValues(alpha: 0.4)
                                              : accent.withValues(alpha: 0.4),
                                          width: 0.8,
                                        ),
                                      ),
                                      child: Text(
                                        isEpOffline ? 'Offline' : 'Online',
                                        style: TextStyle(
                                          color: !isEpOffline
                                              ? onlineColor
                                              : accent,
                                          fontSize: 9,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'Đã xem: $posStr / $durStr  •  ${ep.sentenceCount > 0 ? "Vietsub" : "Chưa vietsub"}',
                              style: TextStyle(
                                color: palette.textMuted,
                                fontSize: 11,
                              ),
                            ),
                            if (hasVoice)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  '🎤 ${ep.ttsVoice}',
                                  style: TextStyle(
                                    color: accent,
                                    fontSize: 10,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (!_isEpMultiSelect) ...[
                        IconButton(
                          icon: Icon(
                            Icons.play_circle_fill_rounded,
                            color: accent,
                            size: 30,
                          ),
                          tooltip: 'Xem tập $epNum',
                          onPressed: () => widget.onOpenEpisode(ep, currentGroup, customEpisodeIndex: epNum),
                        ),
                        PopupMenuButton<String>(
                          icon: Icon(
                            Icons.more_vert,
                            color: palette.textSecondary,
                            size: 20,
                          ),
                          color: palette.surface,
                          onSelected: (val) {
                            if (val == 'tts') {
                              widget.onOpenTts(ep);
                            } else if (val == 'srt') {
                              widget.onExportSrt(ep);
                            } else if (val == 'delete') {
                              widget.onConfirmDeleteSingle(ep);
                            }
                          },
                          itemBuilder: (ctx) => [
                            PopupMenuItem(
                              value: 'tts',
                              child: Text(
                                'Lồng tiếng AI',
                                style: TextStyle(color: palette.textPrimary),
                              ),
                            ),
                            PopupMenuItem(
                              value: 'srt',
                              child: Text(
                                'Xuất file SRT',
                                style: TextStyle(color: palette.textPrimary),
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text(
                                'Xóa tập này',
                                style: TextStyle(
                                  color: Colors.redAccent,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildAllDramaEpisodesView(DramaHistoryGroup group) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.history);

    if (group.seriesId == null || group.seriesId!.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search, size: 48, color: palette.textMuted.withValues(alpha: 0.5)),
              const SizedBox(height: 12),
              Text(
                'Phim này chưa liên kết mã Hồng Quả',
                style: TextStyle(color: palette.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: Icon(Icons.explore_outlined, color: accent),
                label: Text('Đóng', style: TextStyle(color: palette.textPrimary)),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: palette.border),
                ),
                onPressed: () {
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        ),
      );
    }

    return FutureBuilder<HongguoDramaDetail>(
      future: widget.hongguoResolver.getDramaDetail(group.seriesId!),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: CircularProgressIndicator(color: accent),
          );
        }

        if (snapshot.hasError || !snapshot.hasData) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_off_rounded,
                    size: 44, color: palette.textMuted.withValues(alpha: 0.5)),
                const SizedBox(height: 10),
                Text(
                  'Không thể tải danh sách tập từ máy chủ',
                  style: TextStyle(color: palette.textSecondary),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: palette.surfaceAlt,
                    elevation: 0,
                  ),
                  onPressed: () => setState(() {}),
                  child: Text('Thử lại',
                      style: TextStyle(color: palette.textPrimary)),
                ),
              ],
            ),
          );
        }

        final detail = snapshot.data!;
        final total = detail.episodes.isNotEmpty
            ? detail.episodes.length
            : (detail.totalEpisodes > 0 ? detail.totalEpisodes : 1);

        final savedIndices = group.episodes
            .map((e) => e.extractedEpisodeIndex)
            .toSet();

        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 5,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 1.25,
          ),
          itemCount: total,
          itemBuilder: (ctx, i) {
            final epIndex = i + 1;
            final isSaved = savedIndices.contains(epIndex);

            return InkWell(
              onTap: () {
                if (isSaved) {
                  final existingItem = group.episodes.where(
                    (e) => e.extractedEpisodeIndex == epIndex || e.episodeIndex == epIndex,
                  ).firstOrNull;
                  if (existingItem != null) {
                    widget.onOpenEpisode(
                      existingItem,
                      group,
                      customEpisodeIndex: epIndex,
                    );
                  } else {
                    widget.onOpenUnwatchedEpisode(epIndex, group, detail);
                  }
                } else {
                  widget.onOpenUnwatchedEpisode(epIndex, group, detail);
                }
              },
              borderRadius: BorderRadius.circular(10),
              child: Container(
                decoration: BoxDecoration(
                  color: isSaved
                      ? accent.withValues(alpha: 0.14)
                      : palette.surfaceAlt,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isSaved ? accent : palette.border,
                    width: isSaved ? 1.5 : 1,
                  ),
                ),
                alignment: Alignment.center,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '$epIndex',
                      style: TextStyle(
                        color: isSaved ? accent : palette.textPrimary,
                        fontWeight:
                            isSaved ? FontWeight.bold : FontWeight.normal,
                        fontSize: 13,
                      ),
                    ),
                    if (isSaved)
                      Text(
                        'Đã sub',
                        style: TextStyle(
                          color: accent,
                          fontSize: 8,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
