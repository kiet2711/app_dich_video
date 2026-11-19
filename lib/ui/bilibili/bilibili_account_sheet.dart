import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/repository/settings_repository.dart';
import '../../domain/ai/offline_mlkit_translator.dart';
import '../../domain/media/bilibili_resolver.dart';
import '../theme/app_theme.dart';
import 'bilibili_login_sheet.dart';

/// BottomSheet Tài khoản Bilibili & Lịch sử xem đồng bộ từ app Bilibili gốc.
class BilibiliAccountSheet extends StatefulWidget {
  final Future<void> Function(BilibiliWatchHistoryEntry entry)? onOpenVideo;
  final VoidCallback? onAccountChanged;
  final BilibiliResolver? resolver;
  final bool translateTitles;

  const BilibiliAccountSheet({
    super.key,
    this.onOpenVideo,
    this.onAccountChanged,
    this.resolver,
    this.translateTitles = true,
  });

  static Future<void> show(
    BuildContext context, {
    Future<void> Function(BilibiliWatchHistoryEntry entry)? onOpenVideo,
    VoidCallback? onAccountChanged,
    BilibiliResolver? resolver,
    bool translateTitles = true,
  }) {
    final inheritedTheme = Theme.of(context);
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Theme(
        data: inheritedTheme,
        child: BilibiliAccountSheet(
          onOpenVideo: onOpenVideo,
          onAccountChanged: onAccountChanged,
          resolver: resolver,
          translateTitles: translateTitles,
        ),
      ),
    );
  }

  @override
  State<BilibiliAccountSheet> createState() => _BilibiliAccountSheetState();
}

class _BilibiliAccountSheetState extends State<BilibiliAccountSheet> {
  late final BilibiliResolver _resolver;
  final ScrollController _scrollController = ScrollController();

  SettingsRepository? _settings;
  String _cookie = '';
  BilibiliUserProfile? _profile;
  bool _isLoadingAccount = true;
  bool _isLoadingHistory = false;
  bool _isLoadingMore = false;
  bool _hasMore = false;
  int _nextMax = 0;
  int _nextViewAt = 0;
  String? _historyError;
  final List<BilibiliWatchHistoryEntry> _history = [];

  @override
  void initState() {
    super.initState();
    _resolver = widget.resolver ?? BilibiliResolver();
    _scrollController.addListener(_onScroll);
    _loadAccountAndHistory();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 200 &&
        _hasMore &&
        !_isLoadingMore &&
        !_isLoadingHistory) {
      _loadMoreHistory();
    }
  }

  Future<void> _loadAccountAndHistory() async {
    setState(() {
      _isLoadingAccount = true;
      _historyError = null;
    });
    final settings = await SettingsRepository.getInstance();
    final cookie = settings.bilibiliSessData.trim();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _cookie = cookie;
    });

    if (cookie.isEmpty) {
      setState(() {
        _profile = null;
        _history.clear();
        _hasMore = false;
        _isLoadingAccount = false;
        _isLoadingHistory = false;
      });
      return;
    }

    setState(() => _isLoadingHistory = true);
    try {
      final results = await Future.wait<dynamic>([
        _resolver.getUserProfile(cookie),
        _resolver.getWatchHistoryPage(pageSize: 20, cookie: cookie),
      ]);
      if (!mounted) return;
      final profile = results[0] as BilibiliUserProfile;
      final historyPage = results[1] as BilibiliWatchHistoryPage;
      setState(() {
        _profile = profile;
        _history
          ..clear()
          ..addAll(historyPage.items);
        _nextMax = historyPage.nextMax;
        _nextViewAt = historyPage.nextViewAt;
        _hasMore = historyPage.hasMore;
        _isLoadingAccount = false;
        _isLoadingHistory = false;
        _historyError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoadingAccount = false;
        _isLoadingHistory = false;
        _historyError = 'Không thể đồng bộ lịch sử Bilibili. Thử làm mới lại.';
      });
    }
  }

  Future<void> _loadMoreHistory() async {
    if (_cookie.isEmpty || !_hasMore || _isLoadingMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final page = await _resolver.getWatchHistoryPage(
        pageSize: 20,
        max: _nextMax,
        viewAt: _nextViewAt,
        cookie: _cookie,
      );
      if (!mounted) return;
      final existing = _history
          .map((e) => '${e.item.bvid ?? ''}_${e.item.epId ?? ''}_${e.viewAtSeconds}')
          .toSet();
      final fresh = page.items.where((entry) {
        final key =
            '${entry.item.bvid ?? ''}_${entry.item.epId ?? ''}_${entry.viewAtSeconds}';
        return existing.add(key);
      }).toList();
      setState(() {
        _history.addAll(fresh);
        _nextMax = page.nextMax;
        _nextViewAt = page.nextViewAt;
        _hasMore = page.hasMore && fresh.isNotEmpty;
        _isLoadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoadingMore = false);
    }
  }

  Future<void> _openLogin() async {
    final loggedIn = await BilibiliLoginSheet.show(context);
    if (loggedIn == true && mounted) {
      await _loadAccountAndHistory();
      widget.onAccountChanged?.call();
    }
  }

  Future<void> _logout() async {
    final palette = AppThemePalette.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: palette.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: palette.border),
        ),
        title: Text(
          'Đăng xuất Bilibili?',
          style: TextStyle(color: palette.textPrimary),
        ),
        content: Text(
          'Sau khi đăng xuất, lịch sử Bilibili đồng bộ sẽ ẩn đi và bạn không thể xem chất lượng 1080p hoặc video Hội Viên.',
          style: TextStyle(color: palette.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Hủy', style: TextStyle(color: palette.textMuted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Đăng xuất', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      _settings?.bilibiliSessData = '';
      _settings?.bilibiliBiliJct = '';
      if (!mounted) return;
      setState(() {
        _cookie = '';
        _profile = null;
        _history.clear();
        _hasMore = false;
      });
      widget.onAccountChanged?.call();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã đăng xuất tài khoản Bilibili')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.bilibili);
    final secondary = palette.secondaryFor(AppTabId.bilibili);
    final isLoggedIn = _profile?.isLogin == true;

    return Container(
      height: MediaQuery.of(context).size.height * 0.84,
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // Drag handle
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10, bottom: 10),
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: palette.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.account_circle_rounded,
                      color: accent,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Tài khoản Bilibili',
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: 16.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Đăng nhập & đồng bộ lịch sử xem Bilibili gốc',
                          style: TextStyle(
                            color: palette.textMuted,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_cookie.isNotEmpty)
                    IconButton(
                      tooltip: 'Đồng bộ lại lịch sử',
                      onPressed: (_isLoadingAccount || _isLoadingHistory)
                          ? null
                          : _loadAccountAndHistory,
                      icon: (_isLoadingAccount || _isLoadingHistory)
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: accent,
                              ),
                            )
                          : Icon(Icons.sync_rounded, color: palette.textSecondary),
                    ),
                  IconButton(
                    tooltip: 'Đóng',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close_rounded, color: palette.textSecondary),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // Account card
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: _buildAccountCard(palette, accent, secondary, isLoggedIn),
            ),

            const SizedBox(height: 14),

            // History Section Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  Icon(Icons.history_rounded, color: accent, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      isLoggedIn
                          ? 'Lịch sử xem Bilibili (${_history.length})'
                          : 'Lịch sử xem Bilibili',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (isLoggedIn) ...[
                    const SizedBox(width: 8),
                    Text(
                      'Đồng bộ app gốc',
                      style: TextStyle(
                        color: palette.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 8),
            Divider(color: palette.border, height: 1),

            // History list
            Expanded(
              child: _buildHistoryContent(palette, accent, secondary, isLoggedIn),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountCard(
    AppThemePalette palette,
    Color accent,
    Color secondary,
    bool isLoggedIn,
  ) {
    final vipGold =
        palette.isDark ? const Color(0xFFFFD700) : const Color(0xFFD97706);

    if (_isLoadingAccount) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: palette.surfaceAlt,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: palette.border),
        ),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: secondary),
          ),
        ),
      );
    }

    final profile = _profile;
    if (isLoggedIn && profile != null) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              secondary.withValues(alpha: palette.isDark ? 0.16 : 0.12),
              palette.surfaceAlt,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: profile.isVip ? vipGold : secondary.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: palette.surface,
              backgroundImage:
                  profile.avatar.isNotEmpty ? NetworkImage(profile.avatar) : null,
              child: profile.avatar.isEmpty
                  ? Icon(Icons.person, color: palette.textMuted)
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          profile.uname,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (profile.level > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: secondary,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'Lv.${profile.level}',
                            style: TextStyle(
                              color: palette.onColor(secondary),
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (profile.isVip)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: vipGold.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: vipGold,
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        profile.vipLabel.isNotEmpty
                            ? profile.vipLabel
                            : 'VIP Bilibili',
                        style: TextStyle(
                          color: vipGold,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  else
                    Text(
                      'Tài khoản chuẩn (Đã đăng nhập)',
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
            TextButton(
              onPressed: _logout,
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text(
                'Đăng xuất',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.surfaceAlt,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.lock_outline_rounded,
                color: palette.isDark ? Colors.orangeAccent : const Color(0xFFEA580C),
                size: 19,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _cookie.isNotEmpty
                      ? 'Phiên đăng nhập Bilibili đã hết hạn'
                      : 'Chưa đăng nhập Bilibili',
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Đăng nhập để xem chất lượng 1080p+, mở khóa VIP và đồng bộ lịch sử xem từ app Bilibili gốc.',
            style: TextStyle(color: palette.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _openLogin,
              icon: const Icon(Icons.login_rounded, size: 18),
              label: const Text('Đăng nhập ngay'),
              style: ElevatedButton.styleFrom(
                backgroundColor: secondary,
                foregroundColor: palette.onColor(secondary),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryContent(
    AppThemePalette palette,
    Color accent,
    Color secondary,
    bool isLoggedIn,
  ) {
    if (!isLoggedIn) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.history_toggle_off_rounded,
                color: palette.textMuted.withValues(alpha: 0.45),
                size: 44,
              ),
              const SizedBox(height: 10),
              Text(
                'Đăng nhập tài khoản Bilibili để đồng bộ lịch sử xem từ app gốc.',
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.textMuted, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    if (_isLoadingHistory && _history.isEmpty) {
      return Center(
        child: CircularProgressIndicator(color: accent),
      );
    }

    if (_historyError != null && _history.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _historyError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _loadAccountAndHistory,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Thử lại'),
              ),
            ],
          ),
        ),
      );
    }

    if (_history.isEmpty) {
      return Center(
        child: Text(
          'Chưa có lịch sử xem trên tài khoản Bilibili.',
          style: TextStyle(color: palette.textMuted, fontSize: 13),
        ),
      );
    }

    return RefreshIndicator(
      color: accent,
      onRefresh: _loadAccountAndHistory,
      child: ListView.separated(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        itemCount: _history.length + (_isLoadingMore ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (ctx, index) {
          if (index >= _history.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: accent,
                  ),
                ),
              ),
            );
          }
          return _buildHistoryRow(palette, accent, secondary, _history[index]);
        },
      ),
    );
  }

  Widget _buildHistoryRow(
    AppThemePalette palette,
    Color accent,
    Color secondary,
    BilibiliWatchHistoryEntry entry,
  ) {
    final item = entry.item;
    final progressText = entry.isCompleted
        ? 'Đã xem xong'
        : (entry.progressSeconds > 0 && item.durationSeconds > 0)
            ? '${BilibiliAnimeItem.formatDuration(entry.progressSeconds)} / ${item.durationText}'
            : item.durationText;
    final viewedAt = BilibiliAnimeItem.formatPubdate(entry.viewAtSeconds);

    return InkWell(
      onTap: () {
        HapticFeedback.lightImpact();
        Navigator.of(context).pop();
        widget.onOpenVideo?.call(entry);
      },
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: palette.surfaceAlt,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: palette.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Thumbnail + progress overlay
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 118,
                height: 68,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (item.cover.isNotEmpty)
                      Image.network(
                        item.cover,
                        cacheWidth: 280,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          color: palette.surface,
                          child: Icon(
                            Icons.movie_rounded,
                            color: palette.textMuted,
                          ),
                        ),
                      )
                    else
                      Container(
                        color: palette.surface,
                        child: Icon(
                          Icons.movie_rounded,
                          color: palette.textMuted,
                        ),
                      ),
                    if (item.badge.isNotEmpty)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            item.badge,
                            style: TextStyle(
                              color: palette.onColor(accent),
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    if (progressText.isNotEmpty)
                      Positioned(
                        right: 4,
                        bottom: 5,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.72),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            progressText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    if (entry.progressFraction > 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: LinearProgressIndicator(
                          value: entry.progressFraction,
                          minHeight: 2.5,
                          backgroundColor: Colors.white24,
                          valueColor: AlwaysStoppedAnimation<Color>(accent),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            // Metadata
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  widget.translateTitles
                      ? FutureBuilder<String>(
                          future: OfflineMlKitTranslator.translateHongguoTitle(
                            item.title,
                          ),
                          initialData: item.title,
                          builder: (_, snap) => Text(
                            snap.data ?? item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              height: 1.25,
                            ),
                          ),
                        )
                      : Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            height: 1.25,
                          ),
                        ),
                  if (entry.showTitle.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      entry.showTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: secondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (item.author.isNotEmpty) ...[
                        Icon(
                          Icons.person_outline_rounded,
                          size: 12,
                          color: palette.textMuted,
                        ),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(
                            item.author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.textMuted,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                      if (item.author.isNotEmpty && viewedAt.isNotEmpty)
                        Text(
                          ' · ',
                          style: TextStyle(
                            color: palette.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      if (viewedAt.isNotEmpty)
                        Text(
                          viewedAt,
                          style: TextStyle(
                            color: palette.textMuted,
                            fontSize: 11,
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
}
