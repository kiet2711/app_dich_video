import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/model/subtitle_document.dart';
import '../../data/model/watch_later_item.dart';
import '../../data/repository/settings_repository.dart';
import '../../data/repository/watch_later_repository.dart';
import '../../domain/ai/offline_mlkit_translator.dart';
import '../../domain/media/hongguo/hongguo_cloud_account_service.dart';
import '../../domain/media/hongguo/hongguo_discovery_service.dart';
import '../../domain/media/hongguo/hongguo_similar_engine.dart';
import '../../domain/media/hongguo_resolver.dart';
import '../../domain/media/network_header_helper.dart';
import '../../domain/media/video_cache_manager.dart';
import '../../player/global_player_manager.dart';
import '../theme/app_theme.dart';
import 'feed/hongguo_feed_screen.dart';
import 'hongguo_account_sheet.dart';
import 'hongguo_assistant_controller.dart';
import 'hongguo_assistant_sheet.dart';
import 'hongguo_discovery_filter_sheet.dart';
import 'hongguo_related_sheet.dart';
import 'hongguo_settings_sheet.dart';

class HongguoScreen extends StatefulWidget {
  final void Function(String videoUrl, String title, int durationMs)?
      onStartTranslation;

  const HongguoScreen({super.key, this.onStartTranslation});

  @override
  State<HongguoScreen> createState() => _HongguoScreenState();
}

class _HongguoScreenState extends State<HongguoScreen> {
  final HongguoResolver _resolver = HongguoResolver();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  // 3 tab cấp 1 rõ ràng: 'discover' (Đề xuất), 'library' (Kho lọc sâu), 'rank' (BXH)
  String _primaryTab = 'discover';

  // Tab Đề xuất: 'all' (Dành cho bạn - Bookmall Official) hoặc khóa theo 'short_play' / 'comic_series' / 'ai_series'
  String _discoverScope = 'all';

  // Tab Kho lọc sâu: Lọc đa chiều bằng ByteDance landpage API + lưu trang con trỏ tuần tự
  HongguoDiscoverySelection _librarySelection = const HongguoDiscoverySelection(
    genreKind: HongguoGenreKind.realPlay,
    filters: <String, String>{'sort': 'hot_score'},
  );
  final List<HongguoDiscoveryCursor?> _libraryPageCursors = <HongguoDiscoveryCursor?>[null];
  bool _libraryHasMore = false;

  // Tab BXH: 10 bảng xếp hạng chính thức
  String _selectedRankSlug = 'rank/hot-drama';

  // Bộ lọc kho khi Tìm kiếm: null (Tất cả) hoặc HongguoGenreKind
  HongguoGenreKind? _searchScope;

  int _currentPage = 1;
  int _totalPages = 1;

  bool _isLoading = false;
  String? _errorMessage;
  List<HongguoDramaItem> _dramas = [];
  bool _isSearchMode = false;
  String _currentSearchQuery = '';
  bool _isAiResultMode = false;
  String _aiResultLabel = '';
  bool _isTranslationEnabled = true;
  SettingsRepository? _settings;
  late final HongguoAssistantController _assistantController;

  @override
  void initState() {
    super.initState();
    _assistantController = HongguoAssistantController(resolver: _resolver);
    unawaited(_assistantController.initialize());
    unawaited(HongguoCloudAccountService.instance.initialize());
    _loadSettingsAndInitialData();
  }

  Future<void> _loadSettingsAndInitialData() async {
    unawaited(_loadTranslationSetting());
    try {
      final settings = await SettingsRepository.getInstance();
      if (!mounted) return;
      _settings = settings;
      if (settings.hongguoCatalogDiscoveryJson.isNotEmpty) {
        _librarySelection = HongguoDiscoverySelection.fromJsonString(
          settings.hongguoCatalogDiscoveryJson,
        );
      }
    } catch (_) {}
    if (mounted) {
      unawaited(_loadDramas());
    }
  }

  Future<void> _loadTranslationSetting() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final saved = sp.getBool('hongguo_translate_enabled') ?? true;
      if (mounted) {
        setState(() => _isTranslationEnabled = saved);
      }
    } catch (_) {}
  }

  Future<void> _toggleTranslation() async {
    HapticFeedback.lightImpact();
    final newVal = !_isTranslationEnabled;
    setState(() {
      _isTranslationEnabled = newVal;
    });
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool('hongguo_translate_enabled', newVal);
    } catch (_) {}

    if (!mounted) return;
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.hongguo);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              newVal ? Icons.translate_rounded : Icons.translate_outlined,
              color: newVal ? accent : Colors.white70,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                newVal
                    ? 'Đã BẬT dịch tiếng Việt (Tên phim & Giới thiệu)'
                    : 'Đã TẮT dịch (Hiển thị tiếng Trung gốc)',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  void dispose() {
    _assistantController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  HongguoDiscoveryCursor? _discoverScopedCursor;

  void _persistLibrarySelection() {
    _settings?.hongguoCatalogDiscoveryJson = _librarySelection.toJsonString();
  }

  Future<void> _loadDramas({bool resetCursor = false}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _isSearchMode = false;
      _isAiResultMode = false;
      _aiResultLabel = '';
    });

    try {
      if (_primaryTab == 'discover') {
        if (_discoverScope == 'all') {
          if (resetCursor) {
            _discoverScopedCursor = null;
          }
          final items = await HongguoSimilarEngine.instance
              .getPersonalizedDiscoverList(resetCursor: resetCursor);
          if (!mounted) return;
          setState(() {
            _dramas = items;
            _currentPage = 1;
            _totalPages = 1;
            _isLoading = false;
          });
        } else {
          final kind = HongguoGenreKind.fromAny(_discoverScope);
          if (resetCursor) {
            _discoverScopedCursor = null;
          }
          var page = await HongguoDiscoveryService.instance.fetchDiscovery(
            HongguoDiscoverySelection(
              genreKind: kind,
              filters: const <String, String>{'sort': 'hot_score'},
            ),
            cursor: _discoverScopedCursor,
          );
          if (page.items.isEmpty && _discoverScopedCursor != null) {
            _discoverScopedCursor = null;
            page = await HongguoDiscoveryService.instance.fetchDiscovery(
              HongguoDiscoverySelection(
                genreKind: kind,
                filters: const <String, String>{'sort': 'hot_score'},
              ),
            );
          }
          _discoverScopedCursor = page.nextCursor;
          if (!mounted) return;
          setState(() {
            _dramas = page.items;
            _currentPage = 1;
            _totalPages = 1;
            _isLoading = false;
          });
        }
      } else if (_primaryTab == 'library') {
        if (resetCursor) {
          _currentPage = 1;
          _libraryPageCursors
            ..clear()
            ..add(null);
        }
        final pageIdx = (_currentPage - 1).clamp(0, _libraryPageCursors.length - 1);
        final cursor = _libraryPageCursors[pageIdx];
        final pageRes = await HongguoDiscoveryService.instance.fetchDiscovery(
          _librarySelection,
          cursor: cursor,
        );
        if (!mounted) return;
        setState(() {
          _dramas = pageRes.items;
          _libraryHasMore = pageRes.hasMore && pageRes.nextCursor != null;
          if (_libraryHasMore && _libraryPageCursors.length <= _currentPage) {
            _libraryPageCursors.add(pageRes.nextCursor);
          }
          _totalPages = _libraryHasMore ? _currentPage + 1 : _currentPage;
          _isLoading = false;
        });
      } else {
        final res = await _resolver.browseList(
          category: _selectedRankSlug,
          page: _currentPage,
        );
        if (!mounted) return;
        setState(() {
          _dramas = res.items;
          _currentPage = res.currentPage;
          _totalPages = res.totalPages > 0 ? res.totalPages : 1;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Không thể tải danh sách phim: $e';
      });
    }
  }

  Future<void> _loadNextDiscoverBatch() async {
    HapticFeedback.mediumImpact();
    if (_primaryTab != 'discover') {
      setState(() => _primaryTab = 'discover');
    }
    _searchController.clear();
    await _loadDramas(resetCursor: false);
    if (_scrollController.hasClients) {
      unawaited(
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut,
        ),
      );
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Đã nạp thêm ${_dramas.length} phim đề xuất mới!',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _performSearch([String? query]) async {
    final text = (query ?? _searchController.text).trim();
    FocusScope.of(context).unfocus();
    if (text.isEmpty) {
      await _loadDramas(resetCursor: true);
      return;
    }

    if (HongguoResolver.isHongguoUrl(text)) {
      await _resolveAndOpenSharedDrama(text);
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _isSearchMode = true;
      _isAiResultMode = false;
      _aiResultLabel = '';
    });

    var queryToSearch = text;
    if (RegExp(r'[a-zA-ZÀ-ỹ]').hasMatch(text)) {
      try {
        final translatedQuery =
            await OfflineMlKitTranslator.translateSearchQuery(text);
        if (translatedQuery.isNotEmpty && translatedQuery != text) {
          queryToSearch = translatedQuery;
          if (mounted) {
            final accent = AppThemePalette.of(context).accentFor(AppTabId.hongguo);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    Icon(Icons.translate_rounded, color: accent, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Đã dịch tìm kiếm: "$text" ➔ "$translatedQuery"',
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                  ],
                ),
                duration: const Duration(seconds: 3),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        }
      } catch (e) {
        debugPrint('[HongguoSearch] Lỗi dịch từ khóa: $e');
      }
    }

    _currentSearchQuery = queryToSearch;
    await _loadSearchPage(1);
  }

  Future<void> _loadSearchPage(int page) async {
    if (_currentSearchQuery.isEmpty) return;
    if (!_isLoading && mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
        _isSearchMode = true;
        _isAiResultMode = false;
        _aiResultLabel = '';
      });
    }

    try {
      final res = await HongguoDiscoveryService.instance.searchByType(
        _currentSearchQuery,
        genreFilter: _searchScope,
        page: page,
      );
      if (!mounted) return;
      setState(() {
        _dramas = res.items;
        _isLoading = false;
        _currentPage = res.currentPage;
        _totalPages = res.totalPages > 0 ? res.totalPages : 1;
      });
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Lỗi tìm kiếm: $e';
      });
    }
  }

  Future<void> _resolveAndOpenSharedDrama(String input) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final seriesId = await _resolver.resolveSeriesId(input);
      final detail = await _resolver.getDramaDetail(seriesId);
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showEpisodeBottomSheet(detail);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Không phân giải được liên kết Hồng Quả: $e';
      });
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isNotEmpty) {
      HapticFeedback.lightImpact();
      _searchController.text = text;
      await _performSearch(text);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Khay nhớ tạm trống!'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _onSelectPrimaryTab(String tab) {
    if (_primaryTab == tab && !_isSearchMode && !_isAiResultMode) return;
    HapticFeedback.selectionClick();
    setState(() {
      _primaryTab = tab;
      _currentPage = 1;
      _isAiResultMode = false;
      _aiResultLabel = '';
      _isSearchMode = false;
      _searchController.clear();
    });
    _loadDramas(resetCursor: true);
  }

  void _onSelectDiscoverScope(String scope) {
    if (_discoverScope == scope && !_isSearchMode && !_isAiResultMode) return;
    HapticFeedback.selectionClick();
    setState(() {
      _discoverScope = scope;
      _discoverScopedCursor = null;
      _isAiResultMode = false;
      _isSearchMode = false;
    });
    _loadDramas(resetCursor: true);
  }

  void _onSelectLibraryKind(HongguoGenreKind kind) {
    if (_librarySelection.genreKind == kind &&
        !_isSearchMode &&
        !_isAiResultMode) {
      return;
    }
    HapticFeedback.selectionClick();
    setState(() {
      _librarySelection = _librarySelection.withGenreKind(kind);
      _isAiResultMode = false;
      _isSearchMode = false;
    });
    _persistLibrarySelection();
    _loadDramas(resetCursor: true);
  }

  void _toggleQuickLibraryFilter(String axis, String id) {
    HapticFeedback.selectionClick();
    final cur = _librarySelection.valueOf(axis);
    final nextId = axis == 'sort' ? id : (cur == id ? '' : id);
    setState(() {
      _librarySelection = _librarySelection.withFilter(axis, nextId);
      _isAiResultMode = false;
      _isSearchMode = false;
    });
    _persistLibrarySelection();
    _loadDramas(resetCursor: true);
  }

  Future<void> _openLibraryFilterSheet() async {
    final accent = AppThemePalette.of(context).accentFor(AppTabId.hongguo);
    final picked = await HongguoDiscoveryFilterSheet.show(
      context,
      initialSelection: _librarySelection,
      accentColor: accent,
    );
    if (!mounted || picked == null) return;
    setState(() {
      _primaryTab = 'library';
      _librarySelection = picked;
      _isAiResultMode = false;
      _isSearchMode = false;
    });
    _persistLibrarySelection();
    await _loadDramas(resetCursor: true);
  }

  void _onSelectRankBoard(String slug) {
    if (_selectedRankSlug == slug && _primaryTab == 'rank') return;
    HapticFeedback.selectionClick();
    setState(() {
      _primaryTab = 'rank';
      _selectedRankSlug = slug;
      _currentPage = 1;
      _isAiResultMode = false;
      _isSearchMode = false;
    });
    _loadDramas(resetCursor: true);
  }

  void _applyTagFilterFromDetail(String zhTag, HongguoDramaDetail detail) {
    HapticFeedback.mediumImpact();
    final fallbackCat = detail.sourceCategory.isNotEmpty
        ? detail.sourceCategory
        : (_primaryTab == 'library'
            ? _librarySelection.genreKind.categorySlug
            : '');
    final selection = HongguoDiscoveryService.instance.resolveSelectionForTag(
      zhTag,
      preferredSourceCategory: fallbackCat,
      categoryIds: detail.categoryIds,
      allDramaTags: detail.tags,
    );
    setState(() {
      _primaryTab = 'library';
      _librarySelection = selection;
      _isSearchMode = false;
      _isAiResultMode = false;
      _searchController.clear();
    });
    _persistLibrarySelection();
    unawaited(_loadDramas(resetCursor: true));
    final summary = selection.buildSummaryLabel(
      HongguoDiscoveryService.instance.getSelectorGroups(selection.genreKind),
    );
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Đã lọc Kho: $summary'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _goToPage(int page) {
    if (page < 1 || page > _totalPages || page == _currentPage || _isLoading) {
      return;
    }
    HapticFeedback.lightImpact();
    setState(() {
      _currentPage = page;
      _isAiResultMode = false;
      _aiResultLabel = '';
    });
    if (_isSearchMode) {
      _loadSearchPage(page);
    } else {
      _loadDramas(resetCursor: false);
    }
  }

  void _applyAssistantResults(List<HongguoDramaItem> items, String label) {
    if (!mounted || items.isEmpty) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _dramas = items;
      _isLoading = false;
      _errorMessage = null;
      _isSearchMode = false;
      _isAiResultMode = true;
      _aiResultLabel = label;
      _currentPage = 1;
      _totalPages = 1;
    });
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Đã đưa ${items.length} phim gợi ý từ Trợ lý AI ra lưới.'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _openAssistantSheet() {
    HapticFeedback.lightImpact();
    HongguoAssistantSheet.show(
      context,
      controller: _assistantController,
      onOpenDrama: _openDramaDetail,
      onApplyToMainGrid: _applyAssistantResults,
    );
  }

  Future<void> _openDramaDetail(HongguoDramaItem item) async {
    HapticFeedback.lightImpact();
    final accent = AppThemePalette.of(context).accentFor(AppTabId.hongguo);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Center(
        child: CircularProgressIndicator(color: accent),
      ),
    );

    try {
      final effectiveItem = item.sourceCategory.isNotEmpty
          ? item
          : (_primaryTab == 'library'
              ? item.copyWith(sourceCategory: _librarySelection.genreKind.categorySlug)
              : (_discoverScope != 'all'
                  ? item.copyWith(
                      sourceCategory: HongguoGenreKind.fromAny(_discoverScope).categorySlug,
                    )
                  : item));
      final detail = await _resolver.getDramaDetail(
        effectiveItem.seriesId,
        fallbackItem: effectiveItem,
      );
      if (!mounted) return;
      Navigator.pop(context); // đóng dialog loading
      _showEpisodeBottomSheet(detail);
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi tải chi tiết phim: $e')),
      );
    }
  }

  void _showEpisodeBottomSheet(HongguoDramaDetail detail) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _EpisodeSelectorSheet(
        detail: detail,
        resolver: _resolver,
        onStartTranslation: widget.onStartTranslation,
        isTranslationEnabled: _isTranslationEnabled,
        onSelectTag: _applyTagFilterFromDetail,
        onOpenRelatedDrama: _openDramaDetail,
      ),
    );
  }

  void _showHongguoSettingsSheet() {
    HapticFeedback.lightImpact();
    HongguoSettingsSheet.show(context);
  }

  void _showDramaQuickMenu(HongguoDramaItem drama) {
    HapticFeedback.mediumImpact();
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.hongguo);
    final isWl = WatchLaterRepository.watchLaterNotifier.value.any(
      (w) => w.seriesId == drama.seriesId || w.id.contains(drama.seriesId),
    );

    showModalBottomSheet(
      context: context,
      backgroundColor: palette.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: palette.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                drama.title,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Divider(color: palette.border),
            ListTile(
              leading: Icon(
                isWl ? Icons.bookmark_added_rounded : Icons.bookmark_add_outlined,
                color: accent,
              ),
              title: Text(
                isWl ? 'Xóa khỏi danh sách xem sau' : 'Thêm vào danh sách xem sau',
                style: TextStyle(color: palette.textPrimary, fontSize: 14),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                final repo = await WatchLaterRepository.getInstance();
                final added = await repo.toggleWatchLater(WatchLaterItem(
                  id: 'hg_${drama.seriesId}',
                  title: drama.title,
                  coverUrl: drama.cover,
                  source: 'hongguo',
                  targetUrl: drama.seriesId,
                  seriesId: drama.seriesId,
                  totalEpisodes: drama.episodeCount > 0 ? drama.episodeCount : null,
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
                          color: added ? accent : Colors.orangeAccent,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            added
                                ? '🔖 Đã thêm "${drama.title}" vào danh sách Xem sau'
                                : '🗑️ Đã xóa "${drama.title}" khỏi danh sách Xem sau',
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
              title: Text(
                'Sao chép tên phim',
                style: TextStyle(color: palette.textPrimary, fontSize: 14),
              ),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: drama.title));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Đã sao chép tên phim!'), duration: Duration(seconds: 1)),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.hongguo);

    final libraryGroups = HongguoDiscoveryService.instance.getSelectorGroups(
      _librarySelection.genreKind,
    );
    final librarySummary = _librarySelection.buildSummaryLabel(libraryGroups);
    final activeCount = _librarySelection.activeFilterCount;

    return AppTabBackdrop(
      tab: AppTabId.hongguo,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              // 1. THANH HEADER TRÊN CÙNG PHONG CÁCH HỒNG QUẢ
              // (Avatar đăng nhập | Thanh tìm kiếm | Lướt Shorts | Cài đặt)
              _buildHeaderSection(),

              const SizedBox(height: 4),

              // 2. THANH 3 TAB CẤP 1 GỌN GÀNG (ĐỀ XUẤT | KHO LỌC SÂU | BẢNG XẾP HẠNG)
              _buildPrimaryTabBar(),

              // 2.5 THANH LỌC THEO TỪNG TAB (HOẶC PHẠM VI TÌM KIẾM)
              if (_isSearchMode)
                _buildSearchScopeBar()
              else if (!_isAiResultMode && _primaryTab == 'discover')
                _buildDiscoverScopeBar()
              else if (!_isAiResultMode && _primaryTab == 'library')
                _buildLibraryFilterBar(libraryGroups, activeCount)
              else if (!_isAiResultMode && _primaryTab == 'rank')
                _buildRankBoardBar(),

              const SizedBox(height: 6),

              // 3.5 THANH TRẠNG THÁI & LÀM MỚI / ĐỔI LOẠT PHIM MỚI
              _buildStatusActionBar(librarySummary),

              // 4. LƯỚI PHIM VỚI PULL-TO-REFRESH + NÚT TRỢ LÝ AI NỔI
              Expanded(
                child: Stack(
                  children: [
                    RefreshIndicator(
                      color: accent,
                      backgroundColor: palette.surface,
                      onRefresh: _isSearchMode && _currentSearchQuery.isNotEmpty
                          ? () => _loadSearchPage(_currentPage)
                          : () => _loadDramas(resetCursor: true),
                      child: _buildBody(),
                    ),
                    Positioned(
                      right: 14,
                      bottom: 12,
                      child: _buildAssistantFloatingButton(),
                    ),
                  ],
                ),
              ),

              // 5. THANH DƯỚI CÙNG (TẢI THÊM ĐỀ XUẤT THU GỌN / PHÂN TRANG + DỊCH TIÊU ĐỀ)
              _buildBottomActionBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderSection() {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.hongguo);
    final secondary = palette.secondaryFor(AppTabId.hongguo);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
      color: Colors.transparent,
      child: Row(
        children: [
          // Ảnh đại diện đăng nhập bên trái
          ValueListenableBuilder<HongguoCloudAccountState>(
            valueListenable: HongguoCloudAccountService.instance.state,
            builder: (ctx, cloudState, _) {
              final avatarUrl =
                  (cloudState.profile?.avatarUrl ?? '').isNotEmpty
                      ? cloudState.profile!.avatarUrl
                      : (cloudState.credentials?.avatarUrl ?? '');
              final isLoggedIn = cloudState.isLoggedIn;
              final displayName = cloudState.profile?.userName ??
                  cloudState.credentials?.userName ??
                  'Đã đăng nhập';
              return Tooltip(
                message: isLoggedIn
                    ? 'Tài khoản Hồng Quả ($displayName)'
                    : 'Đăng nhập Tài khoản Hồng Quả',
                child: InkWell(
                  onTap: () {
                    HapticFeedback.lightImpact();
                    HongguoAccountSheet.show(
                      context,
                      onOpenSeries: (
                        seriesId, {
                        int episodeIndex = 1,
                        int positionMs = 0,
                      }) {
                        _openDramaDetail(
                          HongguoDramaItem(
                            seriesId: seriesId,
                            title: '',
                            cover: '',
                            episodeCount: 0,
                          ),
                        );
                      },
                    );
                  },
                  borderRadius: BorderRadius.circular(20),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: palette.surface,
                          border: Border.all(
                            color: isLoggedIn ? accent : palette.border,
                            width: 1.5,
                          ),
                          boxShadow: palette.cardShadows,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: avatarUrl.isNotEmpty
                            ? Image.network(
                                avatarUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => Icon(
                                  Icons.account_circle_rounded,
                                  color: isLoggedIn
                                      ? accent
                                      : palette.textSecondary,
                                  size: 32,
                                ),
                              )
                            : Icon(
                                Icons.account_circle_rounded,
                                color: isLoggedIn
                                    ? accent
                                    : palette.textSecondary,
                                size: 32,
                              ),
                      ),
                      if (isLoggedIn)
                        Positioned(
                          right: -1,
                          bottom: -1,
                          child: Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: accent,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: palette.surface,
                                width: 1.5,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 8),

          // Thanh tìm kiếm bo tròn kiểu Hồng Quả
          Expanded(
            child: Container(
              height: 40,
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: accent.withValues(alpha: 0.28),
                ),
                boxShadow: palette.cardShadows,
              ),
              child: Row(
                children: [
                  const SizedBox(width: 11),
                  GestureDetector(
                    onTap: () => _performSearch(),
                    child: Icon(
                      Icons.search_rounded,
                      color: accent,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      textInputAction: TextInputAction.search,
                      onChanged: (_) => setState(() {}),
                      onSubmitted: _performSearch,
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontSize: 13,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Tìm phim hoặc dán link...',
                        hintStyle: TextStyle(
                          color: palette.textMuted,
                          fontSize: 12.5,
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  if (_searchController.text.isNotEmpty) ...[
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 16,
                        color: palette.textMuted,
                      ),
                      onPressed: () {
                        _searchController.clear();
                        _loadDramas();
                      },
                    ),
                    InkWell(
                      onTap: () => _performSearch(),
                      borderRadius: BorderRadius.circular(15),
                      child: Container(
                        margin: const EdgeInsets.only(right: 4),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: Text(
                          'Tìm',
                          style: TextStyle(
                            color: palette.onColor(accent),
                            fontWeight: FontWeight.bold,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                    ),
                  ],
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.only(right: 4),
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    icon: Icon(
                      Icons.paste_rounded,
                      size: 17,
                      color: accent,
                    ),
                    tooltip: 'Dán link từ Clipboard',
                    onPressed: _pasteFromClipboard,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),

          // Nút Lướt Shorts rực rỡ kiểu Hồng Quả
          Tooltip(
            message: 'Lướt Shorts Khám Phá (Xem thử siêu tốc)',
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (ctx) => const HongguoFeedScreen(),
                    ),
                  );
                },
                child: Ink(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [accent, secondary]),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.swipe_vertical_rounded,
                        color: Colors.white,
                        size: 16,
                      ),
                      SizedBox(width: 3),
                      Text(
                        'Lướt',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),

          // Nút Cài đặt bên phải
          Tooltip(
            message: 'Cài đặt tự chuyển tập & dịch ngầm',
            child: Material(
              color: palette.surface,
              shape: CircleBorder(side: BorderSide(color: palette.border)),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _showHongguoSettingsSheet,
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: Icon(
                    Icons.settings_rounded,
                    color: palette.textSecondary,
                    size: 19,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrimaryTabBar() {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.hongguo);

    const tabs = <({String id, String label, IconData icon})>[
      (id: 'discover', label: 'Đề xuất', icon: Icons.auto_awesome_rounded),
      (id: 'library', label: 'Kho lọc sâu', icon: Icons.tune_rounded),
      (id: 'rank', label: 'Bảng Xếp Hạng', icon: Icons.leaderboard_rounded),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
      child: Row(
        children: tabs.map((tab) {
          final isSelected =
              !_isSearchMode && !_isAiResultMode && _primaryTab == tab.id;
          return Padding(
            padding: const EdgeInsets.only(right: 18),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _onSelectPrimaryTab(tab.id),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        tab.icon,
                        size: 14,
                        color: isSelected ? accent : palette.textMuted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        tab.label,
                        style: TextStyle(
                          fontSize: isSelected ? 14.5 : 13,
                          fontWeight:
                              isSelected ? FontWeight.w800 : FontWeight.w600,
                          color: isSelected
                              ? palette.textPrimary
                              : palette.textMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: isSelected ? 22 : 0,
                    height: 3.5,
                    decoration: BoxDecoration(
                      color: isSelected ? accent : Colors.transparent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSearchScopeBar() {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.hongguo);
    final onAccent = palette.onColor(accent);

    final options = <({HongguoGenreKind? kind, String label})>[
      (kind: null, label: 'Tất cả kho'),
      for (final k in HongguoGenreKind.values)
        (kind: k, label: '${k.emoji} ${k.shortLabel}'),
    ];
    return SizedBox(
      height: 36,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final opt = options[i];
          final isSel = _searchScope == opt.kind;
          return ChoiceChip(
            visualDensity: VisualDensity.compact,
            label: Text(
              opt.label,
              style: TextStyle(
                fontSize: 11.5,
                color: isSel ? onAccent : palette.textSecondary,
                fontWeight: isSel ? FontWeight.bold : FontWeight.w500,
              ),
            ),
            selected: isSel,
            selectedColor: accent,
            backgroundColor: palette.surface,
            side: BorderSide(
              color: isSel ? accent : palette.border,
            ),
            showCheckmark: false,
            onSelected: (_) {
              if (_searchScope == opt.kind) return;
              HapticFeedback.selectionClick();
              setState(() => _searchScope = opt.kind);
              if (_currentSearchQuery.isNotEmpty) {
                unawaited(_loadSearchPage(1));
              }
            },
          );
        },
      ),
    );
  }

  Widget _buildDiscoverScopeBar() {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.hongguo);
    final onAccent = palette.onColor(accent);

    const scopes = <({String id, String label})>[
      (id: 'all', label: '✨ Dành cho bạn'),
      (id: 'short_play', label: '🎬 Người thật'),
      (id: 'comic_series', label: '🎨 Hoạt hình'),
      (id: 'ai_series', label: '🤖 Phim AI'),
    ];
    return SizedBox(
      height: 36,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: scopes.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final s = scopes[i];
          final isSel = _discoverScope == s.id;
          return ChoiceChip(
            visualDensity: VisualDensity.compact,
            label: Text(
              s.label,
              style: TextStyle(
                fontSize: 12,
                color: isSel ? onAccent : palette.textSecondary,
                fontWeight: isSel ? FontWeight.bold : FontWeight.w500,
              ),
            ),
            selected: isSel,
            selectedColor: accent,
            backgroundColor: palette.surface,
            side: BorderSide(
              color: isSel ? accent : palette.border,
            ),
            showCheckmark: false,
            onSelected: (_) => _onSelectDiscoverScope(s.id),
          );
        },
      ),
    );
  }

  Widget _buildLibraryFilterBar(
    List<HongguoSelectorGroup> groups,
    int activeCount,
  ) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.hongguo);
    final secondary = palette.secondaryFor(AppTabId.hongguo);
    final onAccent = palette.onColor(accent);

    final kind = _librarySelection.genreKind;
    final quickChips = <({String axis, String id, String label})>[
      (axis: 'sort', id: 'hot_score', label: '🔥 Hot nhất'),
      (axis: 'sort', id: 'online_time', label: '🆕 Mới nhất'),
      (axis: 'gender', id: '0', label: '👩 Nữ tần'),
      (axis: 'gender', id: '1', label: '👨 Nam tần'),
      if (kind == HongguoGenreKind.comicSeries) ...const [
        (axis: 'category_dim_art_style', id: 'cate_5416', label: '2D Anime'),
        (axis: 'category_dim_art_style', id: 'cate_5415', label: '3D'),
      ],
      if (kind == HongguoGenreKind.realPlay) ...const [
        (axis: 'category_dim_epoch', id: 'cate_5315', label: '🎓 Học đường'),
        (axis: 'category_dim_theme', id: 'cate_5000', label: '❤️ Tình cảm'),
        (axis: 'category_dim_theme', id: 'cate_5007', label: '🏯 Cổ trang'),
        (axis: 'category_dim_theme', id: 'cate_5031', label: '⚡ Nghịch tập'),
        (axis: 'category_dim_theme', id: 'cate_5008', label: '✨ Tu tiên'),
      ] else ...const [
        (axis: 'category_dim_epoch', id: 'cate_4', label: '🎓 Học đường'),
        (axis: 'category_dim_epoch', id: 'cate_1', label: '🏙️ Đô thị'),
        (axis: 'category_dim_theme', id: 'cate_7', label: '✨ Tu tiên'),
        (axis: 'category_dim_theme', id: 'cate_755', label: '💡 Não động'),
        (axis: 'category_dim_role', id: 'cate_36', label: '⏳ Trọng sinh'),
        (axis: 'category_dim_role', id: 'cate_19', label: '⚙️ Hệ thống'),
      ],
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    itemCount: HongguoGenreKind.values.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 6),
                    itemBuilder: (_, i) {
                      final k = HongguoGenreKind.values[i];
                      final isSel = kind == k;
                      return ChoiceChip(
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        label: Text(
                          '${k.emoji} ${k.shortLabel}',
                          style: TextStyle(
                            fontSize: 12,
                            color: isSel ? onAccent : palette.textSecondary,
                            fontWeight:
                                isSel ? FontWeight.bold : FontWeight.w500,
                          ),
                        ),
                        selected: isSel,
                        selectedColor: accent,
                        backgroundColor: palette.surface,
                        side: BorderSide(
                          color: isSel ? accent : palette.border,
                        ),
                        showCheckmark: false,
                        onSelected: (_) => _onSelectLibraryKind(k),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: _openLibraryFilterSheet,
                borderRadius: BorderRadius.circular(18),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: activeCount > 0
                        ? accent.withValues(alpha: 0.14)
                        : palette.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: activeCount > 0 ? accent : palette.border,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.tune_rounded,
                        size: 14,
                        color: activeCount > 0 ? accent : palette.textSecondary,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        activeCount > 0 ? 'Bộ lọc ($activeCount)' : 'Bộ lọc',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: activeCount > 0 ? accent : palette.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 30,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: quickChips.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (_, i) {
                final c = quickChips[i];
                final selectedVal = c.axis == 'sort'
                    ? _librarySelection.effectiveSort
                    : _librarySelection.valueOf(c.axis);
                final isSel = selectedVal == c.id;
                return ActionChip(
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  label: Text(
                    c.label,
                    style: TextStyle(
                      fontSize: 11,
                      color: isSel ? secondary : palette.textSecondary,
                      fontWeight: isSel ? FontWeight.bold : FontWeight.w500,
                    ),
                  ),
                  backgroundColor: isSel
                      ? secondary.withValues(alpha: 0.14)
                      : palette.surface,
                  side: BorderSide(
                    color: isSel
                        ? secondary.withValues(alpha: 0.7)
                        : palette.border,
                  ),
                  onPressed: () => _toggleQuickLibraryFilter(c.axis, c.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRankBoardBar() {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.hongguo);
    final onAccent = palette.onColor(accent);

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
      child: SizedBox(
        height: 34,
        child: ListView.separated(
          physics: const BouncingScrollPhysics(),
          scrollDirection: Axis.horizontal,
          itemCount: HongguoResolver.rankBoards.length,
          separatorBuilder: (_, _) => const SizedBox(width: 6),
          itemBuilder: (_, i) {
            final board = HongguoResolver.rankBoards[i];
            final isSelected = _selectedRankSlug == board.slug;
            return ChoiceChip(
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              label: Text(
                board.label,
                style: TextStyle(
                  fontSize: 11.5,
                  color: isSelected ? onAccent : palette.textSecondary,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                ),
              ),
              selected: isSelected,
              selectedColor: accent,
              backgroundColor: palette.surface,
              side: BorderSide(
                color: isSelected ? accent : palette.border,
              ),
              showCheckmark: false,
              onSelected: (_) => _onSelectRankBoard(board.slug),
            );
          },
        ),
      ),
    );
  }

  Widget _buildStatusActionBar(String librarySummary) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.hongguo);
    final secondary = palette.secondaryFor(AppTabId.hongguo);

    final rankLabel = HongguoResolver.rankBoards
        .cast<HongguoCategory?>()
        .firstWhere((c) => c?.slug == _selectedRankSlug, orElse: () => null)
        ?.label ??
        'BXH';

    final statusTitle = _isAiResultMode
        ? '${_aiResultLabel.isNotEmpty ? _aiResultLabel : "Gợi ý từ Trợ lý AI"} (${_dramas.length})'
        : (_isSearchMode
            ? (_totalPages > 1
                ? 'Kết quả tìm kiếm (Trang $_currentPage/$_totalPages)'
                : 'Kết quả tìm kiếm (${_dramas.length})')
            : (_primaryTab == 'discover'
                ? (_discoverScope == 'all'
                    ? 'Đề xuất cá nhân hóa (${_dramas.length})'
                    : 'Đề xuất ${HongguoGenreKind.fromAny(_discoverScope).label} (${_dramas.length})')
                : (_primaryTab == 'rank'
                    ? '$rankLabel (Trang $_currentPage/$_totalPages)'
                    : '$librarySummary · Trang $_currentPage')));

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                Icon(
                  _isAiResultMode
                      ? Icons.auto_awesome_rounded
                      : (_isSearchMode
                          ? Icons.search_rounded
                          : (_primaryTab == 'discover'
                              ? Icons.auto_awesome
                              : (_primaryTab == 'rank'
                                  ? Icons.local_fire_department_rounded
                                  : Icons.filter_list_rounded))),
                  size: 15,
                  color: _primaryTab == 'rank'
                      ? accent
                      : (_primaryTab == 'discover' ? secondary : accent),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    statusTitle,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: palette.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (_isAiResultMode)
            InkWell(
              onTap: () => _loadDramas(resetCursor: true),
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: palette.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.close_rounded, size: 13, color: palette.textSecondary),
                    const SizedBox(width: 4),
                    Text(
                      'Thoát lọc AI',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: palette.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (!_isSearchMode && !_isAiResultMode)
            InkWell(
              onTap: _isLoading
                  ? null
                  : (_primaryTab == 'discover'
                      ? _loadNextDiscoverBatch
                      : () => _loadDramas(resetCursor: true)),
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: accent.withValues(alpha: 0.45),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _isLoading
                        ? SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: accent,
                            ),
                          )
                        : Icon(
                            _primaryTab == 'discover'
                                ? Icons.auto_awesome_rounded
                                : Icons.refresh_rounded,
                            size: 14,
                            color: accent,
                          ),
                    const SizedBox(width: 5),
                    Text(
                      _primaryTab == 'discover' ? 'Đổi loạt mới' : 'Làm mới',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.bold,
                        color: accent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.hongguo);
    final onAccent = palette.onColor(accent);

    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator(color: accent),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                color: Colors.redAccent,
                size: 44,
              ),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Thử lại'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: palette.surface,
                      foregroundColor: accent,
                      side: BorderSide(color: palette.border),
                      elevation: 0,
                    ),
                    onPressed: _isSearchMode && _currentSearchQuery.isNotEmpty
                        ? () => _loadSearchPage(_currentPage)
                        : () => _loadDramas(resetCursor: false),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                    label: const Text('Tải đề xuất'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: onAccent,
                      elevation: 0,
                    ),
                    onPressed: _loadNextDiscoverBatch,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    if (_dramas.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 100),
          Center(
            child: Text(
              'Không tìm thấy phim phù hợp với bộ lọc này.',
              style: TextStyle(color: palette.textMuted),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: ElevatedButton.icon(
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Đặt lại bộ lọc'),
              style: ElevatedButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: onAccent,
                elevation: 0,
              ),
              onPressed: () {
                setState(() {
                  _librarySelection = _librarySelection.resetFilters();
                  _primaryTab = 'discover';
                });
                _loadDramas(resetCursor: true);
              },
            ),
          ),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final aspectRatio = width < 370 ? 0.58 : 0.61;

        return GridView.builder(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 72),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            childAspectRatio: aspectRatio,
            crossAxisSpacing: 12,
            mainAxisSpacing: 14,
          ),
          itemCount: _dramas.length,
          itemBuilder: (ctx, i) {
            final drama = _dramas[i];
            return _DramaCard(
              drama: drama,
              index: i + 1,
              isRankCategory: !_isSearchMode && _primaryTab == 'rank',
              isTranslationEnabled: _isTranslationEnabled,
              onTap: () => _openDramaDetail(drama),
              onLongPress: () => _showDramaQuickMenu(drama),
            );
          },
        );
      },
    );
  }

  Widget _buildAssistantFloatingButton() {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.hongguo);
    final secondary = palette.secondaryFor(AppTabId.hongguo);
    return ListenableBuilder(
      listenable: _assistantController,
      builder: (context, _) {
        final isReady = _assistantController.connectionState ==
            AssistantConnectionState.ready;
        final isBusy = _assistantController.isAssistantBusy ||
            _assistantController.isMicActive;
        return Material(
          color: Colors.transparent,
          elevation: 8,
          shadowColor: accent.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(28),
          child: InkWell(
            onTap: _openAssistantSheet,
            borderRadius: BorderRadius.circular(28),
            child: Ink(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [accent, secondary],
                ),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.25),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isBusy
                        ? Icons.graphic_eq_rounded
                        : Icons.auto_awesome_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'Trợ lý AI',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                  if (isReady) ...[
                    const SizedBox(width: 6),
                    Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBottomActionBar() {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.hongguo);

    final showPagination = !_isAiResultMode &&
        (_isSearchMode || _primaryTab != 'discover') &&
        (_totalPages > 1 || _currentPage > 1);
    final showDiscoverLoadMore =
        !_isAiResultMode && !_isSearchMode && _primaryTab == 'discover';

    if (showPagination) {
      return _buildPaginationBar();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: palette.isDark
            ? palette.surface
            : palette.surface.withValues(alpha: 0.72),
        border: Border(top: BorderSide(color: palette.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (showDiscoverLoadMore) ...[
            Flexible(
              child: ElevatedButton.icon(
                onPressed: _isLoading ? null : _loadNextDiscoverBatch,
                icon: const Icon(Icons.auto_awesome_rounded, size: 15),
                label: Text(
                  _discoverScope == 'all'
                      ? 'Tải thêm đề xuất'
                      : 'Thêm ${HongguoGenreKind.fromAny(_discoverScope).label}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: accent.withValues(alpha: 0.12),
                  foregroundColor: accent,
                  side: BorderSide(
                    color: accent.withValues(alpha: 0.45),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  minimumSize: const Size(0, 34),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ] else
            const Spacer(),
          _buildTranslateToggleButton(compact: false),
        ],
      ),
    );
  }

  Widget _buildTranslateToggleButton({required bool compact}) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.hongguo);
    final enabled = _isTranslationEnabled;
    final color = enabled ? accent : palette.textMuted;
    return Tooltip(
      message: enabled
          ? 'Tắt dịch tiếng Việt'
          : 'Bật dịch tiếng Việt (Tên & Giới thiệu)',
      child: InkWell(
        onTap: _toggleTranslation,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 34,
          padding: EdgeInsets.symmetric(horizontal: compact ? 9 : 11),
          decoration: BoxDecoration(
            color: enabled
                ? accent.withValues(alpha: 0.12)
                : palette.surfaceAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: enabled
                  ? accent.withValues(alpha: 0.45)
                  : palette.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                enabled ? Icons.translate_rounded : Icons.translate_outlined,
                color: color,
                size: 16,
              ),
              if (!compact) ...[
                const SizedBox(width: 6),
                Text(
                  enabled ? 'Dịch: BẬT' : 'Dịch: TẮT',
                  style: TextStyle(
                    color: enabled ? accent : palette.textSecondary,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPaginationBar() {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.hongguo);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: palette.isDark
            ? palette.surface
            : palette.surface.withValues(alpha: 0.72),
        border: Border(top: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.arrow_back_ios_rounded, size: 12),
            label: const Text('Trước', style: TextStyle(fontSize: 12)),
            style: OutlinedButton.styleFrom(
              foregroundColor: _currentPage > 1 ? accent : palette.textMuted,
              side: BorderSide(
                color: _currentPage > 1
                    ? accent.withValues(alpha: 0.5)
                    : palette.border,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: const Size(0, 34),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed:
                _currentPage > 1 ? () => _goToPage(_currentPage - 1) : null,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: palette.surfaceAlt,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: palette.border),
                ),
                child: Text(
                  '$_currentPage / $_totalPages',
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor:
                  _currentPage < _totalPages ? accent : palette.textMuted,
              side: BorderSide(
                color: _currentPage < _totalPages
                    ? accent.withValues(alpha: 0.5)
                    : palette.border,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: const Size(0, 34),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: _currentPage < _totalPages
                ? () => _goToPage(_currentPage + 1)
                : null,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Sau', style: TextStyle(fontSize: 12)),
                SizedBox(width: 4),
                Icon(Icons.arrow_forward_ios_rounded, size: 12),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _buildTranslateToggleButton(compact: true),
        ],
      ),
    );
  }
}

// ===== CARD PHIM MOBILE (TỈ LỆ CHUẨN POSTER, BO GÓC, SHADOW, BADGE XẾP HẠNG) =====
class _DramaCard extends StatelessWidget {
  final HongguoDramaItem drama;
  final int index;
  final bool isRankCategory;
  final bool isTranslationEnabled;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _DramaCard({
    required this.drama,
    required this.index,
    required this.isRankCategory,
    this.isTranslationEnabled = true,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.hongguo);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(18),
      splashColor: accent.withValues(alpha: 0.1),
      child: Container(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: palette.border),
          boxShadow: palette.cardShadows,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Ảnh bìa + Badge
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  (drama.cover.isNotEmpty && !drama.cover.contains('empty_play'))
                      ? Image.network(
                          drama.cover,
                          headers: NetworkHeaderHelper.getHeadersForUrl(drama.cover),
                          cacheWidth: 360,
                          fit: BoxFit.cover,
                          errorBuilder: (ctx, e, st) => Container(
                            color: palette.surfaceAlt,
                            child: Center(
                              child: Icon(
                                Icons.movie_rounded,
                                size: 36,
                                color: palette.textMuted,
                              ),
                            ),
                          ),
                          loadingBuilder: (ctx, child, progress) {
                            if (progress == null) return child;
                            return Container(
                              color: palette.surfaceAlt,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Icon(
                                    Icons.movie_rounded,
                                    size: 36,
                                    color: palette.textMuted.withValues(alpha: 0.25),
                                  ),
                                  SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: accent,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        )
                      : Container(
                          color: palette.surfaceAlt,
                          child: Center(
                            child: Icon(
                              Icons.movie_rounded,
                              size: 36,
                              color: palette.textMuted,
                            ),
                          ),
                        ),

                  // Subtle bottom scrim for polished poster look
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 34,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.48),
                          ],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                      ),
                    ),
                  ),

                  // Badge Xếp Hạng Top 1, 2, 3 (Góc trên trái)
                  if (isRankCategory && index <= 10)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2.5,
                        ),
                        decoration: BoxDecoration(
                          color: index == 1
                              ? const Color(0xFFFF4D4F)
                              : index == 2
                                  ? const Color(0xFFFA8C16)
                                  : index == 3
                                      ? const Color(0xFFFAAD14)
                                      : Colors.black.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'TOP $index',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),

                  // Badge số tập (Góc trên phải)
                  if (drama.episodeCount > 0)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2.5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.68),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${drama.episodeCount} Tập',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFFFD54F),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Thông tin phim (tiêu đề + tags)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Builder(
                    builder: (context) {
                      if (!isTranslationEnabled) {
                        return Text(
                          drama.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: palette.textPrimary,
                            height: 1.25,
                          ),
                        );
                      }
                      final cached =
                          OfflineMlKitTranslator.getCachedTitle(drama.title);
                      if (cached != null) {
                        return Text(
                          cached,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: palette.textPrimary,
                            height: 1.25,
                          ),
                        );
                      }
                      return FutureBuilder<String>(
                        future: OfflineMlKitTranslator.translateHongguoTitle(
                            drama.title),
                        initialData: drama.title,
                        builder: (context, snapshot) {
                          return Text(
                            snapshot.data ?? drama.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: palette.textPrimary,
                              height: 1.25,
                            ),
                          );
                        },
                      );
                    },
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            _formatCardSubtitle(drama),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: accent,
                            ),
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
    );
  }

  String _formatCardSubtitle(HongguoDramaItem drama) {
    final translated =
        drama.tags.take(2).map(HongguoSimilarEngine.getTagLabel).join(' · ');
    final inferredSource = drama.categoryIds.isNotEmpty || drama.tags.isNotEmpty
        ? HongguoResolver.inferSourceCategoryFromIds(
            drama.categoryIds,
            tags: drama.tags,
          )
        : null;
    final prefix = inferredSource == 'category/ai-drama'
        ? 'AI'
        : inferredSource == 'category/comic-drama'
            ? 'Hoạt hình'
            : null;
    if (translated.isNotEmpty) {
      return prefix != null ? '$prefix · $translated' : translated;
    }
    return prefix != null ? '$prefix · Hồng Quả' : 'Phim ngắn Hồng Quả';
  }
}

// ===== BOTTOM SHEET CHỌN TẬP PHIM (TỐI ƯU CẢ IOS VÀ ANDROID, SAFE AREA, CHUNK RANGE) =====
class _EpisodeSelectorSheet extends StatefulWidget {
  final HongguoDramaDetail detail;
  final HongguoResolver resolver;
  final bool isTranslationEnabled;
  final void Function(String videoUrl, String title, int durationMs)?
      onStartTranslation;
  final void Function(String zhTag, HongguoDramaDetail detail)? onSelectTag;
  final void Function(HongguoDramaItem drama)? onOpenRelatedDrama;

  const _EpisodeSelectorSheet({
    required this.detail,
    required this.resolver,
    this.isTranslationEnabled = true,
    this.onStartTranslation,
    this.onSelectTag,
    this.onOpenRelatedDrama,
  });

  @override
  State<_EpisodeSelectorSheet> createState() => _EpisodeSelectorSheetState();
}

class _EpisodeSelectorSheetState extends State<_EpisodeSelectorSheet> {
  int _selectedEpisodeIndex = 1;
  bool _isLoadingPlayUrl = false;
  bool _loadingTts = false;
  String _statusMessage = '';
  int _selectedRangeChunk = 0; // Phân đoạn mỗi 30 tập: 0 (1-30), 1 (31-60), ...
  final ScrollController _titleScrollController = ScrollController();
  final ScrollController _introScrollController = ScrollController();
  bool _isTitleExpanded = false;

  static const int _chunkSize = 30;

  @override
  void dispose() {
    _titleScrollController.dispose();
    _introScrollController.dispose();
    super.dispose();
  }

  Widget _buildHeaderTitle(String rawTitle) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.hongguo);
    final titleStyle = TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.bold,
      color: palette.textPrimary,
      height: 1.3,
    );

    Widget buildTitleContent(String displayTitle) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final painter = TextPainter(
            text: TextSpan(text: displayTitle, style: titleStyle),
            maxLines: 2,
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: constraints.maxWidth);

          if (!painter.didExceedMaxLines) {
            return Text(displayTitle, style: titleStyle);
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  setState(() => _isTitleExpanded = !_isTitleExpanded);
                },
                child: _isTitleExpanded
                    ? Text(displayTitle, style: titleStyle)
                    : ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 46),
                        child: Scrollbar(
                          controller: _titleScrollController,
                          thumbVisibility: true,
                          radius: const Radius.circular(4),
                          thickness: 3,
                          child: SingleChildScrollView(
                            controller: _titleScrollController,
                            physics: const BouncingScrollPhysics(),
                            child: Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Text(displayTitle, style: titleStyle),
                            ),
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 2),
              GestureDetector(
                onTap: () {
                  setState(() => _isTitleExpanded = !_isTitleExpanded);
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _isTitleExpanded ? 'Thu gọn' : 'Xem đủ tên',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: accent,
                      ),
                    ),
                    Icon(
                      _isTitleExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 15,
                      color: accent,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      );
    }

    if (!widget.isTranslationEnabled) {
      return buildTitleContent(rawTitle);
    }
    final cached = OfflineMlKitTranslator.getCachedTitle(rawTitle);
    if (cached != null) {
      return buildTitleContent(cached);
    }
    return FutureBuilder<String>(
      future: OfflineMlKitTranslator.translateHongguoTitle(rawTitle),
      initialData: rawTitle,
      builder: (ctx, snap) => buildTitleContent(snap.data ?? rawTitle),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.hongguo);
    final secondary = palette.secondaryFor(AppTabId.hongguo);
    final onAccent = palette.onColor(accent);

    final detail = widget.detail;
    final maxKnown = detail.episodes.length > detail.totalEpisodes
        ? detail.episodes.length
        : detail.totalEpisodes;
    final total = maxKnown > 0 ? maxKnown : 1;

    final totalChunks = (total / _chunkSize).ceil();

    final startEp = total > _chunkSize ? _selectedRangeChunk * _chunkSize + 1 : 1;
    final endEp = total > _chunkSize
        ? ((_selectedRangeChunk + 1) * _chunkSize).clamp(1, total)
        : total;
    final currentRangeCount = endEp - startEp + 1;

    return DraggableScrollableSheet(
      initialChildSize: 0.82,
      minChildSize: 0.45,
      maxChildSize: 0.94,
      expand: false,
      builder: (ctx, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
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

              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: detail.cover.isNotEmpty
                              ? Image.network(
                                  detail.cover,
                                  headers: NetworkHeaderHelper.getHeadersForUrl(detail.cover),
                                  cacheWidth: 200,
                                  width: 84,
                                  height: 114,
                                  fit: BoxFit.cover,
                                  errorBuilder: (ctx, e, st) => Container(
                                    width: 84,
                                    height: 114,
                                    color: palette.surfaceAlt,
                                    child: Icon(Icons.movie_rounded, color: palette.textMuted),
                                  ),
                                )
                              : Container(
                                  width: 84,
                                  height: 114,
                                  color: palette.surfaceAlt,
                                  child: Icon(Icons.movie_rounded, color: palette.textMuted),
                                ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildHeaderTitle(detail.title),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: accent.withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      'Tổng $total Tập',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: accent,
                                      ),
                                    ),
                                  ),
                                  ValueListenableBuilder<List<WatchLaterItem>>(
                                    valueListenable: WatchLaterRepository.watchLaterNotifier,
                                    builder: (wlContext, items, _) {
                                      final isWl = items.any((w) =>
                                          w.seriesId == detail.seriesId ||
                                          w.id == 'hg_${detail.seriesId}');
                                      return InkWell(
                                        onTap: () async {
                                          final messenger = ScaffoldMessenger.of(context);
                                          final repo = await WatchLaterRepository.getInstance();
                                          final added = await repo.toggleWatchLater(WatchLaterItem(
                                            id: 'hg_${detail.seriesId}',
                                            title: detail.title,
                                            coverUrl: detail.cover,
                                            source: 'hongguo',
                                            targetUrl: detail.seriesId,
                                            seriesId: detail.seriesId,
                                            totalEpisodes: total,
                                            addedAt: DateTime.now().millisecondsSinceEpoch,
                                          ));
                                          if (!mounted) return;
                                          messenger.hideCurrentSnackBar();
                                          messenger.showSnackBar(
                                            SnackBar(
                                              content: Row(
                                                children: [
                                                  Icon(
                                                    added
                                                        ? Icons.bookmark_added_rounded
                                                        : Icons.bookmark_remove_rounded,
                                                    color: added ? accent : Colors.orangeAccent,
                                                    size: 18,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Text(
                                                      added
                                                          ? '🔖 Đã thêm "${detail.title}" vào danh sách Xem sau!'
                                                          : '🗑️ Đã xóa "${detail.title}" khỏi danh sách Xem sau',
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
                                        borderRadius: BorderRadius.circular(8),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: isWl
                                                ? accent.withValues(alpha: 0.16)
                                                : palette.surfaceAlt,
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(
                                              color: isWl ? accent : palette.border,
                                              width: 0.8,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                isWl ? Icons.bookmark_added_rounded : Icons.bookmark_add_outlined,
                                                size: 13,
                                                color: isWl ? accent : palette.textSecondary,
                                              ),
                                              const SizedBox(width: 4),
                                              Text(
                                                isWl ? 'Đã lưu' : 'Xem sau',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                  color: isWl ? accent : palette.textSecondary,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                  ValueListenableBuilder<HongguoCloudAccountState>(
                                    valueListenable: HongguoCloudAccountService.instance.state,
                                    builder: (favCtx, cloudState, _) {
                                      final isFav = cloudState.isFavorite(detail.seriesId);
                                      final pending = cloudState.isFavoritePending(detail.seriesId);
                                      return InkWell(
                                        borderRadius: BorderRadius.circular(8),
                                        onTap: pending
                                            ? null
                                            : () async {
                                                HapticFeedback.selectionClick();
                                                if (!cloudState.isLoggedIn) {
                                                  await HongguoAccountSheet.show(context);
                                                  return;
                                                }
                                                final messenger = ScaffoldMessenger.of(context);
                                                try {
                                                  final msg = await HongguoCloudAccountService
                                                      .instance
                                                      .setFavorite(
                                                    seriesId: detail.seriesId,
                                                    title: detail.title,
                                                    add: !isFav,
                                                  );
                                                  if (msg.isNotEmpty) {
                                                    messenger.showSnackBar(
                                                      SnackBar(
                                                        content: Text(msg),
                                                        duration: const Duration(seconds: 2),
                                                      ),
                                                    );
                                                  }
                                                } catch (e) {
                                                  messenger.showSnackBar(
                                                    SnackBar(content: Text(e.toString())),
                                                  );
                                                }
                                              },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: isFav
                                                ? const Color(0xFFFF4D67).withValues(alpha: 0.14)
                                                : palette.surfaceAlt,
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(
                                              color: isFav
                                                  ? const Color(0xFFFF4D67).withValues(alpha: 0.55)
                                                  : palette.border,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (pending)
                                                const SizedBox(
                                                  width: 12,
                                                  height: 12,
                                                  child: CircularProgressIndicator(strokeWidth: 1.5),
                                                )
                                              else
                                                Icon(
                                                  isFav ? Icons.favorite : Icons.favorite_border,
                                                  size: 13,
                                                  color: isFav
                                                      ? const Color(0xFFFF4D67)
                                                      : palette.textSecondary,
                                                ),
                                              const SizedBox(width: 4),
                                              Text(
                                                isFav ? 'Cloud' : 'Yêu thích',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                  color: isFav
                                                      ? const Color(0xFFFF4D67)
                                                      : palette.textSecondary,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                  InkWell(
                                    borderRadius: BorderRadius.circular(8),
                                    onTap: () {
                                      HapticFeedback.selectionClick();
                                      HongguoRelatedDramaSheet.show(
                                        context,
                                        currentDetail: detail,
                                        isTranslationEnabled:
                                            widget.isTranslationEnabled,
                                        onSelectDrama: (relatedDrama) {
                                          Navigator.of(context).pop();
                                          if (mounted) {
                                            Navigator.of(context).pop();
                                          }
                                          widget.onOpenRelatedDrama
                                              ?.call(relatedDrama);
                                        },
                                      );
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF7C3AED)
                                            .withValues(alpha: 0.14),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: const Color(0xFF7C3AED)
                                              .withValues(alpha: 0.45),
                                          width: 0.8,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.auto_awesome_rounded,
                                            size: 13,
                                            color: palette.isDark
                                                ? const Color(0xFFC4B5FD)
                                                : const Color(0xFF7C3AED),
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            'Phim tương tự',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                              color: palette.isDark
                                                  ? const Color(0xFFEDE9FE)
                                                  : const Color(0xFF6D28D9),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (detail.tags.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 5,
                                  runSpacing: 5,
                                  children: detail.tags.take(6).map((zhTag) {
                                    final viLabel =
                                        HongguoSimilarEngine.getTagLabel(zhTag);
                                    return InkWell(
                                      borderRadius: BorderRadius.circular(12),
                                      onTap: widget.onSelectTag == null
                                          ? null
                                          : () {
                                              HapticFeedback.selectionClick();
                                              Navigator.of(context).pop();
                                              widget.onSelectTag
                                                  ?.call(zhTag, detail);
                                            },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: palette.surfaceAlt,
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          border: Border.all(
                                            color: palette.border,
                                            width: 0.8,
                                          ),
                                        ),
                                        child: Text(
                                          '#$viLabel',
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            color: palette.textSecondary,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ],
                              if (detail.intro.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxHeight: 76),
                                  child: Scrollbar(
                                    controller: _introScrollController,
                                    thumbVisibility: true,
                                    radius: const Radius.circular(4),
                                    thickness: 3,
                                    child: SingleChildScrollView(
                                      controller: _introScrollController,
                                      physics: const BouncingScrollPhysics(),
                                      child: Padding(
                                        padding:
                                            const EdgeInsets.only(right: 6),
                                        child: Builder(
                                          builder: (ctx) {
                                            if (!widget.isTranslationEnabled) {
                                              return Text(
                                                detail.intro,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: palette.textMuted,
                                                  height: 1.35,
                                                ),
                                              );
                                            }
                                            final cached =
                                                OfflineMlKitTranslator
                                                    .getCachedIntro(
                                                        detail.intro);
                                            if (cached != null) {
                                              return Text(
                                                cached,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: palette.textMuted,
                                                  height: 1.35,
                                                ),
                                              );
                                            }
                                            return FutureBuilder<String>(
                                              future: OfflineMlKitTranslator
                                                  .translateHongguoIntro(
                                                      detail.intro),
                                              initialData: detail.intro,
                                              builder: (ctx, snap) {
                                                return Text(
                                                  snap.data ?? detail.intro,
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: palette.textMuted,
                                                    height: 1.35,
                                                  ),
                                                );
                                              },
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 14),
                    Divider(color: palette.border, height: 1),
                    const SizedBox(height: 12),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Chọn tập (Đang chọn: Tập $_selectedEpisodeIndex)',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: palette.textPrimary,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'Mở VIP trọn bộ $total tập',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: accent,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    if (total > _chunkSize) ...[
                      SizedBox(
                        height: 34,
                        child: ListView.separated(
                          physics: const BouncingScrollPhysics(),
                          scrollDirection: Axis.horizontal,
                          itemCount: totalChunks,
                          separatorBuilder: (ctx, i) => const SizedBox(width: 8),
                          itemBuilder: (ctx, i) {
                            final from = i * _chunkSize + 1;
                            final to = ((i + 1) * _chunkSize).clamp(1, total);
                            final isSelected = _selectedRangeChunk == i;
                            return ChoiceChip(
                              label: Text('$from - $to'),
                              selected: isSelected,
                              labelStyle: TextStyle(
                                fontSize: 12,
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: isSelected
                                    ? onAccent
                                    : palette.textSecondary,
                              ),
                              selectedColor: accent,
                              backgroundColor: palette.surfaceAlt,
                              side: BorderSide(
                                color: isSelected ? accent : palette.border,
                              ),
                              showCheckmark: false,
                              onSelected: (_) {
                                HapticFeedback.selectionClick();
                                setState(() {
                                  _selectedRangeChunk = i;
                                });
                              },
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],

                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 5,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                        childAspectRatio: 1.35,
                      ),
                      itemCount: currentRangeCount,
                      itemBuilder: (ctx, i) {
                        final epIndex = startEp + i;
                        final isSelected = _selectedEpisodeIndex == epIndex;
                        final isAccessible = epIndex <= detail.accessibleEpisodes;
                        return InkWell(
                          onTap: () {
                            HapticFeedback.lightImpact();
                            if (isSelected && !_isLoadingPlayUrl) {
                              _playEpisode(context, enableTts: false);
                              return;
                            }
                            setState(() {
                              _selectedEpisodeIndex = epIndex;
                              if (!isAccessible) {
                                _statusMessage =
                                    '⚡ Tập $epIndex là tập VIP: Tự động giải mã DRM trên máy khi phát.';
                              } else {
                                _statusMessage = '';
                              }
                            });
                          },
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? accent.withValues(alpha: 0.16)
                                  : palette.surfaceAlt,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isSelected ? accent : palette.border,
                                width: isSelected ? 1.5 : 1,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '$epIndex',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isSelected
                                        ? FontWeight.bold
                                        : FontWeight.w500,
                                    color: isSelected
                                        ? accent
                                        : palette.textPrimary,
                                  ),
                                ),
                                if (!isAccessible) ...[
                                  const SizedBox(width: 3),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 3,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? accent.withValues(alpha: 0.25)
                                          : secondary.withValues(alpha: 0.16),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'VIP',
                                      style: TextStyle(
                                        fontSize: 8.5,
                                        fontWeight: FontWeight.bold,
                                        color: isSelected ? accent : secondary,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),

                    if (_statusMessage.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Center(
                        child: Text(
                          _statusMessage,
                          style: TextStyle(
                            color: secondary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(height: 80),
                  ],
                ),
              ),

              SafeArea(
                top: false,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  decoration: BoxDecoration(
                    color: palette.surface,
                    border: Border(top: BorderSide(color: palette.border)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: secondary.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: secondary.withValues(alpha: 0.4),
                          ),
                        ),
                        child: IconButton(
                          icon: Icon(
                            Icons.swipe_vertical_rounded,
                            color: secondary,
                          ),
                          tooltip: 'Lướt xem thử dạng Shorts',
                          onPressed: () {
                            Navigator.pop(context);
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (ctx) => HongguoFeedScreen(
                                  initialDrama: widget.detail,
                                  initialEpisodeIndex: _selectedEpisodeIndex,
                                ),
                              ),
                            );
                          },
                        ),
                      ),

                      Expanded(
                        child: OutlinedButton.icon(
                          icon: (_isLoadingPlayUrl && !_loadingTts)
                              ? SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: palette.textPrimary,
                                  ),
                                )
                              : const Icon(Icons.subtitles_rounded, size: 18),
                          label: Text(
                            'Vietsub Tập $_selectedEpisodeIndex',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: palette.textPrimary,
                            side: BorderSide(color: palette.border),
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: _isLoadingPlayUrl
                              ? null
                              : () => _playEpisode(context, enableTts: false),
                        ),
                      ),
                      const SizedBox(width: 10),

                      Expanded(
                        child: ElevatedButton.icon(
                          icon: (_isLoadingPlayUrl && _loadingTts)
                              ? SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: onAccent,
                                  ),
                                )
                              : const Icon(Icons.record_voice_over_rounded,
                                  size: 18),
                          label: Text(
                            'Lồng Tiếng Tập $_selectedEpisodeIndex',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: accent,
                            foregroundColor: onAccent,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: 0,
                          ),
                          onPressed: _isLoadingPlayUrl
                              ? null
                              : () => _playEpisode(context, enableTts: true),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<String?> _resolveCurrentEpisodeUrl() async {
    setState(() {
      _isLoadingPlayUrl = true;
      _statusMessage = 'Đang lấy đường dẫn video tập $_selectedEpisodeIndex...';
    });

    try {
      final detail = widget.detail;
      var vid = '';
      if (detail.episodes.isNotEmpty &&
          _selectedEpisodeIndex <= detail.episodes.length) {
        vid = detail.episodes[_selectedEpisodeIndex - 1].vid;
      }
      final playUrl = await widget.resolver.getEpisodePlayUrl(
        detail.seriesId,
        vid.isNotEmpty ? vid : detail.seriesId,
        episodeIndex: _selectedEpisodeIndex,
        onProgress: (p, msg) {
          if (mounted) {
            setState(() {
              _statusMessage = msg;
            });
          }
        },
      );
      if (mounted) {
        setState(() {
          _isLoadingPlayUrl = false;
          _statusMessage = '';
        });
      }
      return playUrl;
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingPlayUrl = false;
          _statusMessage = 'Lỗi lấy video: $e';
        });
      }
      return null;
    }
  }

  Future<void> _playEpisode(BuildContext ctx, {required bool enableTts}) async {
    HapticFeedback.lightImpact();
    setState(() {
      _loadingTts = enableTts;
    });
    final playUrl = await _resolveCurrentEpisodeUrl();
    if (!mounted) return;
    if (playUrl == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline_rounded, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _statusMessage.isNotEmpty
                      ? _statusMessage
                      : 'Không thể lấy liên kết video tập $_selectedEpisodeIndex',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          backgroundColor: Colors.redAccent.shade700,
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }

    var effectivePath = playUrl;
    final cached = await VideoCacheManager.findCachedFile(
      url: playUrl,
      seriesId: widget.detail.seriesId,
      episodeIndex: _selectedEpisodeIndex,
    );
    if (cached != null) {
      effectivePath = cached.path;
    }
    if (!mounted) return;

    final dramaTitle = widget.isTranslationEnabled
        ? (OfflineMlKitTranslator.getCachedTitle(widget.detail.title) ??
            widget.detail.title)
        : widget.detail.title;

    // Tự động đóng bảng chọn tập phim để người dùng xem video ngay lập tức
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }

    GlobalPlayerManager.instance.openPlayer(
      videoPath: effectivePath,
      title: '$dramaTitle - Tập $_selectedEpisodeIndex',
      document: SubtitleDocument(),
      dramaDetail: widget.detail,
      currentEpisodeIndex: _selectedEpisodeIndex,
      initialTtsEnabled: enableTts,
    );
  }
}