import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/model/history_item.dart';
import '../../data/model/subtitle_document.dart';
import '../../data/repository/history_repository.dart';
import '../../domain/media/hongguo_resolver.dart';
import '../player/video_player_screen.dart';
import '../settings/settings_screen.dart';
import '../theme/app_theme.dart';
import 'import_subtitle_dialog.dart';

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

  /// Tập được xem hoặc tương tác gần đây nhất
  HistoryItem get latestWatchedEpisode {
    final sorted = List<HistoryItem>.from(episodes)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return sorted.first;
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
        sortTimestamp = dramaGroup!.latestWatchedEpisode.timestamp;

  HistoryDisplayItem.single(this.singleItem)
      : isDramaGroup = false,
        dramaGroup = null,
        sortTimestamp = singleItem!.timestamp;
}

class HistoryScreen extends StatefulWidget {
  final void Function(String videoPath, SubtitleDocument doc)? onOpenInTts;

  const HistoryScreen({super.key, this.onOpenInTts});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  HistoryRepository? _historyRepo;
  final HongguoResolver _hongguoResolver = HongguoResolver();

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

  /// Gom nhóm các tập phim bộ lại thành 1 thẻ, giữ nguyên các video đơn lẻ
  List<HistoryDisplayItem> _groupHistoryItems(List<HistoryItem> items) {
    final Map<String, List<HistoryItem>> dramaMap = {};
    final List<HistoryItem> singleItems = [];

    for (final it in items) {
      if (it.isSeriesEpisode) {
        final key = (it.seriesId != null && it.seriesId!.isNotEmpty)
            ? it.seriesId!
            : it.extractedSeriesTitle.toLowerCase().trim();
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

  /// Mở video đơn lẻ thông thường
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

    final resolvedVideo = await HistoryRepository.resolvePath(item.videoPath);

    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (ctx) => VideoPlayerScreen(
            videoPath: resolvedVideo,
            document: doc,
            initialPositionMs: item.lastPositionMs,
            onPlaybackPositionChanged: (positionMs) =>
                repo.updatePlaybackPosition(item.id, positionMs),
          ),
        ),
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
    final resolvedVideo = await HistoryRepository.resolvePath(item.videoPath);
    final epIndex = customEpisodeIndex ?? item.extractedEpisodeIndex;

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

    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => VideoPlayerScreen(
          videoPath: resolvedVideo,
          title: '${group.seriesTitle} - Tập $epIndex',
          document: doc ?? SubtitleDocument(),
          initialPositionMs: item.lastPositionMs,
          dramaDetail: dramaDetail,
          currentEpisodeIndex: epIndex,
          onPlaybackPositionChanged: (positionMs) =>
              repo.updatePlaybackPosition(item.id, positionMs),
        ),
      ),
    );
  }

  /// Mở một tập chưa từng xem trong bộ phim từ bảng chọn tập
  Future<void> _openUnwatchedDramaEpisode(
    int epIndex,
    DramaHistoryGroup group,
    HongguoDramaDetail detail,
  ) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(
        child: CircularProgressIndicator(color: AppTheme.primaryEmerald),
      ),
    );

    try {
      var vid = '';
      if (detail.episodes.isNotEmpty && epIndex <= detail.episodes.length) {
        vid = detail.episodes[epIndex - 1].vid;
      }
      final playUrl = await _hongguoResolver.getEpisodePlayUrl(
        detail.seriesId,
        vid.isNotEmpty ? vid : detail.seriesId,
      );

      if (!mounted) return;
      Navigator.pop(context); // Đóng loading

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (ctx) => VideoPlayerScreen(
            videoPath: playUrl,
            title: '${detail.title} - Tập $epIndex',
            document: SubtitleDocument(),
            dramaDetail: detail,
            currentEpisodeIndex: epIndex,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi tải video Tập $epIndex: $e')),
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
          const SnackBar(
            content: Text('Không tìm thấy tệp phụ đề để lồng tiếng'),
          ),
        );
      }
      return;
    }

    final resolvedVideo = await HistoryRepository.resolvePath(item.videoPath);
    widget.onOpenInTts!(resolvedVideo, doc);
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

  /// Xóa toàn bộ các tập của một bộ phim
  Future<void> _confirmDeleteDramaGroup(DramaHistoryGroup group) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.darkCard,
        title: const Text(
          'Xóa toàn bộ phim',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'Bạn có chắc chắn muốn xóa tất cả ${group.episodes.length} tập của phim "${group.seriesTitle}" không?',
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
            child: const Text(
              'Xóa tất cả tập',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      for (final ep in group.episodes) {
        await _historyRepo?.deleteItem(ep.id);
      }
    }
  }

  Future<void> _confirmClearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.darkCard,
        title: const Text(
          'Xóa toàn bộ lịch sử',
          style: TextStyle(color: Colors.white),
        ),
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
            child: const Text(
              'Xóa tất cả',
              style: TextStyle(color: Colors.white),
            ),
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

  String _formatMs(int ms) {
    if (ms <= 0) return '00:00';
    final d = Duration(milliseconds: ms);
    final min = d.inMinutes;
    final sec = d.inSeconds % 60;
    return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  /// Hiển thị Modal Bottom Sheet chi tiết danh sách các tập của bộ phim
  void _showDramaEpisodesSheet(DramaHistoryGroup group) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return DefaultTabController(
          length: 2,
          child: Container(
            height: MediaQuery.of(context).size.height * 0.82,
            decoration: const BoxDecoration(
              color: Color(0xFF161822),
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                // Header phim
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: (group.seriesCover != null &&
                                group.seriesCover!.isNotEmpty)
                            ? Image.network(
                                group.seriesCover!,
                                width: 56,
                                height: 74,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => Container(
                                  width: 56,
                                  height: 74,
                                  color: AppTheme.darkCard,
                                  child: const Icon(
                                    Icons.movie,
                                    color: Colors.white30,
                                  ),
                                ),
                              )
                            : Container(
                                width: 56,
                                height: 74,
                                color: AppTheme.darkCard,
                                child: const Icon(
                                  Icons.movie,
                                  color: AppTheme.primaryEmerald,
                                ),
                              ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              group.seriesTitle,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 8,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppTheme.primaryEmerald
                                        .withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    'Đã lưu ${group.episodes.length} tập',
                                    style: const TextStyle(
                                      color: AppTheme.primaryEmerald,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                if (group.totalEpisodes > 0)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF252631),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      'Tổng ${group.totalEpisodes} tập',
                                      style: const TextStyle(
                                        color: Colors.white70,
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

                // Tab Bar: "Tập Đã Xem" và "Lướt Tất Cả Tập"
                TabBar(
                  indicatorColor: AppTheme.primaryEmerald,
                  labelColor: AppTheme.primaryEmerald,
                  unselectedLabelColor: Colors.white60,
                  labelStyle: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                  tabs: [
                    Tab(text: 'TẬP ĐÃ LƯU (${group.episodes.length})'),
                    Tab(
                      text: group.totalEpisodes > 0
                          ? 'TẤT CẢ TẬP (${group.totalEpisodes})'
                          : 'TẤT CẢ TẬP',
                    ),
                  ],
                ),
                const Divider(color: Colors.white12, height: 1),

                // Nội dung 2 tab
                Expanded(
                  child: TabBarView(
                    children: [
                      // TAB 1: Danh sách các tập đã lưu trong máy
                      ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: group.episodes.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (ctx, i) {
                          final ep = group.episodes[i];
                          final epNum = ep.extractedEpisodeIndex;
                          final hasVoice =
                              ep.ttsVoice != null && ep.ttsVoice!.isNotEmpty;
                          final posStr = _formatMs(ep.lastPositionMs);
                          final durStr = _formatMs(ep.durationMs);

                          return Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppTheme.darkCard,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: AppTheme.cardBorder),
                            ),
                            child: Row(
                              children: [
                                // Số tập badge
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: AppTheme.primaryEmerald
                                        .withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    '$epNum',
                                    style: const TextStyle(
                                      color: AppTheme.primaryEmerald,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Tập $epNum',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        'Đã xem: $posStr / $durStr  •  ${ep.sentenceCount} câu',
                                        style: const TextStyle(
                                          color: Colors.grey,
                                          fontSize: 11,
                                        ),
                                      ),
                                      if (hasVoice)
                                        Text(
                                          '🎤 ${ep.ttsVoice}',
                                          style: const TextStyle(
                                            color: AppTheme.primaryEmerald,
                                            fontSize: 10,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.play_circle_fill_rounded,
                                    color: AppTheme.primaryEmerald,
                                    size: 32,
                                  ),
                                  tooltip: 'Xem tập $epNum',
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    _openSeriesEpisode(ep, group);
                                  },
                                ),
                                PopupMenuButton<String>(
                                  icon: const Icon(
                                    Icons.more_vert,
                                    color: Colors.white70,
                                    size: 20,
                                  ),
                                  color: const Color(0xFF252631),
                                  onSelected: (val) {
                                    if (val == 'tts') {
                                      Navigator.pop(ctx);
                                      _openInTts(ep);
                                    } else if (val == 'srt') {
                                      _exportSrt(ep);
                                    } else if (val == 'delete') {
                                      _confirmDelete(ep);
                                    }
                                  },
                                  itemBuilder: (_) => [
                                    if (widget.onOpenInTts != null)
                                      const PopupMenuItem(
                                        value: 'tts',
                                        child: Text(
                                          'Lồng tiếng AI',
                                          style: TextStyle(color: Colors.white),
                                        ),
                                      ),
                                    const PopupMenuItem(
                                      value: 'srt',
                                      child: Text(
                                        'Xuất file SRT',
                                        style: TextStyle(color: Colors.white),
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
                            ),
                          );
                        },
                      ),

                      // TAB 2: Lướt tất cả các tập của phim từ Hồng Quả
                      _buildAllDramaEpisodesView(group),
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

  /// Xây dựng Tab 2: Lướt tất cả tập phim từ server Hồng Quả
  Widget _buildAllDramaEpisodesView(DramaHistoryGroup group) {
    if (group.seriesId == null || group.seriesId!.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.search, size: 48, color: Colors.white30),
              const SizedBox(height: 12),
              const Text(
                'Phim này chưa liên kết mã Hồng Quả',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.explore_outlined,
                    color: AppTheme.primaryEmerald),
                label: const Text('Tìm trên Hồng Quả',
                    style: TextStyle(color: Colors.white)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppTheme.cardBorder),
                ),
                onPressed: () {
                  Navigator.pop(context);
                  // Chuyển hướng người dùng sang tab Hồng Quả nếu cần
                },
              ),
            ],
          ),
        ),
      );
    }

    return FutureBuilder<HongguoDramaDetail>(
      future: _hongguoResolver.getDramaDetail(group.seriesId!),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: AppTheme.primaryEmerald),
          );
        }

        if (snapshot.hasError || !snapshot.hasData) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off_rounded,
                    size: 44, color: Colors.white30),
                const SizedBox(height: 10),
                const Text(
                  'Không thể tải danh sách tập từ máy chủ',
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF252631),
                  ),
                  onPressed: () => setState(() {}),
                  child: const Text('Thử lại',
                      style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          );
        }

        final detail = snapshot.data!;
        final total = detail.episodes.isNotEmpty
            ? detail.episodes.length
            : (detail.totalEpisodes > 0 ? detail.totalEpisodes : 1);

        // Tạo tập hợp các tập đã có trong lịch sử để đánh dấu
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
                Navigator.pop(ctx);
                if (isSaved) {
                  final existingItem = group.episodes.firstWhere(
                    (e) => e.extractedEpisodeIndex == epIndex,
                  );
                  _openSeriesEpisode(existingItem, group);
                } else {
                  _openUnwatchedDramaEpisode(epIndex, group, detail);
                }
              },
              borderRadius: BorderRadius.circular(8),
              child: Container(
                decoration: BoxDecoration(
                  color: isSaved
                      ? const Color(0xFF132F24)
                      : const Color(0xFF252631),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isSaved
                        ? AppTheme.primaryEmerald
                        : Colors.white12,
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
                        color: isSaved ? AppTheme.primaryEmerald : Colors.white,
                        fontWeight:
                            isSaved ? FontWeight.bold : FontWeight.normal,
                        fontSize: 13,
                      ),
                    ),
                    if (isSaved)
                      const Text(
                        'Đã sub',
                        style: TextStyle(
                          color: AppTheme.primaryEmerald,
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
            // Banner "Nhập Video & Phụ Đề Có Sẵn"
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
                final displayItems = _groupHistoryItems(items);

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'DANH SÁCH ĐÃ DỊCH (${displayItems.length} MỤC)',
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
                              style:
                                  TextStyle(color: Colors.grey, fontSize: 12),
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

                    if (displayItems.isEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 40),
                        alignment: Alignment.center,
                        child: Column(
                          children: const [
                            Icon(Icons.history,
                                color: Colors.white24, size: 56),
                            SizedBox(height: 12),
                            Text(
                              'Chưa có video nào trong lịch sử',
                              style: TextStyle(
                                  color: Colors.white70, fontSize: 15),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Các video tạo phụ đề xong sẽ hiển thị tại đây để xem lại',
                              style:
                                  TextStyle(color: Colors.grey, fontSize: 12),
                            ),
                          ],
                        ),
                      )
                    else
                      ListView.separated(
                        physics: const NeverScrollableScrollPhysics(),
                        shrinkWrap: true,
                        itemCount: displayItems.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final dItem = displayItems[index];

                          if (dItem.isDramaGroup) {
                            return _buildDramaGroupCard(
                              dItem.dramaGroup!,
                              dateFormatter,
                            );
                          } else {
                            return _buildSingleItemCard(
                              dItem.singleItem!,
                              dateFormatter,
                            );
                          }
                        },
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Card gom nhóm cho Phim Bộ (Hồng Quả / Short Drama)
  Widget _buildDramaGroupCard(
    DramaHistoryGroup group,
    DateFormat dateFormatter,
  ) {
    final latest = group.latestWatchedEpisode;
    final latestEpNum = latest.extractedEpisodeIndex;
    final dateStr = dateFormatter.format(
      DateTime.fromMillisecondsSinceEpoch(latest.timestamp),
    );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.darkCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppTheme.primaryEmerald.withValues(alpha: 0.3),
          width: 1.2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Hàng 1: Poster + Tiêu đề phim bộ + Nút xóa cả bộ
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: (group.seriesCover != null &&
                        group.seriesCover!.isNotEmpty)
                    ? Image.network(
                        group.seriesCover!,
                        width: 52,
                        height: 70,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          width: 52,
                          height: 70,
                          color: const Color(0xFF252631),
                          child: const Icon(Icons.movie, color: Colors.white30),
                        ),
                      )
                    : Container(
                        width: 52,
                        height: 70,
                        decoration: BoxDecoration(
                          color: const Color(0xFF132F24),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.movie_filter_rounded,
                          color: AppTheme.primaryEmerald,
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
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
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
                            color: AppTheme.primaryEmerald
                                .withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            '🎬 Đã lưu ${group.episodes.length} tập',
                            style: const TextStyle(
                              color: AppTheme.primaryEmerald,
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
                            color: const Color(0xFF1E2029),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            'Gần nhất: Tập $latestEpNum',
                            style: const TextStyle(
                              color: AppTheme.accentGold,
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
                      style: const TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                  ],
                ),
              ),
              InkWell(
                onTap: () => _confirmDeleteDramaGroup(group),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.delete_outline,
                      color: Colors.grey, size: 20),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Hàng 2: Nút hành động chính
          Row(
            children: [
              // Nút Xem tiếp tập gần nhất
              Expanded(
                flex: 5,
                child: ElevatedButton.icon(
                  onPressed: () => _openSeriesEpisode(latest, group),
                  icon: const Icon(
                    Icons.play_arrow_rounded,
                    size: 20,
                    color: Colors.black,
                  ),
                  label: Text(
                    'Xem tiếp Tập $latestEpNum',
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryEmerald,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
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
                  icon: const Icon(
                    Icons.list_alt_rounded,
                    size: 18,
                    color: Colors.white,
                  ),
                  label: Text(
                    'Tất cả tập (${group.episodes.length})',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppTheme.cardBorder),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Card video đơn lẻ thông thường (Bilibili, Video máy, v.v.)
  Widget _buildSingleItemCard(
    HistoryItem it,
    DateFormat dateFormatter,
  ) {
    final dateStr = dateFormatter.format(
      DateTime.fromMillisecondsSinceEpoch(it.timestamp),
    );
    final hasVoice = it.ttsVoice != null && it.ttsVoice!.isNotEmpty;

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
                  hasVoice ? '🎤 ${it.ttsVoice}' : 'Chưa lồng tiếng',
                  style: TextStyle(
                    color: hasVoice ? AppTheme.primaryEmerald : Colors.grey,
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
                        side: const BorderSide(color: AppTheme.cardBorder),
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
  }
}
