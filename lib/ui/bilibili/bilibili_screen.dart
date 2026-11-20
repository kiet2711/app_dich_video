import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/repository/history_repository.dart';
import '../../data/repository/settings_repository.dart';
import '../../domain/ai/live/live_reply_title_sync.dart';
import '../../domain/ai/offline_mlkit_translator.dart';
import '../../domain/media/bilibili_resolver.dart';
import '../../player/global_player_manager.dart';
import '../../data/model/watch_later_item.dart';
import '../../data/repository/watch_later_repository.dart';
import '../theme/app_theme.dart';
import 'bilibili_account_sheet.dart';
import 'bilibili_assistant_controller.dart';
import 'bilibili_assistant_sheet.dart';
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
  late final BilibiliAssistantController _assistantController;
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

  static const List<({String label, String query})> _aiTags = [
    // Định dạng nội dung AI
    (label: 'Phim AI', query: 'AI漫剧'),
    (label: 'Đoản kịch AI', query: 'AI短剧'),
    (label: 'Hoạt hình AI', query: 'AI动画'),
    (label: 'Truyện tranh động', query: '动态漫'),
    (label: 'Xem trọn bộ', query: '一口气看完'),

    // Trọng sinh & Nghịch tập & Sảng văn
    (label: 'Trọng sinh học đường', query: '重生回到高中时代'),
    (label: 'Trọng sinh nghịch tập', query: '重生逆袭'),
    (label: 'Vô địch lưu', query: '无敌流'),
    (label: 'Phản đòn cực đã', query: '打脸爽文'),
    (label: 'Thiên kim thật giả', query: '真假千金'),

    // Hệ thống & Đô thị & Thần hào
    (label: 'Hệ thống lưu', query: '系统流'),
    (label: 'Thần hào / Tiêu tiền', query: '神豪系统'),
    (label: 'Đô thị chiến thần', query: '都市战神'),
    (label: 'Đô thị dị năng', query: '都市异能'),

    // Tu tiên & Huyền huyễn
    (label: 'Tu tiên nghịch tập', query: '修仙逆袭'),
    (label: 'Phàm nhân tu tiên', query: '凡人修仙'),
    (label: 'Linh khí khôi phục', query: '灵气复苏'),
    (label: 'Cao võ kỷ nguyên', query: '高武纪元'),
    (label: 'Huyền huyễn não động', query: '玄幻脑洞'),

    // Xuyên không & Cổ đại
    (label: 'Xuyên không', query: '穿越'),
    (label: 'Xuyên không cổ đại', query: '穿越古代'),
    (label: 'Cung đấu / Trạch đấu', query: '宫斗宅斗'),

    // Mạt thế & Sinh tồn & Kinh dị
    (label: 'Mạt thế sinh tồn', query: '末日求生'),
    (label: 'Quy tắc quái đàm', query: '规则怪谈'),
    (label: 'Vô hạn lưu', query: '无限流'),

    // Khoa học viễn tưởng & Cyber
    (label: 'Khoa học viễn tưởng', query: '科幻AI'),
    (label: 'Cyberpunk tương lai', query: '赛博朋克'),
    (label: 'Võng du / Game thủ', query: '网游'),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _assistantController = BilibiliAssistantController(resolver: _resolver);
    unawaited(_assistantController.initialize());
    _loadInitialState();
  }

  Future<void> _loadInitialState() async {
    final sp = await SharedPreferences.getInstance();
    final settings = await SettingsRepository.getInstance();
    if (!mounted) return;
    final cookie = settings.bilibiliSessData;
    _assistantController.updateCookie(cookie);
    setState(() {
      _isTranslateEnabled = sp.getBool('bilibili_translate_enabled') ?? true;
      _bilibiliCookie = cookie;
    });

    if (cookie.isNotEmpty) {
      _fetchProfile(cookie);
    }
    BilibiliResolver.warmUpWbi(cookie);

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
        _hasMoreAi = items.length >= 5;
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
  Future<void> _playVideo(
    BilibiliAnimeItem item, {
    int overrideInitialPositionMs = 0,
  }) async {
    final playUrl = item.targetPlayUrl;
    if (playUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không tìm thấy link phát cho video này.')),
      );
      return;
    }

    int initialPositionMs = overrideInitialPositionMs;
    try {
      final repo = await HistoryRepository.getInstance();
      final historyItem = repo.getHistory().where((h) {
        if (h.videoPath == playUrl) return true;
        final bvid = item.bvid;
        if (bvid != null && bvid.isNotEmpty && (h.videoPath.contains(bvid) || h.id.contains(bvid))) {
          return true;
        }
        return false;
      }).firstOrNull;
      if (historyItem != null && historyItem.lastPositionMs > 0) {
        if (historyItem.durationMs <= 0 || historyItem.lastPositionMs < historyItem.durationMs * 0.95) {
          if (historyItem.lastPositionMs > initialPositionMs) {
            initialPositionMs = historyItem.lastPositionMs;
          }
        }
      }
    } catch (_) {}

    if (widget.onOpenVideo != null) {
      widget.onOpenVideo!(playUrl, item.title);
    } else {
      GlobalPlayerManager.instance.openPlayer(
        videoPath: playUrl,
        title: item.title,
        coverUrl: item.cover,
        author: item.author,
        bilibiliItem: item,
        initialPositionMs: initialPositionMs,
      );
    }
  }

  void _showItemMoreOptions(BilibiliAnimeItem item) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.bilibili);
    final secondary = palette.secondaryFor(AppTabId.bilibili);

    showModalBottomSheet(
      context: context,
      backgroundColor: palette.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        final bvid = item.bvid ?? '';
        final isWl = bvid.isNotEmpty &&
            WatchLaterRepository.watchLaterNotifier.value.any(
                (w) => w.targetUrl.contains(bvid) || w.id.contains(bvid));
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
                          color: accent,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'UP',
                          style: TextStyle(
                            color: palette.onColor(accent),
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          item.author.isNotEmpty ? item.author : 'Bilibili Video',
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (item.durationText.isNotEmpty)
                        Text(
                          item.durationText,
                          style: TextStyle(color: palette.textMuted, fontSize: 12),
                        ),
                    ],
                  ),
                ),
                Divider(color: palette.border),
                ListTile(
                  leading: Icon(Icons.play_circle_fill_rounded, color: secondary),
                  title: Text('Xem video ngay', style: TextStyle(color: palette.textPrimary, fontSize: 14)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _playVideo(item);
                  },
                ),
                ListTile(
                  leading: Icon(Icons.translate_rounded, color: accent),
                  title: Text(
                    _manualTranslationCache.containsKey(item.title) ? 'Xem tiêu đề Tiếng Trung gốc' : 'Dịch tiêu đề sang Tiếng Việt',
                    style: TextStyle(color: palette.textPrimary, fontSize: 14),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _toggleSingleItemTranslation(item.title);
                  },
                ),
                ListTile(
                  leading: Icon(
                    isWl ? Icons.bookmark_added_rounded : Icons.bookmark_add_outlined,
                    color: secondary,
                  ),
                  title: Text(
                    isWl ? 'Xóa khỏi danh sách xem sau' : 'Thêm vào danh sách xem sau',
                    style: TextStyle(color: palette.textPrimary, fontSize: 14),
                  ),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final repo = await WatchLaterRepository.getInstance();
                    final added = await repo.toggleWatchLater(WatchLaterItem(
                      id: 'bili_${bvid.isNotEmpty ? bvid : item.title.hashCode}',
                      title: item.title,
                      coverUrl: item.cover,
                      source: 'bilibili',
                      targetUrl: item.targetPlayUrl,
                      author: item.author,
                      addedAt: DateTime.now().millisecondsSinceEpoch,
                    ));
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Row(
                          children: [
                            Icon(
                              added ? Icons.bookmark_added_rounded : Icons.bookmark_remove_rounded,
                              color: added ? secondary : Colors.orangeAccent,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                added
                                    ? '🔖 Đã thêm "${item.title}" vào danh sách Xem sau'
                                    : '🗑️ Đã xóa "${item.title}" khỏi danh sách Xem sau',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        duration: const Duration(seconds: 2),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: Icon(Icons.copy_rounded, color: palette.textSecondary),
                  title: Text('Sao chép tiêu đề', style: TextStyle(color: palette.textPrimary, fontSize: 14)),
                  onTap: () {
                    Navigator.pop(ctx);
                    Clipboard.setData(ClipboardData(text: item.title));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Đã sao chép tiêu đề!'), duration: Duration(seconds: 1)),
                    );
                  },
                ),
                ListTile(
                  leading: Icon(Icons.link_rounded, color: palette.textSecondary),
                  title: Text('Sao chép link Bilibili', style: TextStyle(color: palette.textPrimary, fontSize: 14)),
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
    _assistantController.dispose();
    _tabController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _applyAssistantResults(List<BilibiliAnimeItem> items, String label) {
    if (!mounted) return;
    setState(() {
      _hasSearched = true;
      _isLoadingSearch = false;
      _lastSearchKeyword = label.trim().isEmpty ? 'Trợ lý AI' : label.trim();
      _searchController.text = _lastSearchKeyword;
      _searchResults = items;
    });
  }

  void _openAssistantSheet() {
    var sheetOpen = true;
    BilibiliAssistantSheet.show(
      context,
      controller: _assistantController,
      onOpenVideo: (item) {
        if (sheetOpen && mounted) {
          sheetOpen = false;
          Navigator.of(context).pop();
        }
        unawaited(_playVideo(item));
      },
      onApplyToMainGrid: _applyAssistantResults,
    ).whenComplete(() {
      sheetOpen = false;
    });
  }

  Widget _buildAssistantFloatingButton() {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.bilibili);
    final secondary = palette.secondaryFor(AppTabId.bilibili);

    return AnimatedBuilder(
      animation: _assistantController,
      builder: (context, _) {
        final state = _assistantController.connectionState;
        final isBusy = _assistantController.isAssistantBusy;
        final isMic = _assistantController.isMicActive;
        final Color statusColor;
        if (isMic) {
          statusColor = const Color(0xFFEF4444);
        } else if (state == AssistantConnectionState.ready) {
          statusColor = AppColors.primaryEmerald;
        } else if (state == AssistantConnectionState.connecting) {
          statusColor = AppColors.accentGold;
        } else if (state == AssistantConnectionState.error) {
          statusColor = const Color(0xFFEF4444);
        } else {
          statusColor = Colors.white54;
        }

        return Material(
          color: Colors.transparent,
          elevation: 8,
          borderRadius: BorderRadius.circular(28),
          child: InkWell(
            onTap: _openAssistantSheet,
            borderRadius: BorderRadius.circular(28),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [accent, secondary],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.34),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isBusy)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  else
                    Icon(
                      isMic ? Icons.mic_rounded : Icons.auto_awesome_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  const SizedBox(width: 8),
                  Text(
                    isMic ? 'Đang nghe...' : 'Trợ lý AI',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.2),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppTabBackdrop(
      tab: AppTabId.bilibili,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  _buildHeaderSection(),

                  if (_hasSearched) ...[
                    _buildSearchResultHeader(),
                    Expanded(child: _buildSearchResultList()),
                  ] else ...[
                    _buildTabBar(),
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
              Positioned(
                right: 16,
                bottom: 12,
                child: _buildAssistantFloatingButton(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _refreshAccountFromStorage() async {
    final settings = await SettingsRepository.getInstance();
    if (!mounted) return;
    final cookie = settings.bilibiliSessData;
    setState(() {
      _bilibiliCookie = cookie;
      if (cookie.isEmpty) {
        _userProfile = null;
      }
    });
    _assistantController.updateCookie(cookie);
    if (cookie.isNotEmpty) {
      _fetchProfile(cookie);
    }
  }

  // =================== HEADER SECTION ===================
  Widget _buildHeaderSection() {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.bilibili);
    final onAccent = palette.onColor(accent);
    final avatar = _userProfile?.avatar ?? '';
    final isLogin = _userProfile?.isLogin ?? false;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // User Avatar on Left
              Tooltip(
                message: isLogin
                    ? 'Tài khoản Bilibili (${_userProfile?.uname ?? "Đã đăng nhập"})'
                    : 'Đăng nhập & Lịch sử Bilibili',
                child: InkWell(
                  onTap: () async {
                    await BilibiliAccountSheet.show(
                      context,
                      translateTitles: _isTranslateEnabled,
                      onAccountChanged: () => unawaited(_refreshAccountFromStorage()),
                      onOpenVideo: (entry) => _playVideo(
                        entry.item,
                        overrideInitialPositionMs: entry.resumePositionMs,
                      ),
                    );
                    await _refreshAccountFromStorage();
                  },
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: palette.surface,
                      border: Border.all(
                        color: isLogin ? accent : palette.border,
                        width: 1.5,
                      ),
                      boxShadow: palette.cardShadows,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: avatar.isNotEmpty
                        ? Image.network(
                            avatar,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Icon(
                              Icons.account_circle_rounded,
                              color: palette.textSecondary,
                              size: 32,
                            ),
                          )
                        : Icon(
                            Icons.account_circle_rounded,
                            color: palette.textSecondary,
                            size: 32,
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 8),

              // Rounded Search Pill kiểu Bilibili gốc
              Expanded(
                child: Container(
                  height: 38,
                  decoration: BoxDecoration(
                    color: palette.surface,
                    borderRadius: BorderRadius.circular(19),
                    border: Border.all(color: palette.border),
                    boxShadow: palette.cardShadows,
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Icon(Icons.search_rounded, color: accent, size: 18),
                      const SizedBox(width: 6),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          style: TextStyle(color: palette.textPrimary, fontSize: 13),
                          decoration: InputDecoration(
                            hintText: 'Tìm video Bilibili (hỗ trợ tiếng Việt)',
                            hintStyle: TextStyle(color: palette.textMuted, fontSize: 12),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                          onSubmitted: (val) => _executeSearch(),
                        ),
                      ),
                      if (_searchController.text.isNotEmpty)
                        IconButton(
                          icon: Icon(Icons.clear_rounded, size: 16, color: palette.textMuted),
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
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: const BorderRadius.horizontal(right: Radius.circular(19)),
                          ),
                          child: Text(
                            'Tìm',
                            style: TextStyle(
                              color: onAccent,
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
              const SizedBox(width: 4),

              // Translation toggle button
              IconButton(
                onPressed: _toggleTranslateEnabled,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                tooltip: _isTranslateEnabled ? 'Dịch tiêu đề: Đang BẬT' : 'Dịch tiêu đề: Đang TẮT',
                icon: Icon(
                  _isTranslateEnabled ? Icons.translate_rounded : Icons.translate_outlined,
                  color: _isTranslateEnabled ? accent : palette.textMuted,
                  size: 21,
                ),
              ),

              // Dedicated Settings button on right
              IconButton(
                onPressed: () => BilibiliSettingsSheet.show(context),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                tooltip: 'Cài đặt Bilibili',
                icon: Icon(
                  Icons.settings_rounded,
                  color: palette.textSecondary,
                  size: 21,
                ),
              ),
            ],
          ),

          if (_hotKeywords.isNotEmpty && !_hasSearched) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 26,
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
                    borderRadius: BorderRadius.circular(13),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: palette.surfaceAlt,
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(color: palette.border),
                      ),
                      child: FutureBuilder<String>(
                        future: OfflineMlKitTranslator.translateHongguoTitle(kw),
                        initialData: kw,
                        builder: (context, snapshot) {
                          return Text(
                            snapshot.data ?? kw,
                            style: TextStyle(color: palette.textSecondary, fontSize: 11),
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
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.bilibili);

    return Container(
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: TabBar(
        controller: _tabController,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        dividerColor: Colors.transparent,
        labelPadding: const EdgeInsets.symmetric(horizontal: 16),
        indicatorColor: accent,
        indicatorWeight: 3,
        indicatorSize: TabBarIndicatorSize.label,
        labelColor: accent,
        unselectedLabelColor: palette.textSecondary,
        labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
        unselectedLabelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
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
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.bilibili);
    final onAccent = palette.onColor(accent);

    if (_isLoadingRecommend) {
      return Center(child: CircularProgressIndicator(color: accent));
    }
    if (_recommendList.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off_rounded, size: 48, color: palette.textMuted),
            const SizedBox(height: 12),
            Text('Chưa có gợi ý video nào', style: TextStyle(color: palette.textSecondary)),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => _fetchRecommend(refresh: true),
              style: ElevatedButton.styleFrom(backgroundColor: accent, foregroundColor: onAccent),
              child: const Text('Thử lại'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      color: accent,
      backgroundColor: palette.surface,
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
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                12,
                10,
                12,
                palette.bottomContentPadding(extra: 16),
              ),
              sliver: SliverGrid(
                gridDelegate: _buildVideoGridDelegate(context),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildVideoCard(_recommendList[index]),
                  childCount: _recommendList.length,
                ),
              ),
            ),

            if (_isLoadingMoreRecommend)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: CircularProgressIndicator(color: accent, strokeWidth: 2.5),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  SliverGridDelegateWithFixedCrossAxisCount _buildVideoGridDelegate(
    BuildContext context,
  ) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final cardWidth = ((screenWidth - 34) / 2).clamp(120.0, 400.0);
    final thumbHeight = cardWidth * (9.5 / 16);
    final textScale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.35);
    final infoHeight = 50.0 * textScale + 18.0;
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 2,
      mainAxisExtent: thumbHeight + infoHeight,
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
    );
  }

  // =================== TAB 2: AI 漫剧 (PHIM AI) ===================
  Widget _buildAiTab() {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.bilibili);

    return Column(
      children: [
        _buildAiFilterBar(),

        Expanded(
          child: _isLoadingAi
              ? Center(child: CircularProgressIndicator(color: accent))
              : _aiList.isEmpty
                  ? Center(
                      child: Text(
                        'Không tìm thấy phim AI nào',
                        style: TextStyle(color: palette.textSecondary),
                      ),
                    )
                  : RefreshIndicator(
                      color: accent,
                      backgroundColor: palette.surface,
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
                          padding: EdgeInsets.fromLTRB(
                            12,
                            10,
                            12,
                            palette.bottomContentPadding(extra: 16),
                          ),
                          gridDelegate: _buildVideoGridDelegate(context),
                          itemCount: _aiList.length + (_isLoadingMoreAi ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index >= _aiList.length) {
                              return Center(
                                child: CircularProgressIndicator(color: accent),
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
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.bilibili);
    final onAccent = palette.onColor(accent);

    return Container(
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        children: [
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
          const SizedBox(height: 8),

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
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
                    decoration: BoxDecoration(
                      color: isSel ? accent : palette.surfaceAlt,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: isSel ? accent : palette.border),
                    ),
                    child: Text(
                      tag.label,
                      style: TextStyle(
                        color: isSel ? onAccent : palette.textSecondary,
                        fontSize: 11,
                        fontWeight: isSel ? FontWeight.bold : FontWeight.w500,
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
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.bilibili);

    return InkWell(
      onTap: onSelect,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? accent.withValues(alpha: 0.14) : palette.surfaceAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? accent : palette.border,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? accent : palette.textSecondary,
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  // =================== TAB 3: 热门 (POPULAR) ===================
  Widget _buildPopularTab() {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.bilibili);

    if (_isLoadingPopular) {
      return Center(child: CircularProgressIndicator(color: accent));
    }
    return RefreshIndicator(
      color: accent,
      backgroundColor: palette.surface,
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
          padding: EdgeInsets.fromLTRB(
            12,
            10,
            12,
            palette.bottomContentPadding(extra: 16),
          ),
          gridDelegate: _buildVideoGridDelegate(context),
          itemCount: _popularList.length + (_isLoadingMorePopular ? 1 : 0),
          itemBuilder: (context, index) {
            if (index >= _popularList.length) {
              return Center(
                child: CircularProgressIndicator(color: accent),
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
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.bilibili);

    if (_isLoadingComic) {
      return Center(child: CircularProgressIndicator(color: accent));
    }
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: palette.surface,
            border: Border(bottom: BorderSide(color: palette.border)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
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
            color: accent,
            backgroundColor: palette.surface,
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
                padding: EdgeInsets.fromLTRB(
                  12,
                  10,
                  12,
                  palette.bottomContentPadding(extra: 16),
                ),
                gridDelegate: _buildVideoGridDelegate(context),
                itemCount: _comicList.length + (_isLoadingMoreComic ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index >= _comicList.length) {
                    return Center(
                      child: CircularProgressIndicator(color: accent),
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
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.bilibili);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Kết quả tìm kiếm cho "$_lastSearchKeyword" (${_searchResults.length} video)',
              style: TextStyle(
                color: palette.textPrimary,
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
            child: Text('Đóng', style: TextStyle(color: accent, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResultList() {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.bilibili);

    if (_isLoadingSearch) {
      return Center(child: CircularProgressIndicator(color: accent));
    }
    if (_searchResults.isEmpty) {
      return Center(
        child: Text(
          'Không tìm thấy video nào phù hợp.',
          style: TextStyle(color: palette.textSecondary),
        ),
      );
    }

    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
        12,
        10,
        12,
        palette.bottomContentPadding(extra: 16),
      ),
      gridDelegate: _buildVideoGridDelegate(context),
      itemCount: _searchResults.length,
      itemBuilder: (ctx, idx) => _buildVideoCard(_searchResults[idx]),
    );
  }

  // =================== VIDEO CARD (BILIBILI CLEAN 16:10 GRID) ===================
  Widget _buildVideoCard(BilibiliAnimeItem item) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.bilibili);

    return InkWell(
      onTap: () => _playVideo(item),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: palette.border),
          boxShadow: palette.cardShadows,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9.5,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (item.cover.isNotEmpty)
                    Image.network(
                      item.cover,
                      cacheWidth: 360,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        color: palette.surfaceAlt,
                        child: Icon(Icons.movie_rounded, color: palette.textMuted),
                      ),
                    )
                  else
                    Container(
                      color: palette.surfaceAlt,
                      child: Icon(Icons.movie_rounded, color: palette.textMuted),
                    ),

                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.8),
                          ],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                      ),
                    ),
                  ),

                  Positioned(
                    left: 6,
                    right: 6,
                    bottom: 4,
                    child: Row(
                      children: [
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

            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(9, 7, 8, 7),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildTitleText(item.title),

                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: accent.withValues(alpha: 0.55),
                              width: 0.8,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'UP',
                            style: TextStyle(
                              color: accent,
                              fontSize: 8,
                              fontWeight: FontWeight.bold,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),

                        Expanded(
                          child: _buildUpName(item.author),
                        ),

                        InkWell(
                          onTap: () => _showItemMoreOptions(item),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: Icon(
                              Icons.more_vert_rounded,
                              size: 15,
                              color: palette.textMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // =================== TITLE TRANSLATION HELPER ===================
  Widget _buildTitleText(String originalTitle) {
    final palette = AppThemePalette.of(context);
    final style = TextStyle(
      color: palette.textPrimary,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      height: 1.25,
    );

    if (_manualTranslationCache.containsKey(originalTitle)) {
      return Text(
        _manualTranslationCache[originalTitle]!,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }

    if (!_isTranslateEnabled) {
      return Text(
        originalTitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: style,
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
          style: style,
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
    final palette = AppThemePalette.of(context);
    final style = TextStyle(color: palette.textMuted, fontSize: 11);
    final clean = author.trim();
    if (clean.isEmpty) {
      return Text(
        'Bilibili UP',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    if (!_isTranslateEnabled) {
      return Text(
        clean,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
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
          style: style,
        );
      },
    );
  }
}
