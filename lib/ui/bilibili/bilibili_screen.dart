import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/repository/settings_repository.dart';
import '../../domain/ai/offline_mlkit_translator.dart';
import '../../domain/media/bilibili_resolver.dart';
import '../../player/global_player_manager.dart';
import '../theme/app_theme.dart';
import 'bilibili_settings_sheet.dart';

class BilibiliScreen extends StatefulWidget {
  final void Function(String videoUrl, String title)? onOpenVideo;

  const BilibiliScreen({super.key, this.onOpenVideo});

  @override
  State<BilibiliScreen> createState() => _BilibiliScreenState();
}

class _BilibiliScreenState extends State<BilibiliScreen>
    with SingleTickerProviderStateMixin {
  final BilibiliResolver _resolver = BilibiliResolver();
  late TabController _tabController;

  bool _isTranslateEnabled = true;
  String _bilibiliCookie = '';
  BilibiliUserProfile? _userProfile;

  // Search State
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  bool _hasSearched = false;
  String _lastSearchKeyword = '';
  List<BilibiliAnimeItem> _searchResults = [];
  bool _isLoadingSearch = false;
  List<String> _hotKeywords = [];

  // Tab 1: 推荐 (Recommend Feed)
  List<BilibiliAnimeItem> _recommendList = [];
  bool _isLoadingRecommend = true;
  int _recommendFreshIdx = 1;
  bool _isLoadingMoreRecommend = false;

  // Tab 2: AI 漫剧 (AI Manhua & Dramas)
  List<BilibiliAnimeItem> _aiList = [];
  bool _isLoadingAi = true;
  String _aiKeyword = 'AI漫剧';
  String _aiOrder = 'totalrank'; // totalrank, click, pubdate
  int _aiPage = 1;
  bool _hasMoreAi = true;
  bool _isLoadingMoreAi = false;

  // Tab 3: 热门 (Popular Videos)
  List<BilibiliAnimeItem> _popularList = [];
  bool _isLoadingPopular = true;
  int _popularPage = 1;
  bool _hasMorePopular = true;
  bool _isLoadingMorePopular = false;

  // Tab 4: 动态漫 (Motion Comics & Dramas)
  List<BilibiliAnimeItem> _comicList = [];
  bool _isLoadingComic = true;
  String _comicOrder = 'totalrank'; // totalrank, click, pubdate
  int _comicPage = 1;
  bool _hasMoreComic = true;
  bool _isLoadingMoreComic = false;

  // Individual card translation overrides: map item title -> translated text
  final Map<String, String> _manualTranslationCache = {};

  final List<({String label, String query})> _aiTags = [
    (label: 'Phim AI', query: 'AI漫剧'),
    (label: 'Đoản kịch AI', query: 'AI短剧'),
    (label: 'Hoạt hình AI', query: 'AI动画'),
    (label: 'Trọng sinh học đường', query: '重生回到高中时代'),
    (label: 'Tu tiên nghịch tập', query: '修仙逆袭'),
    (label: 'Đô thị chiến thần', query: '都市战神'),
    (label: 'Xuyên không', query: '穿越'),
    (label: 'Khoa học viễn tưởng', query: '科幻AI'),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadInitialState();
  }

  Future<void> _loadInitialState() async {
    final sp = await SharedPreferences.getInstance();
    final settings = await SettingsRepository.getInstance();
    if (!mounted) return;
    final cookie = settings.bilibiliSessData;
    setState(() {
      _isTranslateEnabled = sp.getBool('bilibili_translate_enabled') ?? true;
      _bilibiliCookie = cookie;
    });

    if (cookie.isNotEmpty) {
      _fetchProfile(cookie);
    }

    _fetchRecommend(refresh: true);
    _fetchAi(refresh: true);
    _fetchPopular(refresh: true);
    _fetchComic(refresh: true);
    _fetchHotKeywords();
  }

  Future<void> _fetchProfile(String cookie) async {
    try {
      final profile = await _resolver.getUserProfile(cookie);
      if (!mounted) return;
      setState(() {
        _userProfile = profile;
      });
    } catch (_) {}
  }

  Future<void> _toggleTranslateEnabled() async {
    final newVal = !_isTranslateEnabled;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('bilibili_translate_enabled', newVal);
    if (!mounted) return;
    setState(() {
      _isTranslateEnabled = newVal;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          newVal
              ? '🌐 Đã BẬT tự động dịch tiêu đề sang Tiếng Việt'
              : '🇨🇳 Đã TẮT dịch tiêu đề (hiển thị tiếng Trung gốc)',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // =================== FETCH DATA METHODS ===================

  // 1. Recommend Feed
  Future<void> _fetchRecommend({bool refresh = false}) async {
    if (refresh) {
      _recommendFreshIdx = 1;
    }
    if (!refresh && _isLoadingMoreRecommend) return;

    setState(() {
      if (refresh) _isLoadingRecommend = true;
      if (!refresh) _isLoadingMoreRecommend = true;
    });

    try {
      final items = await _resolver.getRecommendFeed(
        pageSize: 20,
        freshIdx: _recommendFreshIdx,
        cookie: _bilibiliCookie,
      );
      if (!mounted) return;
      setState(() {
        if (refresh) {
          _recommendList = items;
        } else {
          _recommendList.addAll(items);
        }
        _recommendFreshIdx++;
        _isLoadingRecommend = false;
        _isLoadingMoreRecommend = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoadingRecommend = false;
        _isLoadingMoreRecommend = false;
      });
    }
  }

  // 2. AI Manhua / Dramas
  Future<void> _fetchAi({bool refresh = false}) async {
    if (refresh) {
      _aiPage = 1;
      _hasMoreAi = true;
    }
    if (!refresh && _isLoadingMoreAi) return;

    setState(() {
      if (refresh) _isLoadingAi = true;
      if (!refresh) _isLoadingMoreAi = true;
    });

    try {
      final items = await _resolver.getAiManhuaVideos(
        keyword: _aiKeyword,
        page: _aiPage,
        pageSize: 20,
        order: _aiOrder,
        cookie: _bilibiliCookie,
      );
      if (!mounted) return;
      setState(() {
        if (refresh) {
          _aiList = items;
        } else {
          _aiList.addAll(items);
        }
        _hasMoreAi = items.length >= 20;
        _isLoadingAi = false;
        _isLoadingMoreAi = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoadingAi = false;
        _isLoadingMoreAi = false;
      });
    }
  }

  // 3. Popular Videos
  Future<void> _fetchPopular({bool refresh = false}) async {
    if (refresh) {
      _popularPage = 1;
      _hasMorePopular = true;
    }
    if (!refresh && _isLoadingMorePopular) return;

    setState(() {
      if (refresh) _isLoadingPopular = true;
      if (!refresh) _isLoadingMorePopular = true;
    });

    try {
      final items = await _resolver.getPopularVideos(
        page: _popularPage,
        pageSize: 20,
        cookie: _bilibiliCookie,
      );
      if (!mounted) return;
      setState(() {
        if (refresh) {
          _popularList = items;
        } else {
          _popularList.addAll(items);
        }
        _hasMorePopular = items.length >= 20;
        _isLoadingPopular = false;
        _isLoadingMorePopular = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoadingPopular = false;
        _isLoadingMorePopular = false;
      });
    }
  }

  // 4. Motion Comics / 动态漫
  Future<void> _fetchComic({bool refresh = false}) async {
    if (refresh) {
      _comicPage = 1;
      _hasMoreComic = true;
    }
    if (!refresh && _isLoadingMoreComic) return;

    setState(() {
      if (refresh) _isLoadingComic = true;
      if (!refresh) _isLoadingMoreComic = true;
    });

    try {
      final items = await _resolver.searchVideos(
        '动态漫',
        page: _comicPage,
        pageSize: 20,
        order: _comicOrder,
        cookie: _bilibiliCookie,
      );
      if (!mounted) return;
      setState(() {
        if (refresh) {
          _comicList = items;
        } else {
          _comicList.addAll(items);
        }
        _hasMoreComic = items.length >= 20;
        _isLoadingComic = false;
        _isLoadingMoreComic = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoadingComic = false;
        _isLoadingMoreComic = false;
      });
    }
  }

  Future<void> _fetchHotKeywords() async {
    try {
      final keywords = await _resolver.getHotSearchKeywords();
      if (!mounted) return;
      setState(() {
        _hotKeywords = keywords;
      });
    } catch (_) {}
  }

  // =================== SEARCH METHOD ===================
  Future<void> _executeSearch([String? explicitQuery]) async {
    final queryText = (explicitQuery ?? _searchController.text).trim();
    if (queryText.isEmpty) return;

    _searchFocusNode.unfocus();
    setState(() {
      _isLoadingSearch = true;
      _hasSearched = true;
      _lastSearchKeyword = queryText;
    });

    String queryToSearch = queryText;
    try {
      final translatedQuery =
          await OfflineMlKitTranslator.translateSearchQuery(queryText);
      if (translatedQuery.isNotEmpty && translatedQuery != queryText) {
        queryToSearch = translatedQuery;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '🇻🇳➔🇨🇳 Đã dịch tìm kiếm: "$queryText" ➔ "$translatedQuery"',
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (_) {}

    try {
      final results = await _resolver.searchVideos(
        queryToSearch,
        cookie: _bilibiliCookie,
      );
      if (!mounted) return;
      setState(() {
        _searchResults = results;
        _isLoadingSearch = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoadingSearch = false;
      });
    }
  }

  // =================== PLAY VIDEO ===================
  void _playVideo(BilibiliAnimeItem item) {
    final playUrl = item.targetPlayUrl;
    if (playUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không tìm thấy link phát cho video này.')),
      );
      return;
    }

    if (widget.onOpenVideo != null) {
      widget.onOpenVideo!(playUrl, item.title);
    } else {
      GlobalPlayerManager.instance.openPlayer(
        videoPath: playUrl,
        title: item.title,
      );
    }
  }

  void _showItemMoreOptions(BilibiliAnimeItem item) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E202A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFB7299),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('UP', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          item.author.isNotEmpty ? item.author : 'Bilibili Video',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (item.durationText.isNotEmpty)
                        Text(
                          item.durationText,
                          style: const TextStyle(color: Colors.white60, fontSize: 12),
                        ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12),
                ListTile(
                  leading: const Icon(Icons.play_circle_fill_rounded, color: Color(0xFF00AEEC)),
                  title: const Text('Xem video ngay', style: TextStyle(color: Colors.white, fontSize: 14)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _playVideo(item);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.translate_rounded, color: Color(0xFFFB7299)),
                  title: Text(
                    _manualTranslationCache.containsKey(item.title) ? 'Xem tiêu đề Tiếng Trung gốc' : 'Dịch tiêu đề sang Tiếng Việt',
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _toggleSingleItemTranslation(item.title);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.copy_rounded, color: Colors.white70),
                  title: const Text('Sao chép tiêu đề', style: TextStyle(color: Colors.white, fontSize: 14)),
                  onTap: () {
                    Navigator.pop(ctx);
                    Clipboard.setData(ClipboardData(text: item.title));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Đã sao chép tiêu đề!'), duration: Duration(seconds: 1)),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.link_rounded, color: Colors.white70),
                  title: const Text('Sao chép link Bilibili', style: TextStyle(color: Colors.white, fontSize: 14)),
                  onTap: () {
                    Navigator.pop(ctx);
                    Clipboard.setData(ClipboardData(text: item.targetPlayUrl));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Đã sao chép liên kết video!'), duration: Duration(seconds: 1)),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121318),
      body: SafeArea(
        child: Column(
          children: [
            // Top App Bar + Search Bar Header (matching screenshot)
            _buildHeaderSection(),

            if (_hasSearched) ...[
              _buildSearchResultHeader(),
              Expanded(child: _buildSearchResultList()),
            ] else ...[
              // Sub-Tabs Header (推荐, AI 漫剧, 热门, 动态漫)
              _buildTabBar(),

              // Tab Views
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildRecommendTab(),
                    _buildAiTab(),
                    _buildPopularTab(),
                    _buildComicTab(),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // =================== HEADER SECTION ===================
  Widget _buildHeaderSection() {
    final avatar = _userProfile?.avatar ?? '';
    final isLogin = _userProfile?.isLogin ?? false;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      color: const Color(0xFF17181F),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // User Avatar on Left (tap -> opens Bilibili settings/login)
              InkWell(
                onTap: () async {
                  await BilibiliSettingsSheet.show(context);
                  final settings = await SettingsRepository.getInstance();
                  if (mounted) {
                    setState(() {
                      _bilibiliCookie = settings.bilibiliSessData;
                    });
                    if (_bilibiliCookie.isNotEmpty) {
                      _fetchProfile(_bilibiliCookie);
                    }
                  }
                },
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isLogin ? const Color(0xFFFB7299) : Colors.white24,
                      width: 1.5,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: avatar.isNotEmpty
                      ? Image.network(
                          avatar,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.account_circle_rounded,
                            color: Colors.white70,
                            size: 32,
                          ),
                        )
                      : const Icon(
                          Icons.account_circle_rounded,
                          color: Colors.white70,
                          size: 32,
                        ),
                ),
              ),
              const SizedBox(width: 10),

              // Rounded Search Pill (matching screenshot Q 重生回到高中时代)
              Expanded(
                child: Container(
                  height: 38,
                  decoration: BoxDecoration(
                    color: const Color(0xFF232530),
                    borderRadius: BorderRadius.circular(19),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      const Icon(Icons.search_rounded, color: Colors.white60, size: 18),
                      const SizedBox(width: 6),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          decoration: const InputDecoration(
                            hintText: 'Q Trọng sinh học đường / Tìm phim AI...',
                            hintStyle: TextStyle(color: Colors.white38, fontSize: 12.5),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                          onSubmitted: (val) => _executeSearch(),
                        ),
                      ),
                      if (_searchController.text.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 16, color: Colors.white54),
                          onPressed: () {
                            _searchController.clear();
                            setState(() {
                              _hasSearched = false;
                              _searchResults.clear();
                            });
                          },
                        ),
                      InkWell(
                        onTap: () => _executeSearch(),
                        borderRadius: const BorderRadius.horizontal(right: Radius.circular(19)),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            color: Color(0xFFFB7299),
                            borderRadius: BorderRadius.horizontal(right: Radius.circular(19)),
                          ),
                          child: const Text(
                            'Tìm',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),

              // Translation toggle button
              IconButton(
                onPressed: _toggleTranslateEnabled,
                tooltip: _isTranslateEnabled ? 'Dịch tiêu đề: Đang BẬT' : 'Dịch tiêu đề: Đang TẮT',
                icon: Icon(
                  _isTranslateEnabled ? Icons.translate_rounded : Icons.translate_outlined,
                  color: _isTranslateEnabled ? const Color(0xFFFB7299) : Colors.white54,
                  size: 22,
                ),
              ),
            ],
          ),

          // Hot keywords horizontal list (dịch động tự động bằng ML Kit)
          if (_hotKeywords.isNotEmpty && !_hasSearched) ...[
            const SizedBox(height: 6),
            SizedBox(
              height: 24,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _hotKeywords.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (ctx, idx) {
                  final kw = _hotKeywords[idx];
                  return InkWell(
                    onTap: () {
                      _searchController.text = kw;
                      _executeSearch(kw);
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF232530),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: FutureBuilder<String>(
                        future: OfflineMlKitTranslator.translateHongguoTitle(kw),
                        initialData: kw,
                        builder: (context, snapshot) {
                          return Text(
                            snapshot.data ?? kw,
                            style: const TextStyle(color: Colors.white70, fontSize: 11),
                          );
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  // =================== TAB BAR ===================
  Widget _buildTabBar() {
    return Container(
      color: const Color(0xFF17181F),
      child: TabBar(
        controller: _tabController,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        labelPadding: const EdgeInsets.symmetric(horizontal: 16),
        indicatorColor: const Color(0xFFFB7299),
        indicatorWeight: 3,
        indicatorSize: TabBarIndicatorSize.label,
        labelColor: const Color(0xFFFB7299),
        unselectedLabelColor: Colors.white70,
        labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        unselectedLabelStyle: const TextStyle(fontSize: 14),
        tabs: const [
          Tab(text: 'Đề xuất'),
          Tab(text: 'Phim AI'),
          Tab(text: 'Thịnh hành'),
          Tab(text: 'Truyện tranh'),
        ],
      ),
    );
  }

  // =================== TAB 1: 推荐 (RECOMMEND FEED) ===================
  Widget _buildRecommendTab() {
    if (_isLoadingRecommend) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFFFB7299)));
    }
    if (_recommendList.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 48, color: Colors.white38),
            const SizedBox(height: 12),
            const Text('Chưa có gợi ý video nào', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => _fetchRecommend(refresh: true),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFB7299)),
              child: const Text('Thử lại', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      color: const Color(0xFFFB7299),
      backgroundColor: const Color(0xFF1E202A),
      onRefresh: () => _fetchRecommend(refresh: true),
      child: NotificationListener<ScrollNotification>(
        onNotification: (scrollInfo) {
          if (!_isLoadingMoreRecommend &&
              scrollInfo.metrics.pixels >= scrollInfo.metrics.maxScrollExtent - 400) {
            _fetchRecommend(refresh: false);
          }
          return false;
        },
        child: CustomScrollView(
          slivers: [
            // Top Banner matching user screenshot
            SliverToBoxAdapter(
              child: _buildAiBanner(),
            ),

            // Video Cards 2-column Grid
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  childAspectRatio: 0.90,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 10,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildVideoCard(_recommendList[index]),
                  childCount: _recommendList.length,
                ),
              ),
            ),

            if (_isLoadingMoreRecommend)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: CircularProgressIndicator(color: Color(0xFFFB7299), strokeWidth: 2.5),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // Banner styled like screenshot's AI Contest Banner
  Widget _buildAiBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      height: 120,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: const LinearGradient(
          colors: [
            Color(0xFF1F1C38),
            Color(0xFF14243B),
            Color(0xFF0F1E29),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // Background Tech pattern
          Positioned(
            right: -20,
            bottom: -20,
            child: Icon(
              Icons.auto_awesome_motion_rounded,
              size: 140,
              color: Colors.white.withValues(alpha: 0.05),
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFB7299),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'Kho Phim AI',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Bilibili AI Video Feed',
                      style: TextStyle(color: Colors.white60, fontSize: 11),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Phim AI · Truyện Tranh Động · Đoản Kịch',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Xem trọn bộ phim AI 1-2 tiếng mượt mà, dịch Vietsub & lồng tiếng AI',
                  style: TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // =================== TAB 2: AI 漫剧 (PHIM AI) ===================
  Widget _buildAiTab() {
    return Column(
      children: [
        // AI Tag and Sort Filter Chips
        _buildAiFilterBar(),

        Expanded(
          child: _isLoadingAi
              ? const Center(child: CircularProgressIndicator(color: Color(0xFFFB7299)))
              : _aiList.isEmpty
                  ? const Center(
                      child: Text('Không tìm thấy phim AI nào', style: TextStyle(color: Colors.white60)),
                    )
                  : RefreshIndicator(
                      color: const Color(0xFFFB7299),
                      backgroundColor: const Color(0xFF1E202A),
                      onRefresh: () => _fetchAi(refresh: true),
                      child: NotificationListener<ScrollNotification>(
                        onNotification: (scrollInfo) {
                          if (!_isLoadingMoreAi &&
                              _hasMoreAi &&
                              scrollInfo.metrics.pixels >= scrollInfo.metrics.maxScrollExtent - 400) {
                            _aiPage++;
                            _fetchAi(refresh: false);
                          }
                          return false;
                        },
                        child: GridView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            childAspectRatio: 0.90,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 10,
                          ),
                          itemCount: _aiList.length + (_isLoadingMoreAi ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index >= _aiList.length) {
                              return const Center(
                                child: CircularProgressIndicator(color: Color(0xFFFB7299)),
                              );
                            }
                            return _buildVideoCard(_aiList[index]);
                          },
                        ),
                      ),
                    ),
        ),
      ],
    );
  }

  Widget _buildAiFilterBar() {
    return Container(
      color: const Color(0xFF17181F),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Column(
        children: [
          // Order row: Tổng hợp | Xem nhiều | Mới nhất
          Row(
            children: [
              _buildSortChip(label: 'Tổng hợp', orderKey: 'totalrank', isSelected: _aiOrder == 'totalrank', onSelect: () {
                setState(() => _aiOrder = 'totalrank');
                _fetchAi(refresh: true);
              }),
              const SizedBox(width: 8),
              _buildSortChip(label: 'Xem nhiều nhất', orderKey: 'click', isSelected: _aiOrder == 'click', onSelect: () {
                setState(() => _aiOrder = 'click');
                _fetchAi(refresh: true);
              }),
              const SizedBox(width: 8),
              _buildSortChip(label: 'Mới nhất', orderKey: 'pubdate', isSelected: _aiOrder == 'pubdate', onSelect: () {
                setState(() => _aiOrder = 'pubdate');
                _fetchAi(refresh: true);
              }),
            ],
          ),
          const SizedBox(height: 6),

          // Keywords list
          SizedBox(
            height: 28,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _aiTags.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (ctx, idx) {
                final tag = _aiTags[idx];
                final isSel = _aiKeyword == tag.query;
                return InkWell(
                  onTap: () {
                    setState(() => _aiKeyword = tag.query);
                    _fetchAi(refresh: true);
                  },
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: isSel ? const Color(0xFFFB7299) : const Color(0xFF232530),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      tag.label,
                      style: TextStyle(
                        color: isSel ? Colors.white : Colors.white70,
                        fontSize: 11,
                        fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
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

  Widget _buildSortChip({
    required String label,
    required String orderKey,
    required bool isSelected,
    required VoidCallback onSelect,
  }) {
    return InkWell(
      onTap: onSelect,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFB7299).withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? const Color(0xFFFB7299) : Colors.white24,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? const Color(0xFFFB7299) : Colors.white70,
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  // =================== TAB 3: 热门 (POPULAR) ===================
  Widget _buildPopularTab() {
    if (_isLoadingPopular) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFFFB7299)));
    }
    return RefreshIndicator(
      color: const Color(0xFFFB7299),
      backgroundColor: const Color(0xFF1E202A),
      onRefresh: () => _fetchPopular(refresh: true),
      child: NotificationListener<ScrollNotification>(
        onNotification: (scrollInfo) {
          if (!_isLoadingMorePopular &&
              _hasMorePopular &&
              scrollInfo.metrics.pixels >= scrollInfo.metrics.maxScrollExtent - 400) {
            _popularPage++;
            _fetchPopular(refresh: false);
          }
          return false;
        },
        child: GridView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            childAspectRatio: 0.90,
            crossAxisSpacing: 8,
            mainAxisSpacing: 10,
          ),
          itemCount: _popularList.length + (_isLoadingMorePopular ? 1 : 0),
          itemBuilder: (context, index) {
            if (index >= _popularList.length) {
              return const Center(
                child: CircularProgressIndicator(color: Color(0xFFFB7299)),
              );
            }
            return _buildVideoCard(_popularList[index]);
          },
        ),
      ),
    );
  }

  // =================== TAB 4: 动态漫 (COMIC DRAMAS) ===================
  Widget _buildComicTab() {
    if (_isLoadingComic) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFFFB7299)));
    }
    return Column(
      children: [
        Container(
          color: const Color(0xFF17181F),
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: Row(
            children: [
              _buildSortChip(label: 'Tổng hợp', orderKey: 'totalrank', isSelected: _comicOrder == 'totalrank', onSelect: () {
                setState(() => _comicOrder = 'totalrank');
                _fetchComic(refresh: true);
              }),
              const SizedBox(width: 8),
              _buildSortChip(label: 'Xem nhiều nhất', orderKey: 'click', isSelected: _comicOrder == 'click', onSelect: () {
                setState(() => _comicOrder = 'click');
                _fetchComic(refresh: true);
              }),
              const SizedBox(width: 8),
              _buildSortChip(label: 'Mới nhất', orderKey: 'pubdate', isSelected: _comicOrder == 'pubdate', onSelect: () {
                setState(() => _comicOrder = 'pubdate');
                _fetchComic(refresh: true);
              }),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
      color: const Color(0xFFFB7299),
      backgroundColor: const Color(0xFF1E202A),
      onRefresh: () => _fetchComic(refresh: true),
      child: NotificationListener<ScrollNotification>(
        onNotification: (scrollInfo) {
          if (!_isLoadingMoreComic &&
              _hasMoreComic &&
              scrollInfo.metrics.pixels >= scrollInfo.metrics.maxScrollExtent - 400) {
            _comicPage++;
            _fetchComic(refresh: false);
          }
          return false;
        },
        child: GridView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            childAspectRatio: 0.90,
            crossAxisSpacing: 8,
            mainAxisSpacing: 10,
          ),
          itemCount: _comicList.length + (_isLoadingMoreComic ? 1 : 0),
          itemBuilder: (context, index) {
            if (index >= _comicList.length) {
              return const Center(
                child: CircularProgressIndicator(color: Color(0xFFFB7299)),
              );
            }
            return _buildVideoCard(_comicList[index]);
          },
        ),
      ),
    ),
    ),
    ],
    );
  }

  // =================== SEARCH RESULTS ===================
  Widget _buildSearchResultHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: const Color(0xFF17181F),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Kết quả tìm kiếm cho "$_lastSearchKeyword" (${_searchResults.length} video)',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _hasSearched = false;
                _searchResults.clear();
              });
            },
            child: const Text('Đóng', style: TextStyle(color: Color(0xFFFB7299), fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResultList() {
    if (_isLoadingSearch) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFFFB7299)));
    }
    if (_searchResults.isEmpty) {
      return const Center(
        child: Text(
          'Không tìm thấy video nào phù hợp.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.90,
        crossAxisSpacing: 8,
        mainAxisSpacing: 10,
      ),
      itemCount: _searchResults.length,
      itemBuilder: (ctx, idx) => _buildVideoCard(_searchResults[idx]),
    );
  }

  // =================== VIDEO CARD (MATCHING USER SCREENSHOT) ===================
  Widget _buildVideoCard(BilibiliAnimeItem item) {
    return InkWell(
      onTap: () => _playVideo(item),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1E202A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. Thumbnail with Bottom Stats Overlay (16:9)
            AspectRatio(
              aspectRatio: 16 / 9.5,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (item.cover.isNotEmpty)
                    Image.network(
                      item.cover,
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

                  // Gradient Scrim at bottom of image
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.85),
                          ],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                      ),
                    ),
                  ),

                  // Bottom Overlay Stats: [▶ Views] [💬 Danmaku] ... [Duration H:mm:ss]
                  Positioned(
                    left: 6,
                    right: 6,
                    bottom: 4,
                    child: Row(
                      children: [
                        // Play count
                        const Icon(Icons.play_circle_outline_rounded, size: 12, color: Colors.white),
                        const SizedBox(width: 2.5),
                        Text(
                          item.viewCountText.isNotEmpty ? item.viewCountText : '0',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 8),

                        // Danmaku / Comment
                        const Icon(Icons.subtitles_outlined, size: 11, color: Colors.white70),
                        const SizedBox(width: 2),
                        Text(
                          item.danmakuText.isNotEmpty ? item.danmakuText : '-',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 10,
                          ),
                        ),

                        const Spacer(),

                        // Video Duration (e.g. 2:07:07, 1:08:31)
                        if (item.durationText.isNotEmpty)
                          Text(
                            item.durationText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              letterSpacing: -0.2,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // 2. Title & Channel Row
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Title (2 lines max, height 32px vừa vặn 2 dòng)
                  SizedBox(
                    height: 32,
                    child: _buildTitleText(item.title),
                  ),
                  const SizedBox(height: 5),

                  // Channel / UP row with UP badge and 3-dots icon
                  Row(
                    children: [
                      // UP Badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white30, width: 0.8),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: const Text(
                          'UP',
                          style: TextStyle(
                            color: Colors.white60,
                            fontSize: 8,
                            fontWeight: FontWeight.bold,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),

                      // Channel name
                      Expanded(
                        child: _buildUpName(item.author),
                      ),

                      // 3-dots options icon
                      InkWell(
                        onTap: () => _showItemMoreOptions(item),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 2),
                          child: Icon(Icons.more_vert_rounded, size: 15, color: Colors.white38),
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
    );
  }

  // =================== TITLE TRANSLATION HELPER ===================
  Widget _buildTitleText(String originalTitle) {
    if (_manualTranslationCache.containsKey(originalTitle)) {
      return Text(
        _manualTranslationCache[originalTitle]!,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          height: 1.25,
        ),
      );
    }

    if (!_isTranslateEnabled) {
      return Text(
        originalTitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          height: 1.25,
        ),
      );
    }

    return FutureBuilder<String>(
      future: OfflineMlKitTranslator.translateHongguoTitle(originalTitle),
      initialData: originalTitle,
      builder: (context, snapshot) {
        return Text(
          snapshot.data ?? originalTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            height: 1.25,
          ),
        );
      },
    );
  }

  Future<void> _toggleSingleItemTranslation(String title) async {
    if (_manualTranslationCache.containsKey(title)) {
      setState(() {
        _manualTranslationCache.remove(title);
      });
    } else {
      final trans = await OfflineMlKitTranslator.translateHongguoTitle(title);
      if (mounted) {
        setState(() {
          _manualTranslationCache[title] = trans;
        });
      }
    }
  }

  Widget _buildUpName(String author) {
    final clean = author.trim();
    if (clean.isEmpty) {
      return const Text(
        'Bilibili UP',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: Colors.white60, fontSize: 11),
      );
    }
    if (!_isTranslateEnabled) {
      return Text(
        clean,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white60, fontSize: 11),
      );
    }
    return FutureBuilder<String>(
      future: OfflineMlKitTranslator.translateHongguoTitle(clean),
      initialData: clean,
      builder: (context, snapshot) {
        return Text(
          snapshot.data ?? clean,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white60, fontSize: 11),
        );
      },
    );
  }
}
