import 'dart:async';

import '../../../data/model/history_item.dart';
import '../../../data/model/watch_later_item.dart';
import '../../../data/repository/history_repository.dart';
import '../../../data/repository/watch_later_repository.dart';
import '../bilibili_resolver.dart';

typedef LocalHistoryItemsLoader = Future<List<HistoryItem>> Function();
typedef WatchLaterItemsLoader = Future<List<WatchLaterItem>> Function();

/// Hồ sơ sở thích & lịch sử xem Bilibili tổng hợp từ:
/// 1) Lịch sử xem & Danh sách Xem sau ngay trong ứng dụng (không cần đăng nhập)
/// 2) Lịch sử tài khoản Bilibili & Đề xuất cá nhân (`rcmd`) khi có `SESSDATA`.
class BilibiliTasteProfile {
  final bool hasBilibiliCookie;
  final List<String> topTags;
  final List<String> topAuthors;
  final List<String> recentLocalTitles;
  final List<String> recentBiliHistoryTitles;
  final List<String> recommendSampleTitles;
  final Set<String> affinityTerms;
  final String promptSummary;
  final DateTime generatedAt;

  const BilibiliTasteProfile({
    required this.hasBilibiliCookie,
    this.topTags = const [],
    this.topAuthors = const [],
    this.recentLocalTitles = const [],
    this.recentBiliHistoryTitles = const [],
    this.recommendSampleTitles = const [],
    this.affinityTerms = const {},
    this.promptSummary = '',
    required this.generatedAt,
  });

  bool get isEmpty =>
      topTags.isEmpty &&
      topAuthors.isEmpty &&
      recentLocalTitles.isEmpty &&
      recentBiliHistoryTitles.isEmpty &&
      recommendSampleTitles.isEmpty;

  bool get hasSignals => !isEmpty;

  int get sampleCount =>
      recentLocalTitles.length +
      recentBiliHistoryTitles.length +
      recommendSampleTitles.length;

  Map<String, dynamic> toJson({bool includeRecommendSample = true}) => {
    'ok': true,
    'hasSignals': !isEmpty,
    'hasBilibiliAccountCookie': hasBilibiliCookie,
    'topTags': topTags,
    'topAuthors': topAuthors,
    'recentLocalWatchedOrSaved': recentLocalTitles,
    if (recentBiliHistoryTitles.isNotEmpty)
      'recentBilibiliAccountHistory': recentBiliHistoryTitles,
    if (includeRecommendSample && recommendSampleTitles.isNotEmpty)
      'personalizedFeedSample': recommendSampleTitles,
    'promptSummary': promptSummary,
  };
}

class BilibiliTasteService {
  final BilibiliResolver resolver;
  final LocalHistoryItemsLoader? localHistoryLoader;
  final WatchLaterItemsLoader? watchLaterLoader;

  BilibiliTasteProfile? _cachedProfile;
  String _cachedCookieKey = '';
  Future<BilibiliTasteProfile>? _inFlight;

  BilibiliTasteService({
    BilibiliResolver? resolver,
    this.localHistoryLoader,
    this.watchLaterLoader,
  }) : resolver = resolver ?? BilibiliResolver();

  BilibiliTasteProfile? get cachedProfile => _cachedProfile;

  void clearCache() {
    _cachedProfile = null;
    _cachedCookieKey = '';
  }

  static bool _isBilibiliHistoryItem(HistoryItem item) {
    final p = item.videoPath.toLowerCase();
    return p.contains('bilibili.com') ||
        p.contains('b23.tv') ||
        RegExp(r'\bBV1[0-9a-zA-Z]{9}\b', caseSensitive: false).hasMatch(item.videoPath);
  }

  static const List<({String label, List<String> keywords})> _topicBuckets = [
    (label: 'Phim AI / Hoạt hình AI (AI漫剧)', keywords: ['ai漫剧', 'ai动画', 'ai短剧', 'phim ai', '动态漫']),
    (label: 'Quốc sáng / Tu tiên / Donghua (国创)', keywords: ['修仙', '国创', '逆袭', '重生', '玄幻', 'tu tiên', 'trọng sinh', 'donghua']),
    (label: 'Anime Nhật (番剧)', keywords: ['anime', '番剧', '新番', '日漫', 'mad']),
    (label: 'Công nghệ / Lập trình / AI Tech (科技)', keywords: ['科技', '数码', '评测', 'ai', 'python', 'docker', 'nas', 'mac', 'rtx', 'công nghệ', 'review']),
    (label: 'Kiến thức / Học tập (知识)', keywords: ['知识', '教程', '科普', '原理', '源码', 'kiến thức', 'hướng dẫn', 'bài học']),
    (label: 'Game / Esports (游戏)', keywords: ['游戏', '实况', '攻略', '黑神话', '原神', 'game', 'esport']),
    (label: 'Phim tài liệu (纪录片)', keywords: ['纪录片', '历史', '宇宙', 'tài liệu', 'lịch sử']),
    (label: 'Ẩm thực / Vlog đời sống (生活)', keywords: ['美食', '做饭', '生活', 'vlog', 'ẩm thực', 'đời sống', 'mẹo']),
    (label: 'Âm nhạc (音乐)', keywords: ['音乐', 'mv', 'live', 'nhạc', 'cover']),
  ];

  Future<BilibiliTasteProfile> getTasteProfile({
    String cookie = '',
    bool forceRefresh = false,
    bool includeRecommendSample = true,
  }) {
    final cleanCookie = cookie.trim();
    final cookieKey = cleanCookie.isEmpty ? '' : cleanCookie.hashCode.toString();
    final now = DateTime.now();

    if (!forceRefresh &&
        _cachedProfile != null &&
        _cachedCookieKey == cookieKey &&
        now.difference(_cachedProfile!.generatedAt) < const Duration(minutes: 5)) {
      return Future.value(_cachedProfile!);
    }

    if (_inFlight != null && !forceRefresh && _cachedCookieKey == cookieKey) {
      return _inFlight!;
    }

    final future = _buildProfile(
      cookie: cleanCookie,
      cookieKey: cookieKey,
      includeRecommendSample: includeRecommendSample,
    );
    _inFlight = future;
    return future.whenComplete(() {
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    });
  }

  Future<BilibiliTasteProfile> _buildProfile({
    required String cookie,
    required String cookieKey,
    required bool includeRecommendSample,
  }) async {
    final localHistoryFuture = _loadLocalHistory();
    final watchLaterFuture = _loadWatchLater();
    final biliHistoryFuture = cookie.isNotEmpty
        ? resolver.getWatchHistory(pageSize: 20, cookie: cookie)
        : Future.value(const <BilibiliAnimeItem>[]);
    final rcmdFuture = (cookie.isNotEmpty && includeRecommendSample)
        ? resolver.getRecommendFeed(pageSize: 12, cookie: cookie)
        : Future.value(const <BilibiliAnimeItem>[]);

    final localItems = await localHistoryFuture;
    final wlItems = await watchLaterFuture;
    final biliHistory = await biliHistoryFuture;
    final rcmdItems = await rcmdFuture;

    final tagScores = <String, int>{};
    final authorScores = <String, int>{};
    final recentLocal = <String>[];
    final recentRemote = <String>[];
    final recommendSample = <String>[];
    final affinity = <String>{};

    void scoreText(String text, {int weight = 1}) {
      final lower = text.trim().toLowerCase();
      if (lower.isEmpty) return;
      for (final bucket in _topicBuckets) {
        if (bucket.keywords.any(lower.contains)) {
          tagScores[bucket.label] = (tagScores[bucket.label] ?? 0) + weight;
          for (final kw in bucket.keywords) {
            if (lower.contains(kw)) affinity.add(kw);
          }
        }
      }
      // Lưu các cụm chữ Hán (>=2 ký tự) hoặc từ tiếng Anh đặc trưng làm tín hiệu sở thích
      for (final m in RegExp(r'[\u4e00-\u9fff]{2,6}').allMatches(text)) {
        final tok = m.group(0)!;
        if (tok.length >= 2) affinity.add(tok.toLowerCase());
      }
    }

    for (final h in localItems.take(15)) {
      final orig = h.displayOriginalTitle;
      final vi = h.displayTranslatedTitle ?? '';
      final combined = vi.isNotEmpty && vi != orig ? '$vi ($orig)' : orig;
      if (combined.isNotEmpty && !recentLocal.contains(combined)) {
        recentLocal.add(combined);
      }
      scoreText('$orig $vi', weight: 2);
    }

    for (final w in wlItems.take(12)) {
      final label = w.translatedTitle?.trim().isNotEmpty == true
          ? '${w.translatedTitle} (${w.title})'
          : w.title;
      if (label.isNotEmpty && !recentLocal.contains(label)) {
        recentLocal.add(label);
      }
      final a = (w.author ?? '').trim();
      if (a.isNotEmpty) {
        authorScores[a] = (authorScores[a] ?? 0) + 2;
      }
      scoreText('${w.title} ${w.translatedTitle ?? ""}', weight: 2);
    }

    for (final item in biliHistory.take(18)) {
      if (item.title.isNotEmpty && !recentRemote.contains(item.title)) {
        recentRemote.add(item.title);
      }
      if (item.badge.trim().isNotEmpty) {
        final tag = item.badge.trim();
        tagScores[tag] = (tagScores[tag] ?? 0) + 3;
      }
      if (item.author.trim().isNotEmpty) {
        final a = item.author.trim();
        authorScores[a] = (authorScores[a] ?? 0) + 2;
      }
      scoreText('${item.title} ${item.badge}', weight: 2);
    }

    for (final item in rcmdItems.take(10)) {
      if (item.title.isNotEmpty && !recommendSample.contains(item.title)) {
        recommendSample.add(
          item.author.isNotEmpty ? '${item.title} [${item.author}]' : item.title,
        );
      }
      if (item.author.trim().isNotEmpty) {
        final a = item.author.trim();
        authorScores[a] = (authorScores[a] ?? 0) + 1;
      }
      scoreText(item.title, weight: 1);
    }

    final sortedTags = tagScores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final sortedAuthors = authorScores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final topTags = sortedTags.take(5).map((e) => e.key).toList();
    final topAuthors = sortedAuthors.take(5).map((e) => e.key).toList();
    final localPreview = recentLocal.take(6).toList();
    final remotePreview = recentRemote.take(6).toList();
    final rcmdPreview = recommendSample.take(5).toList();

    final summaryParts = <String>[];
    if (topTags.isNotEmpty) {
      summaryParts.add('Thể loại hay xem: ${topTags.take(4).join(", ")}');
    }
    if (topAuthors.isNotEmpty) {
      summaryParts.add('Kênh UP quen: ${topAuthors.take(3).join(", ")}');
    }
    if (localPreview.isNotEmpty) {
      summaryParts.add('Gần đây đã xem/lưu: ${localPreview.take(3).join(" ; ")}');
    } else if (remotePreview.isNotEmpty) {
      summaryParts.add('Lịch sử Bilibili: ${remotePreview.take(3).join(" ; ")}');
    }

    final profile = BilibiliTasteProfile(
      hasBilibiliCookie: cookie.isNotEmpty,
      topTags: topTags,
      topAuthors: topAuthors,
      recentLocalTitles: localPreview,
      recentBiliHistoryTitles: remotePreview,
      recommendSampleTitles: rcmdPreview,
      affinityTerms: affinity,
      promptSummary: summaryParts.join(' | '),
      generatedAt: DateTime.now(),
    );
    _cachedProfile = profile;
    _cachedCookieKey = cookieKey;
    return profile;
  }

  Future<List<HistoryItem>> _loadLocalHistory() async {
    try {
      final list = localHistoryLoader != null
          ? await localHistoryLoader!()
          : (await HistoryRepository.getInstance()).getHistory();
      return list.where(_isBilibiliHistoryItem).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<WatchLaterItem>> _loadWatchLater() async {
    try {
      final list = watchLaterLoader != null
          ? await watchLaterLoader!()
          : (await WatchLaterRepository.getInstance()).getItems();
      return list.where((w) => w.source == 'bilibili').toList();
    } catch (_) {
      return const [];
    }
  }
}
