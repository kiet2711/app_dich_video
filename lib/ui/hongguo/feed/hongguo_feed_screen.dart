import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../data/model/subtitle_document.dart';
import '../../../data/model/watch_later_item.dart';
import '../../../data/repository/watch_later_repository.dart';
import '../../../domain/ai/offline_mlkit_translator.dart';
import '../../../domain/media/hongguo/hongguo_stream_proxy_server.dart';
import '../../../domain/media/hongguo_resolver.dart';
import '../../../player/app_player_controller.dart';
import '../../../player/global_player_manager.dart';
import '../../theme/app_theme.dart';

/// Item dữ liệu cho 1 trang trong Feed
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

/// Màn hình lướt video ngắn Hồng Quả dạng Shorts / TikTok Feed
/// Ứng dụng kiến trúc chuẩn ByteDance (MDL Streaming Proxy + Dual-Player Pool)
/// - Không tải toàn bộ video về máy: Stream và giải mã CENC On-the-fly qua Local Proxy 127.0.0.1
/// - Dual-Player Pool: Nạp sẵn khung hình đầu tiên của tập tiếp theo -> Lướt phát ngay 0ms không xoay tròn.
class HongguoFeedScreen extends StatefulWidget {
  final HongguoDramaDetail? initialDrama;
  final int initialEpisodeIndex;
  final List<HongguoDramaItem>? discoverDramas;

  const HongguoFeedScreen({
    super.key,
    this.initialDrama,
    this.initialEpisodeIndex = 1,
    this.discoverDramas,
  });

  @override
  State<HongguoFeedScreen> createState() => _HongguoFeedScreenState();
}

class _HongguoFeedScreenState extends State<HongguoFeedScreen> {
  final HongguoResolver _resolver = HongguoResolver();
  late final PageController _pageController;

  final List<FeedDramaPageItem> _feedItems = [];
  int _currentIndex = 0;
  bool _isLoadingMore = false;

  // Dual-Player Pool: 2 controller luân phiên (1 Active phát hiện tại, 1 Preload nạp trước tập kế)
  AppPlayerController? _activeController;
  int? _activePageIndex;

  AppPlayerController? _preloadController;
  int? _preloadPageIndex;

  bool _isLoadingVideo = false;
  String? _errorMessage;
  bool _isManuallyPaused = false;
  bool _showPlayPauseAnim = false;

  @override
  void initState() {
    super.initState();
    _buildInitialItems();
    _pageController = PageController(initialPage: _currentIndex);

    // Khởi tạo 2 Player Controller với buffer nhẹ 16MB (chuẩn Shorts/TikTok)
    _activeController = AppPlayerController(bufferSizeMb: 16);
    _preloadController = AppPlayerController(bufferSizeMb: 16);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await HongguoStreamProxyServer.instance.ensureStarted();
      if (!mounted) return;
      await _activatePage(_currentIndex);
      _preloadNextPage(_currentIndex + 1);
    });
  }

  void _buildInitialItems() {
    if (widget.initialDrama != null) {
      final detail = widget.initialDrama!;
      final episodes = detail.episodes;
      final total = episodes.isNotEmpty
          ? episodes.length
          : (detail.totalEpisodes > 0 ? detail.totalEpisodes : 1);

      for (var i = 1; i <= total; i++) {
        final vid = (episodes.isNotEmpty && i <= episodes.length)
            ? episodes[i - 1].vid
            : (i == 1 ? detail.seriesId : '');
        _feedItems.add(
          FeedDramaPageItem(
            detail: detail,
            episodeIndex: i,
            vid: vid,
          ),
        );
      }
      _currentIndex = (widget.initialEpisodeIndex - 1).clamp(0, _feedItems.length - 1);
    } else if (widget.discoverDramas != null && widget.discoverDramas!.isNotEmpty) {
      for (final drama in widget.discoverDramas!) {
        final dummyDetail = HongguoDramaDetail(
          seriesId: drama.seriesId,
          title: drama.title,
          cover: drama.cover,
          intro: drama.intro,
          totalEpisodes: drama.episodeCount,
          tags: drama.tags,
          episodes: [
            for (var i = 0; i < drama.vidList.length; i++)
              HongguoEpisodeItem(
                index: i + 1,
                vid: drama.vidList[i],
                title: 'Tập ${i + 1}',
              ),
          ],
        );
        _feedItems.add(
          FeedDramaPageItem(
            detail: dummyDetail,
            episodeIndex: 1,
            vid: drama.vidList.isNotEmpty ? drama.vidList.first : drama.seriesId,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _activeController?.dispose();
    _preloadController?.dispose();
    _activeController = null;
    _preloadController = null;
    HongguoStreamProxyServer.instance.maintainSessions([]);
    super.dispose();
  }

  /// Kích hoạt và phát video cho trang được chọn
  Future<void> _activatePage(int index) async {
    if (!mounted || index < 0 || index >= _feedItems.length) return;

    // 1. Kiểm tra xem tập này đã được Preload sẵn trong _preloadController chưa
    if (_preloadPageIndex == index && _preloadController != null) {
      // SWAP NGAY LẬP TỨC TRONG 0MS!
      final prevActive = _activeController;
      _activeController = _preloadController;
      _preloadController = prevActive;

      _activePageIndex = index;
      _preloadPageIndex = null;

      _activeController?.player.setPlaylistMode(PlaylistMode.loop);
      _activeController?.player.play();

      setState(() {
        _isLoadingVideo = false;
        _errorMessage = null;
        _isManuallyPaused = false;
      });

      // Tự động gối đầu Preload tập tiếp theo N+1
      _preloadNextPage(index + 1);
      _maintainProxyMemory(index);
      return;
    }

    // 2. Nếu chưa được Preload (Lần đầu mở hoặc nhảy cóc qua Episode Selector)
    _activePageIndex = index;
    setState(() {
      _isLoadingVideo = true;
      _errorMessage = null;
      _isManuallyPaused = false;
    });

    final item = _feedItems[index];

    try {
      await HongguoStreamProxyServer.instance.ensureStarted();
      final streamUrl = HongguoStreamProxyServer.instance.getStreamUrl(
        vid: item.vid,
        seriesId: item.detail.seriesId,
        episodeIndex: item.episodeIndex,
      );

      if (!mounted || _activePageIndex != index) return;

      if (_activeController == null || _activeController!.isDisposed) {
        _activeController = AppPlayerController(bufferSizeMb: 16);
      }

      await _activeController!.switchMedia(
        networkUrl: streamUrl,
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0',
        },
        play: true,
      );

      await _activeController!.player.setPlaylistMode(PlaylistMode.loop);
      await _activeController!.player.play();

      if (mounted && _activePageIndex == index) {
        setState(() {
          _isLoadingVideo = false;
        });
      }

      // Kích hoạt Preload tập N+1 gối đầu
      _preloadNextPage(index + 1);
      _maintainProxyMemory(index);
    } catch (e) {
      debugPrint('[HongguoFeedScreen] Lỗi kích hoạt tập $index: $e');
      if (mounted && _activePageIndex == index) {
        setState(() {
          _isLoadingVideo = false;
          _errorMessage = 'Lỗi phát video: $e';
        });
      }
    }
  }

  /// Nạp trước (Preload) tập kế tiếp vào _preloadController (Standby Player)
  /// Frame đầu tiên được giải mã sẵn và chờ sẵn trên GPU, khi lướt là có hình ngay
  Future<void> _preloadNextPage(int nextIndex) async {
    if (!mounted || nextIndex < 0 || nextIndex >= _feedItems.length) return;
    if (_preloadPageIndex == nextIndex) return; // Đang nạp đúng tập này rồi

    _preloadPageIndex = nextIndex;
    final nextItem = _feedItems[nextIndex];

    try {
      // 1. Máy chủ proxy tải trước 1MB đầu & giải mã Header
      await HongguoStreamProxyServer.instance.preloadStream(
        vid: nextItem.vid,
        seriesId: nextItem.detail.seriesId,
        episodeIndex: nextItem.episodeIndex,
      );

      if (!mounted || _preloadPageIndex != nextIndex) return;

      // 2. Nạp vào Preload Controller và tạm dừng ở khung hình 0
      final streamUrl = HongguoStreamProxyServer.instance.getStreamUrl(
        vid: nextItem.vid,
        seriesId: nextItem.detail.seriesId,
        episodeIndex: nextItem.episodeIndex,
      );

      if (_preloadController == null || _preloadController!.isDisposed) {
        _preloadController = AppPlayerController(bufferSizeMb: 16);
      }

      await _preloadController!.switchMedia(
        networkUrl: streamUrl,
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0',
        },
        play: false, // Chỉ nạp khung hình, KHÔNG phát tiếng
      );
      await _preloadController!.player.pause();

      if (mounted) {
        setState(() {}); // Kích hoạt vẽ khung hình của Preload Player lên PageView
      }
    } catch (e) {
      debugPrint('[HongguoFeedScreen] Preload tập $nextIndex thất bại: $e');
    }
  }

  void _maintainProxyMemory(int currentIndex) {
    final activeVids = <String>[
      _feedItems[currentIndex].vid,
      if (currentIndex > 0) _feedItems[currentIndex - 1].vid,
      if (currentIndex + 1 < _feedItems.length) _feedItems[currentIndex + 1].vid,
    ];
    HongguoStreamProxyServer.instance.maintainSessions(activeVids);
  }

  void _onPageChanged(int index) {
    HapticFeedback.selectionClick();
    _currentIndex = index;
    _activatePage(index);

    // Nếu gần chạm đáy danh sách khám phá, tự nạp thêm phim
    if (widget.initialDrama == null && index >= _feedItems.length - 3 && !_isLoadingMore) {
      _loadMoreDiscoverDramas();
    }
  }

  Future<void> _loadMoreDiscoverDramas() async {
    _isLoadingMore = true;
    try {
      final res = await _resolver.getRandomRecommendations();
      if (!mounted) return;
      final newItems = <FeedDramaPageItem>[];
      for (final drama in res.items) {
        final dummyDetail = HongguoDramaDetail(
          seriesId: drama.seriesId,
          title: drama.title,
          cover: drama.cover,
          intro: drama.intro,
          totalEpisodes: drama.episodeCount,
          tags: drama.tags,
          episodes: [
            for (var i = 0; i < drama.vidList.length; i++)
              HongguoEpisodeItem(
                index: i + 1,
                vid: drama.vidList[i],
                title: 'Tập ${i + 1}',
              ),
          ],
        );
        newItems.add(
          FeedDramaPageItem(
            detail: dummyDetail,
            episodeIndex: 1,
            vid: drama.vidList.isNotEmpty ? drama.vidList.first : drama.seriesId,
          ),
        );
      }
      setState(() {
        _feedItems.addAll(newItems);
        _isLoadingMore = false;
      });
    } catch (_) {
      _isLoadingMore = false;
    }
  }

  void _togglePlayPause() {
    HapticFeedback.lightImpact();
    if (_activeController == null) return;
    if (_activeController!.value.isPlaying) {
      _activeController!.player.pause();
      setState(() {
        _isManuallyPaused = true;
        _showPlayPauseAnim = true;
      });
    } else {
      _activeController!.player.play();
      setState(() {
        _isManuallyPaused = false;
        _showPlayPauseAnim = true;
      });
    }
    Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _showPlayPauseAnim = false);
    });
  }

  /// Mở màn hình dịch chính thức có phụ đề & lồng tiếng AI
  void _openTranslationPlayer(FeedDramaPageItem item) {
    HapticFeedback.mediumImpact();
    _activeController?.player.pause();

    final dramaTitle = OfflineMlKitTranslator.getCachedTitle(item.detail.title) ?? item.detail.title;

    GlobalPlayerManager.instance.openPlayer(
      videoPath: item.vid,
      title: '$dramaTitle - Tập ${item.episodeIndex}',
      document: SubtitleDocument(),
      dramaDetail: item.detail,
      currentEpisodeIndex: item.episodeIndex,
      initialTtsEnabled: true,
    );
  }

  void _showEpisodePicker(HongguoDramaDetail detail) {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _FeedEpisodePickerSheet(
        detail: detail,
        currentIndex: _currentIndex + 1,
        onSelectEpisode: (epIndex) {
          Navigator.pop(ctx);
          final targetPageIndex = epIndex - 1;
          if (targetPageIndex >= 0 && targetPageIndex < _feedItems.length) {
            _pageController.animateToPage(
              targetPageIndex,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
            );
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. PageView lướt video dọc
          PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.vertical,
            physics: const BouncingScrollPhysics(),
            itemCount: _feedItems.length,
            onPageChanged: _onPageChanged,
            itemBuilder: (context, index) {
              final item = _feedItems[index];
              final isCurrent = index == _currentIndex;

              // Xác định Controller nào được gắn cho trang này (Active hay Preload)
              AppPlayerController? boundController;
              if (index == _activePageIndex && _activeController != null) {
                boundController = _activeController;
              } else if (index == _preloadPageIndex && _preloadController != null) {
                boundController = _preloadController;
              }

              return Stack(
                fit: StackFit.expand,
                children: [
                  // Ảnh bìa poster nền mờ
                  if (item.detail.cover.isNotEmpty)
                    Image.network(
                      item.detail.cover,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),

                  // Lớp phủ đen mờ bảo vệ độ tương phản
                  Container(color: Colors.black.withValues(alpha: 0.45)),

                  // Video Player: Hiển thị cả trang hiện tại VÀ trang Preload đang chờ
                  if (boundController != null && (!isCurrent || (!_isLoadingVideo && _errorMessage == null)))
                    Center(
                      child: AspectRatio(
                        aspectRatio: boundController.value.aspectRatio > 0
                            ? boundController.value.aspectRatio
                            : (9 / 16),
                        child: Video(controller: boundController.videoController),
                      ),
                    ),

                  // Vòng xoay nạp video (chỉ hiển thị trong trường hợp hy hữu mạng quá yếu chưa kịp nạp)
                  if (isCurrent && _isLoadingVideo)
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(
                            color: AppColors.primaryEmerald,
                            strokeWidth: 2.5,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Đang kết nối luồng tập ${item.episodeIndex}...',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),

                  // Báo lỗi nếu nạp thất bại
                  if (isCurrent && _errorMessage != null)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 40),
                            const SizedBox(height: 10),
                            Text(
                              _errorMessage!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white70, fontSize: 13),
                            ),
                            const SizedBox(height: 14),
                            ElevatedButton.icon(
                              icon: const Icon(Icons.refresh_rounded, size: 16),
                              label: const Text('Thử lại'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primaryEmerald,
                                foregroundColor: Colors.black,
                              ),
                              onPressed: () => _activatePage(index),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // Vùng chạm màn hình: Chạm để Play/Pause
                  GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _togglePlayPause,
                  ),

                  // Icon Play/Pause động ở giữa màn hình
                  if (_showPlayPauseAnim)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _isManuallyPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                          color: Colors.white,
                          size: 48,
                        ),
                      ),
                    ),

                  // Overlay thông tin và nút bấm
                  _buildOverlayUI(item),
                ],
              );
            },
          ),

          // 2. Nút Back thoát chế độ Feed ở góc trên bên trái
          Positioned(
            top: MediaQuery.of(context).padding.top + 10,
            left: 12,
            child: CircleAvatar(
              backgroundColor: Colors.black.withValues(alpha: 0.5),
              child: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 18),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverlayUI(FeedDramaPageItem item) {
    final title = OfflineMlKitTranslator.getCachedTitle(item.detail.title) ?? item.detail.title;
    final total = item.detail.episodes.isNotEmpty
        ? item.detail.episodes.length
        : (item.detail.totalEpisodes > 0 ? item.detail.totalEpisodes : 1);

    return Positioned.fill(
      child: IgnorePointer(
        ignoring: false,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).padding.bottom + 16,
            left: 16,
            right: 16,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Cột thông tin phim bên trái
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Badge tập
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.primaryEmerald.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'Tập ${item.episodeIndex} / $total',
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),

                    // Tên phim
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        shadows: [Shadow(color: Color(0xCC000000), blurRadius: 4)],
                      ),
                    ),

                    if (item.detail.intro.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        item.detail.intro,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          shadows: [Shadow(color: Color(0xCC000000), blurRadius: 4)],
                        ),
                      ),
                    ],

                    const SizedBox(height: 12),

                    // Nút CTA Dịch Phim Này (Điểm nhấn lớn nhất)
                    ElevatedButton.icon(
                      icon: const Icon(Icons.translate_rounded, size: 18),
                      label: const Text(
                        'Dịch & Lồng Tiếng Phim Này',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryEmerald,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        elevation: 4,
                      ),
                      onPressed: () => _openTranslationPlayer(item),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 12),

              // Cột nút tác vụ bên phải (TikTok style)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Nút Chọn Tập Phim
                  _buildRightActionButton(
                    icon: Icons.format_list_numbered_rounded,
                    label: 'Tập phim',
                    onTap: () => _showEpisodePicker(item.detail),
                  ),
                  const SizedBox(height: 16),

                  // Nút Lưu Xem Sau
                  ValueListenableBuilder<List<WatchLaterItem>>(
                    valueListenable: WatchLaterRepository.watchLaterNotifier,
                    builder: (context, wlList, _) {
                      final isSaved = wlList.any((w) => w.seriesId == item.detail.seriesId);
                      return _buildRightActionButton(
                        icon: isSaved ? Icons.bookmark_added_rounded : Icons.bookmark_add_outlined,
                        iconColor: isSaved ? AppColors.primaryEmerald : Colors.white,
                        label: isSaved ? 'Đã lưu' : 'Xem sau',
                        onTap: () async {
                          HapticFeedback.lightImpact();
                          final repo = await WatchLaterRepository.getInstance();
                          if (isSaved) {
                            await repo.removeItem(item.detail.seriesId);
                          } else {
                            await repo.addItem(
                              WatchLaterItem(
                                id: item.detail.seriesId,
                                title: item.detail.title,
                                coverUrl: item.detail.cover,
                                source: 'hongguo',
                                targetUrl: 'https://hongguoduanju.com/player/${item.detail.seriesId}',
                                seriesId: item.detail.seriesId,
                                totalEpisodes: item.detail.totalEpisodes,
                                addedAt: DateTime.now().millisecondsSinceEpoch,
                              ),
                            );
                          }
                        },
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRightActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color iconColor = Colors.white,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white24, width: 0.5),
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w500,
              shadows: [Shadow(color: Colors.black, blurRadius: 2)],
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom Sheet chọn nhanh tập phim trong Feed
class _FeedEpisodePickerSheet extends StatelessWidget {
  final HongguoDramaDetail detail;
  final int currentIndex;
  final ValueChanged<int> onSelectEpisode;

  const _FeedEpisodePickerSheet({
    required this.detail,
    required this.currentIndex,
    required this.onSelectEpisode,
  });

  @override
  Widget build(BuildContext context) {
    final total = detail.episodes.isNotEmpty
        ? detail.episodes.length
        : (detail.totalEpisodes > 0 ? detail.totalEpisodes : 1);

    return Container(
      height: MediaQuery.of(context).size.height * 0.55,
      decoration: const BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: AppColors.cardBorder)),
      ),
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Danh sách tập ($total tập)',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.cardBorder),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 5,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.1,
              ),
              itemCount: total,
              itemBuilder: (ctx, i) {
                final epIndex = i + 1;
                final isSelected = epIndex == currentIndex;
                return InkWell(
                  onTap: () => onSelectEpisode(epIndex),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppColors.primaryEmerald
                          : AppColors.darkSurfaceVariant,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected ? AppColors.primaryEmerald : AppColors.cardBorder,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$epIndex',
                      style: TextStyle(
                        color: isSelected ? Colors.black : Colors.white,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                        fontSize: 13,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
