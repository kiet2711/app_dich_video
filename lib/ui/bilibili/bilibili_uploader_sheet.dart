import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/repository/settings_repository.dart';
import '../../domain/ai/offline_mlkit_translator.dart';
import '../../domain/media/bilibili_resolver.dart';

class BilibiliUploaderSheet extends StatefulWidget {
  final int mid;
  final String authorName;
  final String? initialAvatar;
  final void Function(BilibiliAnimeItem video) onSelectVideo;

  const BilibiliUploaderSheet({
    super.key,
    required this.mid,
    required this.authorName,
    this.initialAvatar,
    required this.onSelectVideo,
  });

  static Future<void> show({
    required BuildContext context,
    required int mid,
    required String authorName,
    String? initialAvatar,
    required void Function(BilibiliAnimeItem video) onSelectVideo,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => BilibiliUploaderSheet(
        mid: mid,
        authorName: authorName,
        initialAvatar: initialAvatar,
        onSelectVideo: onSelectVideo,
      ),
    );
  }

  @override
  State<BilibiliUploaderSheet> createState() => _BilibiliUploaderSheetState();
}

class _BilibiliUploaderSheetState extends State<BilibiliUploaderSheet> {
  final BilibiliResolver _resolver = BilibiliResolver();
  final ScrollController _scrollController = ScrollController();

  BilibiliUploaderProfile? _profile;
  bool _isFollowing = false;
  bool _isTogglingFollow = false;

  final List<BilibiliAnimeItem> _videos = [];
  bool _isLoadingVideos = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  int _currentPage = 1;
  String _order = 'pubdate'; // pubdate (Mới nhất), click (Xem nhiều)

  @override
  void initState() {
    super.initState();
    _loadProfileAndVideos();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 250 &&
        !_isLoadingMore &&
        _hasMore &&
        !_isLoadingVideos) {
      _loadMoreVideos();
    }
  }

  Future<void> _loadProfileAndVideos() async {
    final settings = await SettingsRepository.getInstance();
    final cookie = settings.bilibiliSessData;

    // Kiểm tra trạng thái đã follow từ local
    final localFollowed = settings.isBilibiliMidFollowed(widget.mid);

    // 1. Tải profile uploader
    BilibiliUploaderProfile? profile;
    if (widget.mid > 0) {
      profile = await _resolver.getUploaderProfile(widget.mid, cookie: cookie);
    }

    if (mounted) {
      setState(() {
        _profile = profile;
        _isFollowing = localFollowed || (profile?.isFollowing ?? false);
      });
    }

    // 2. Tải danh sách video
    await _fetchVideos(page: 1, reset: true);
  }

  Future<void> _fetchVideos({required int page, bool reset = false}) async {
    if (reset) {
      setState(() {
        _isLoadingVideos = true;
        _videos.clear();
        _currentPage = 1;
        _hasMore = true;
      });
    }

    final settings = await SettingsRepository.getInstance();
    final cookie = settings.bilibiliSessData;

    final items = await _resolver.getUploaderVideos(
      widget.mid,
      authorName: widget.authorName,
      page: page,
      pageSize: 30,
      order: _order,
      cookie: cookie,
    );

    if (!mounted) return;
    setState(() {
      if (reset) {
        _videos.addAll(items);
      } else {
        _videos.addAll(items);
      }
      _currentPage = page;
      _isLoadingVideos = false;
      _isLoadingMore = false;
      if (items.length < 20) {
        _hasMore = false;
      }
    });
  }

  Future<void> _loadMoreVideos() async {
    if (_isLoadingMore || !_hasMore) return;
    setState(() => _isLoadingMore = true);
    await _fetchVideos(page: _currentPage + 1);
  }

  Future<void> _toggleFollow() async {
    if (_isTogglingFollow) return;
    setState(() => _isTogglingFollow = true);

    final settings = await SettingsRepository.getInstance();
    final targetFollow = !_isFollowing;

    // Cập nhật giao diện và local settings trước để phản hồi mượt mà
    setState(() {
      _isFollowing = targetFollow;
    });

    if (targetFollow) {
      settings.addBilibiliFollowedMid(widget.mid);
    } else {
      settings.removeBilibiliFollowedMid(widget.mid);
    }

    // Nếu có đăng nhập Bilibili (có SESSDATA), đồng bộ lên tài khoản Bilibili
    if (settings.bilibiliSessData.isNotEmpty && widget.mid > 0) {
      unawaited(
        _resolver.modifyRelation(
          mid: widget.mid,
          follow: targetFollow,
          cookie: settings.bilibiliSessData,
          csrf: settings.bilibiliBiliJct,
        ),
      );
    }

    if (mounted) {
      setState(() => _isTogglingFollow = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            targetFollow
                ? '🎉 Đã đăng ký theo dõi "${widget.authorName}"'
                : 'Đã hủy đăng ký theo dõi',
          ),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          backgroundColor: targetFollow
              ? const Color(0xFFFB7299)
              : const Color(0xFF282B37),
        ),
      );
    }
  }

  void _onOrderChanged(String newOrder) {
    if (_order == newOrder) return;
    setState(() {
      _order = newOrder;
    });
    _fetchVideos(page: 1, reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final avatarUrl = _profile?.face.isNotEmpty == true
        ? _profile!.face
        : (widget.initialAvatar ?? '');
    final name = _profile?.name.isNotEmpty == true
        ? _profile!.name
        : widget.authorName;
    final fansCount = _profile?.fansText.isNotEmpty == true
        ? _profile!.fansText
        : '0';
    final totalVideos = _profile?.videoCount ?? _videos.length;
    final sign = _profile?.sign ?? '';

    return Container(
      height: MediaQuery.of(context).size.height * 0.88,
      decoration: const BoxDecoration(
        color: Color(0xFF14161E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Drag handle
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 8),
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header Uploader Profile
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Avatar
                ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: avatarUrl.isNotEmpty
                      ? Image.network(
                          avatarUrl,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const CircleAvatar(
                            radius: 28,
                            backgroundColor: Color(0xFF282B37),
                            child: Icon(Icons.person, size: 28, color: Colors.white54),
                          ),
                        )
                      : const CircleAvatar(
                          radius: 28,
                          backgroundColor: Color(0xFF282B37),
                          child: Icon(Icons.person, size: 28, color: Colors.white54),
                        ),
                ),
                const SizedBox(width: 14),

                // Name & Stats
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (_profile?.level != null && _profile!.level > 0) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFB7299).withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: const Color(0xFFFB7299).withValues(alpha: 0.6),
                                  width: 0.8,
                                ),
                              ),
                              child: Text(
                                'Lv${_profile!.level}',
                                style: const TextStyle(
                                  color: Color(0xFFFB7299),
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text(
                            '$fansCount người theo dõi',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                          const Text(' • ', style: TextStyle(color: Colors.white38)),
                          Text(
                            '$totalVideos video',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      if (sign.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          sign,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),

                // Nút Đăng ký / Theo dõi (+ 关注)
                InkWell(
                  onTap: _toggleFollow,
                  borderRadius: BorderRadius.circular(20),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: _isFollowing
                          ? Colors.white12
                          : const Color(0xFFFB7299),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _isFollowing
                            ? Colors.white24
                            : const Color(0xFFFB7299),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!_isFollowing) ...[
                          const Icon(Icons.add, color: Colors.white, size: 14),
                          const SizedBox(width: 4),
                        ],
                        Text(
                          _isFollowing ? 'Đã theo dõi' : 'Theo dõi',
                          style: TextStyle(
                            color: _isFollowing ? Colors.white70 : Colors.white,
                            fontSize: 12.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 6),
          const Divider(color: Colors.white12, height: 1),

          // Bộ lọc thứ tự: Mới nhất / Xem nhiều
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Text(
                  'Tất cả video đã đăng',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                _buildOrderFilterChip(
                  label: 'Mới nhất',
                  isSelected: _order == 'pubdate',
                  onTap: () => _onOrderChanged('pubdate'),
                ),
                const SizedBox(width: 8),
                _buildOrderFilterChip(
                  label: 'Xem nhiều',
                  isSelected: _order == 'click',
                  onTap: () => _onOrderChanged('click'),
                ),
              ],
            ),
          ),

          // Danh sách video
          Expanded(
            child: _isLoadingVideos
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFF00AEEC)),
                  )
                : _videos.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: const [
                            Icon(Icons.video_library_outlined, size: 48, color: Colors.white24),
                            SizedBox(height: 12),
                            Text(
                              'Chưa có video nào',
                              style: TextStyle(color: Colors.white54, fontSize: 13),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        itemCount: _videos.length + (_hasMore ? 1 : 0),
                        itemBuilder: (ctx, index) {
                          if (index == _videos.length) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 16),
                              child: Center(
                                child: SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(0xFF00AEEC),
                                  ),
                                ),
                              ),
                            );
                          }
                          final video = _videos[index];
                          return _buildVideoTile(video);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildOrderFilterChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF00AEEC).withValues(alpha: 0.2)
              : Colors.white10,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? const Color(0xFF00AEEC) : Colors.white12,
            width: 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? const Color(0xFF00AEEC) : Colors.white60,
            fontSize: 11.5,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildVideoTile(BilibiliAnimeItem video) {
    return InkWell(
      onTap: () {
        Navigator.pop(context);
        widget.onSelectVideo(video);
      },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Thumbnail 16:9 bo góc kèm thời lượng
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 124,
                height: 70,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (video.cover.isNotEmpty)
                      Image.network(
                        video.cover,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          color: const Color(0xFF282B37),
                          child: const Icon(Icons.movie_rounded, color: Colors.white24),
                        ),
                      )
                    else
                      Container(
                        color: const Color(0xFF282B37),
                        child: const Icon(Icons.movie_rounded, color: Colors.white24),
                      ),
                    if (video.durationText.isNotEmpty)
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            video.durationText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),

            // Tiêu đề & thông số
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  FutureBuilder<String>(
                    future: OfflineMlKitTranslator.translateHongguoTitle(video.title),
                    initialData: video.title,
                    builder: (context, snapshot) {
                      return Text(
                        snapshot.data ?? video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (video.viewCountText.isNotEmpty) ...[
                        const Icon(Icons.play_arrow_outlined, size: 13, color: Colors.white38),
                        const SizedBox(width: 2),
                        Text(
                          video.viewCountText,
                          style: const TextStyle(color: Colors.white38, fontSize: 10.5),
                        ),
                      ],
                      if (video.viewCountText.isNotEmpty && video.danmakuText.isNotEmpty)
                        const Text(' • ', style: TextStyle(color: Colors.white24)),
                      if (video.danmakuText.isNotEmpty) ...[
                        const Icon(Icons.subtitles_outlined, size: 12, color: Colors.white38),
                        const SizedBox(width: 2),
                        Text(
                          '${video.danmakuText} đạn mạc',
                          style: const TextStyle(color: Colors.white38, fontSize: 10.5),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
