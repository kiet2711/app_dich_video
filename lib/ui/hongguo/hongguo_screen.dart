import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/model/subtitle_document.dart';
import '../../domain/ai/offline_mlkit_translator.dart';
import '../../domain/media/hongguo_resolver.dart';
import '../../domain/media/network_header_helper.dart';
import '../../domain/media/video_cache_manager.dart';
import '../../player/global_player_manager.dart';
import '../theme/app_theme.dart';
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

  String _currentCategorySlug = 'discover';
  String _currentGenreSlug = '';
  int _currentPage = 1;
  int _totalPages = 1;

  bool _isLoading = false;
  String? _errorMessage;
  List<HongguoDramaItem> _dramas = [];
  bool _isSearchMode = false;
  bool _isTranslationEnabled = true;

  @override
  void initState() {
    super.initState();
    _loadTranslationSetting();
    _loadDramas();
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              newVal ? Icons.translate_rounded : Icons.translate_outlined,
              color: newVal ? AppColors.primaryEmerald : Colors.white70,
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
        backgroundColor: const Color(0xFF1E222D),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: AppColors.cardBorder),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadDramas() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _isSearchMode = false;
    });

    try {
      final res = _currentCategorySlug == 'discover'
          ? await _resolver.getRandomRecommendations(genre: _currentGenreSlug)
          : await _resolver.browseList(
              category: _currentCategorySlug,
              genre: _currentGenreSlug,
              page: _currentPage,
            );

      if (!mounted) return;
      setState(() {
        _dramas = res.items;
        _currentPage = res.currentPage;
        _totalPages = res.totalPages > 0 ? res.totalPages : 1;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Không thể tải danh sách phim: $e';
      });
    }
  }

  Future<void> _loadRandomNewDramas() async {
    HapticFeedback.mediumImpact();
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _isSearchMode = false;
      _searchController.clear();
      // Nếu đang ở BXH Hot, chuyển sang tab Đề Xuất để nạp phim phong phú ngoài BXH
      if (_currentCategorySlug == 'rank/hot-drama') {
        _currentCategorySlug = 'discover';
      }
    });

    try {
      final res = await _resolver.getRandomRecommendations(
        preferredCategory: (_currentCategorySlug == 'discover' ||
                _currentCategorySlug.startsWith('rank/'))
            ? null
            : _currentCategorySlug,
        genre: _currentGenreSlug,
      );

      if (!mounted) return;
      setState(() {
        _dramas = res.items;
        _currentPage = res.currentPage;
        _totalPages = res.totalPages > 0 ? res.totalPages : 1;
        _isLoading = false;
      });

      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }

      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(
                Icons.casino_rounded,
                color: AppColors.primaryEmerald,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Đã nạp ${res.items.length} phim mới ngẫu nhiên!',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF1E222D),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: AppColors.cardBorder),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Không thể nạp phim mới: $e';
      });
    }
  }

  Future<void> _performSearch([String? query]) async {
    final text = (query ?? _searchController.text).trim();
    if (text.isEmpty) {
      _loadDramas();
      return;
    }

    // Nếu người dùng dán link chia sẻ hoặc ID phim
    if (HongguoResolver.isHongguoUrl(text)) {
      _resolveAndOpenSharedDrama(text);
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _isSearchMode = true;
    });

    var queryToSearch = text;
    // Tự động nhận diện tiếng Việt / chữ cái Latin và dùng ML Kit dịch sang tiếng Trung
    if (RegExp(r'[a-zA-ZÀ-ỹ]').hasMatch(text)) {
      try {
        final translatedQuery =
            await OfflineMlKitTranslator.translateSearchQuery(text);
        if (translatedQuery.isNotEmpty && translatedQuery != text) {
          queryToSearch = translatedQuery;
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    const Icon(Icons.translate_rounded,
                        color: AppColors.primaryEmerald, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Đã dịch tìm kiếm: "$text" ➔ "$translatedQuery"',
                        style:
                            const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                  ],
                ),
                duration: const Duration(seconds: 3),
                behavior: SnackBarBehavior.floating,
                backgroundColor: const Color(0xFF1E222D),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: const BorderSide(color: AppColors.cardBorder),
                ),
              ),
            );
          }
        }
      } catch (e) {
        debugPrint('[HongguoSearch] Lỗi dịch từ khóa: $e');
      }
    }

    try {
      final results = await _resolver.search(queryToSearch);
      if (!mounted) return;
      setState(() {
        _dramas = results;
        _isLoading = false;
        _currentPage = 1;
        _totalPages = 1;
      });
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
      _performSearch(text);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Khay nhớ tạm trống!'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _onSelectCategory(String slug) {
    if (_currentCategorySlug == slug && !_isSearchMode) return;
    HapticFeedback.selectionClick();
    setState(() {
      _currentCategorySlug = slug;
      _currentGenreSlug = '';
      _currentPage = 1;
      _searchController.clear();
    });
    _loadDramas();
  }

  void _onSelectGenre(String slug) {
    if (_currentGenreSlug == slug && !_isSearchMode) return;
    HapticFeedback.selectionClick();
    setState(() {
      _currentGenreSlug = slug;
      _currentPage = 1;
      _searchController.clear();
    });
    _loadDramas();
  }

  void _goToPage(int page) {
    if (page < 1 || page > _totalPages || page == _currentPage || _isLoading) {
      return;
    }
    HapticFeedback.lightImpact();
    setState(() {
      _currentPage = page;
    });
    _loadDramas();
  }

  Future<void> _openDramaDetail(HongguoDramaItem item) async {
    HapticFeedback.lightImpact();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(
        child: CircularProgressIndicator(color: AppColors.primaryEmerald),
      ),
    );

    try {
      final detail = await _resolver.getDramaDetail(item.seriesId);
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
      ),
    );
  }

  void _showHongguoSettingsSheet() {
    HapticFeedback.lightImpact();
    HongguoSettingsSheet.show(context);
  }

  @override
  Widget build(BuildContext context) {
    final isCategoryWithGenre =
        _currentCategorySlug.contains('real-drama') ||
        _currentCategorySlug.contains('comic-drama');

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        backgroundColor: AppColors.darkSurface,
        elevation: 0,
        centerTitle: false,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.redAccent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.local_fire_department_rounded,
                color: Colors.redAccent,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'Phim Ngắn Hồng Quả',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              Icons.translate_rounded,
              color: _isTranslationEnabled
                  ? AppColors.primaryEmerald
                  : AppColors.textMuted,
            ),
            tooltip: _isTranslationEnabled
                ? 'Tắt dịch tiếng Việt'
                : 'Bật dịch tiếng Việt (Tên & Giới thiệu)',
            onPressed: _toggleTranslation,
          ),
          IconButton(
            icon: const Icon(Icons.tune_rounded, color: AppColors.textSecondary),
            tooltip: 'Cài đặt tự chuyển tập & dịch ngầm',
            onPressed: _showHongguoSettingsSheet,
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: AppColors.textSecondary),
            tooltip: 'Làm mới',
            onPressed: () {
              HapticFeedback.lightImpact();
              _loadDramas();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // 1. THANH TÌM KIẾM & DÁN LINK NHANH
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.darkSurfaceVariant,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: TextField(
                  controller: _searchController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: _performSearch,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Tìm kiếm phim hoặc dán link chia sẻ...',
                    hintStyle: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13,
                    ),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      color: AppColors.textSecondary,
                      size: 20,
                    ),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_searchController.text.isNotEmpty)
                          IconButton(
                            icon: const Icon(
                              Icons.close_rounded,
                              size: 18,
                              color: AppColors.textMuted,
                            ),
                            onPressed: () {
                              _searchController.clear();
                              _loadDramas();
                            },
                          ),
                        IconButton(
                          icon: const Icon(
                            Icons.paste_rounded,
                            size: 18,
                            color: AppColors.primaryEmerald,
                          ),
                          tooltip: 'Dán link từ Clipboard',
                          onPressed: _pasteFromClipboard,
                        ),
                      ],
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                ),
              ),
            ),

            // 2. DANH MỤC CHÍNH (HOT, NGƯỜI THẬT, HOẠT HÌNH, AI)
            SizedBox(
              height: 42,
              child: ListView.separated(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                scrollDirection: Axis.horizontal,
                itemCount: HongguoResolver.categories.length,
                separatorBuilder: (ctx, i) => const SizedBox(width: 8),
                itemBuilder: (ctx, i) {
                  final cat = HongguoResolver.categories[i];
                  final isSelected =
                      !_isSearchMode && _currentCategorySlug == cat.slug;
                  return ChoiceChip(
                    label: Text(
                      cat.label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected
                            ? Colors.white
                            : AppColors.textSecondary,
                      ),
                    ),
                    selected: isSelected,
                    selectedColor: AppColors.primaryEmerald.withValues(alpha: 0.25),
                    backgroundColor: AppColors.darkSurfaceVariant,
                    side: BorderSide(
                      color: isSelected
                          ? AppColors.primaryEmerald
                          : AppColors.cardBorder,
                    ),
                    onSelected: (_) => _onSelectCategory(cat.slug),
                  );
                },
              ),
            ),

            // 3. THỂ LOẠI CON (HIỂN THỊ KHI Ở DANH MỤC NGƯỜI THẬT HOẶC HOẠT HÌNH)
            if (isCategoryWithGenre && !_isSearchMode)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: SizedBox(
                  height: 36,
                  child: ListView.separated(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    scrollDirection: Axis.horizontal,
                    itemCount: HongguoResolver.realDramaGenres.length,
                    separatorBuilder: (ctx, i) => const SizedBox(width: 6),
                    itemBuilder: (ctx, i) {
                      final g = HongguoResolver.realDramaGenres[i];
                      final isSelected = _currentGenreSlug == g.slug;
                      return ActionChip(
                        label: Text(
                          g.label,
                          style: TextStyle(
                            fontSize: 11,
                            color: isSelected
                                ? AppColors.accentGold
                                : AppColors.textMuted,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        backgroundColor: isSelected
                            ? AppColors.accentGold.withValues(alpha: 0.12)
                            : Colors.transparent,
                        side: BorderSide(
                          color: isSelected
                              ? AppColors.accentGold.withValues(alpha: 0.6)
                              : AppColors.cardBorder.withValues(alpha: 0.5),
                        ),
                        onPressed: () => _onSelectGenre(g.slug),
                      );
                    },
                  ),
                ),
              ),

            const SizedBox(height: 6),

            // 3.5 THANH ĐIỀU KHIỂN TRẠNG THÁI & NÚT LOAD PHIM MỚI
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Icon(
                          _isSearchMode
                              ? Icons.search_rounded
                              : (_currentCategorySlug == 'discover'
                                  ? Icons.auto_awesome
                                  : (_currentCategorySlug.contains('rank')
                                      ? Icons.local_fire_department_rounded
                                      : Icons.movie_filter_rounded)),
                          size: 15,
                          color: _currentCategorySlug == 'discover'
                              ? AppColors.accentGold
                              : (_currentCategorySlug.contains('rank')
                                  ? Colors.redAccent
                                  : AppColors.primaryEmerald),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            _isSearchMode
                                ? 'Kết quả tìm kiếm (${_dramas.length})'
                                : (_currentCategorySlug == 'discover'
                                    ? 'Phim đề xuất ngẫu nhiên (${_dramas.length})'
                                    : (_currentCategorySlug.contains('rank')
                                        ? 'Bảng Xếp Hạng Hot (Trang $_currentPage/$_totalPages)'
                                        : 'Kho phim Hồng Quả (Trang $_currentPage/$_totalPages)')),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Nút hành động Subheader (Đổi phim ngẫu nhiên khi ở Đề Xuất, hoặc Làm mới khi ở BXH/Thể loại)
                  if (!_isSearchMode)
                    InkWell(
                      onTap: _isLoading
                          ? null
                          : (_currentCategorySlug == 'discover'
                              ? _loadRandomNewDramas
                              : _loadDramas),
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              AppColors.primaryEmerald.withValues(alpha: 0.22),
                              AppColors.primaryEmerald.withValues(alpha: 0.08),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: AppColors.primaryEmerald.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _isLoading
                                ? const SizedBox(
                                    width: 13,
                                    height: 13,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppColors.primaryEmerald,
                                    ),
                                  )
                                : Icon(
                                    _currentCategorySlug == 'discover'
                                        ? Icons.casino_rounded
                                        : Icons.refresh_rounded,
                                    size: 14,
                                    color: AppColors.primaryEmerald,
                                  ),
                            const SizedBox(width: 5),
                            Text(
                              _currentCategorySlug == 'discover'
                                  ? 'Đổi phim mới'
                                  : 'Làm mới',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.bold,
                                color: AppColors.primaryEmerald,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // 4. LƯỚI PHIM VỚI PULL-TO-REFRESH
            Expanded(
              child: RefreshIndicator(
                color: AppColors.primaryEmerald,
                backgroundColor: AppColors.darkSurface,
                onRefresh: _loadDramas,
                child: _buildBody(),
              ),
            ),

            // 5. THANH PHÂN TRANG (PAGINATION HOẶC ĐỔI PHIM MỚI)
            if (!_isSearchMode &&
                _currentCategorySlug != 'discover' &&
                _totalPages > 1)
              _buildPaginationBar(),
            if (!_isSearchMode && _currentCategorySlug == 'discover')
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: const BoxDecoration(
                  color: AppColors.darkSurface,
                  border: Border(top: BorderSide(color: AppColors.cardBorder)),
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : _loadRandomNewDramas,
                    icon: const Icon(Icons.casino_rounded, size: 18),
                    label: const Text(
                      'Đổi danh sách phim mới khác',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          AppColors.primaryEmerald.withValues(alpha: 0.15),
                      foregroundColor: AppColors.primaryEmerald,
                      side: const BorderSide(color: AppColors.primaryEmerald),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      elevation: 0,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primaryEmerald),
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
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Thử lại'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.darkSurfaceVariant,
                      foregroundColor: AppColors.primaryEmerald,
                      side: const BorderSide(color: AppColors.cardBorder),
                    ),
                    onPressed: _loadDramas,
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.casino_rounded, size: 16),
                    label: const Text('Load phim mới'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryEmerald,
                      foregroundColor: Colors.black,
                    ),
                    onPressed: _loadRandomNewDramas,
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
          const Center(
            child: Text(
              'Không tìm thấy bộ phim nào.',
              style: TextStyle(color: AppColors.textMuted),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: ElevatedButton.icon(
              icon: const Icon(Icons.casino_rounded, size: 16),
              label: const Text('Load phim mới ngẫu nhiên'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryEmerald,
                foregroundColor: Colors.black,
              ),
              onPressed: _loadRandomNewDramas,
            ),
          ),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Tỉ lệ poster thích ứng cho mọi kích thước màn hình điện thoại
        final width = constraints.maxWidth;
        final aspectRatio = width < 370 ? 0.58 : 0.61;

        return GridView.builder(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
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
              isRankCategory: _currentCategorySlug.contains('rank'),
              isTranslationEnabled: _isTranslationEnabled,
              onTap: () => _openDramaDetail(drama),
            );
          },
        );
      },
    );
  }

  Widget _buildPaginationBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        color: AppColors.darkSurface,
        border: Border(top: BorderSide(color: AppColors.cardBorder)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.arrow_back_ios_rounded, size: 12),
            label: const Text('Trang trước'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _currentPage > 1
                  ? AppColors.primaryEmerald
                  : AppColors.textMuted,
              side: BorderSide(
                color: _currentPage > 1
                    ? AppColors.primaryEmerald.withValues(alpha: 0.5)
                    : AppColors.cardBorder,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            ),
            onPressed:
                _currentPage > 1 ? () => _goToPage(_currentPage - 1) : null,
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.darkSurfaceVariant,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Text(
              'Trang $_currentPage / $_totalPages',
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.arrow_forward_ios_rounded, size: 12),
            label: const Text('Trang sau'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _currentPage < _totalPages
                  ? AppColors.primaryEmerald
                  : AppColors.textMuted,
              side: BorderSide(
                color: _currentPage < _totalPages
                    ? AppColors.primaryEmerald.withValues(alpha: 0.5)
                    : AppColors.cardBorder,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            ),
            onPressed: _currentPage < _totalPages
                ? () => _goToPage(_currentPage + 1)
                : null,
          ),
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

  const _DramaCard({
    required this.drama,
    required this.index,
    required this.isRankCategory,
    this.isTranslationEnabled = true,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      splashColor: AppColors.primaryEmerald.withValues(alpha: 0.1),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.darkSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.cardBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
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
                  drama.cover.isNotEmpty
                      ? Image.network(
                          drama.cover,
                          headers: NetworkHeaderHelper.getHeadersForUrl(drama.cover),
                          cacheWidth: 360,
                          fit: BoxFit.cover,
                          errorBuilder: (ctx, e, st) => Container(
                            color: AppColors.darkSurfaceVariant,
                            child: const Center(
                              child: Icon(
                                Icons.movie_rounded,
                                size: 36,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ),
                          loadingBuilder: (ctx, child, progress) {
                            if (progress == null) return child;
                            return Container(
                              color: AppColors.darkSurfaceVariant,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Icon(
                                    Icons.movie_rounded,
                                    size: 36,
                                    color: Colors.white.withValues(alpha: 0.05),
                                  ),
                                  const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppColors.primaryEmerald,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        )
                      : Container(
                          color: AppColors.darkSurfaceVariant,
                          child: const Center(
                            child: Icon(
                              Icons.movie_rounded,
                              size: 36,
                              color: AppColors.textMuted,
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
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: index == 1
                              ? const Color(0xFFFF4D4F)
                              : index == 2
                                  ? const Color(0xFFFA8C16)
                                  : index == 3
                                      ? const Color(0xFFFAAD14)
                                      : Colors.black.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(4),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.4),
                              blurRadius: 4,
                            ),
                          ],
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
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.2),
                          ),
                        ),
                        child: Text(
                          '${drama.episodeCount} Tập',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: AppColors.accentGold,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Thông tin phim (tiêu đề + tags)
            Padding(
              padding: const EdgeInsets.all(8),
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
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
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
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
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
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary,
                              height: 1.25,
                            ),
                          );
                        },
                      );
                    },
                  ),
                  const SizedBox(height: 4),
                  Text(
                    drama.tags.isNotEmpty
                        ? drama.tags.take(2).join(' · ')
                        : 'Phim ngắn Hồng Quả',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10,
                      color: AppColors.textMuted,
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
}

// ===== BOTTOM SHEET CHỌN TẬP PHIM (TỐI ƯU CẢ IOS VÀ ANDROID, SAFE AREA, CHUNK RANGE) =====
class _EpisodeSelectorSheet extends StatefulWidget {
  final HongguoDramaDetail detail;
  final HongguoResolver resolver;
  final bool isTranslationEnabled;
  final void Function(String videoUrl, String title, int durationMs)?
      onStartTranslation;

  const _EpisodeSelectorSheet({
    required this.detail,
    required this.resolver,
    this.isTranslationEnabled = true,
    this.onStartTranslation,
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
  final ScrollController _introScrollController = ScrollController();

  static const int _chunkSize = 30;

  @override
  void dispose() {
    _introScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail;
    final total = detail.episodes.isNotEmpty
        ? detail.episodes.length
        : (detail.totalEpisodes > 0 ? detail.totalEpisodes : 1);

    final totalChunks = (total / _chunkSize).ceil();

    // Lọc danh sách tập hiển thị theo khoảng nếu có nhiều tập
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
          decoration: const BoxDecoration(
            color: AppColors.darkSurface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              // Thanh kéo drag handle (iOS / Android Sheet bar)
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 8),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.cardBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Nội dung chính cuộn được
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    // Header phim: Poster nhỏ + Tên + Tổng số tập + Giới thiệu
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
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
                                    color: AppColors.darkSurfaceVariant,
                                    child: const Icon(Icons.movie_rounded),
                                  ),
                                )
                              : Container(
                                  width: 84,
                                  height: 114,
                                  color: AppColors.darkSurfaceVariant,
                                  child: const Icon(Icons.movie_rounded),
                                ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Builder(
                                builder: (ctx) {
                                  if (!widget.isTranslationEnabled) {
                                    return Text(
                                      detail.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.textPrimary,
                                      ),
                                    );
                                  }
                                  final cached =
                                      OfflineMlKitTranslator.getCachedTitle(
                                          detail.title);
                                  if (cached != null) {
                                    return Text(
                                      cached,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.textPrimary,
                                      ),
                                    );
                                  }
                                  return FutureBuilder<String>(
                                    future:
                                        OfflineMlKitTranslator.translateHongguoTitle(
                                            detail.title),
                                    initialData: detail.title,
                                    builder: (ctx, snap) {
                                      return Text(
                                        snap.data ?? detail.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: AppColors.textPrimary,
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.primaryEmerald
                                      .withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  'Tổng $total Tập',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.primaryEmerald,
                                  ),
                                ),
                              ),
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
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                  color: AppColors.textMuted,
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
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                  color: AppColors.textMuted,
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
                                                  style: const TextStyle(
                                                    fontSize: 11,
                                                    color: AppColors.textMuted,
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
                    const Divider(color: AppColors.cardBorder, height: 1),
                    const SizedBox(height: 12),

                    // Tiêu đề chọn tập
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Chọn tập (Đang chọn: Tập $_selectedEpisodeIndex)',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // Bộ lọc khoảng tập (Nếu phim có trên 30 tập)
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
                                    ? Colors.black
                                    : AppColors.textSecondary,
                              ),
                              selectedColor: AppColors.primaryEmerald,
                              backgroundColor: AppColors.darkSurfaceVariant,
                              side: BorderSide(
                                color: isSelected
                                    ? AppColors.primaryEmerald
                                    : AppColors.cardBorder,
                              ),
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

                    // Lưới các nút tập (5 cột chuẩn mobile)
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
                        return InkWell(
                          onTap: () {
                            HapticFeedback.lightImpact();
                            setState(() {
                              _selectedEpisodeIndex = epIndex;
                            });
                          },
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? AppColors.primaryEmerald
                                      .withValues(alpha: 0.25)
                                  : AppColors.darkSurfaceVariant,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isSelected
                                    ? AppColors.primaryEmerald
                                    : AppColors.cardBorder,
                                width: isSelected ? 1.5 : 1,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              '$epIndex',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: isSelected
                                    ? AppColors.primaryEmerald
                                    : AppColors.textPrimary,
                              ),
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
                          style: const TextStyle(
                            color: AppColors.accentGold,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(height: 80), // Chừa khoảng trống cho thanh nút đáy
                  ],
                ),
              ),

              // THANH NÚT HÀNH ĐỘNG CỐ ĐỊNH Ở ĐÁY SHEET (VỚI SAFE AREA CHO IOS HOME BAR & ANDROID GESTURES)
              SafeArea(
                top: false,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  decoration: const BoxDecoration(
                    color: AppColors.darkSurface,
                    border: Border(top: BorderSide(color: AppColors.cardBorder)),
                  ),
                  child: Row(
                    children: [
                      // Nút Xem Vietsub (Phụ đề)
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: (_isLoadingPlayUrl && !_loadingTts)
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppColors.textPrimary,
                                  ),
                                )
                              : const Icon(Icons.subtitles_rounded, size: 18),
                          label: Text(
                            'Vietsub Tập $_selectedEpisodeIndex',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.textPrimary,
                            side: const BorderSide(color: AppColors.cardBorder),
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: _isLoadingPlayUrl
                              ? null
                              : () => _playEpisode(context, enableTts: false),
                        ),
                      ),
                      const SizedBox(width: 10),

                      // Nút Xem Lồng Tiếng (AI Voice-over)
                      Expanded(
                        child: ElevatedButton.icon(
                          icon: (_isLoadingPlayUrl && _loadingTts)
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.black,
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
                            backgroundColor: AppColors.primaryEmerald,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
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
    if (playUrl == null || !mounted) return;

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
