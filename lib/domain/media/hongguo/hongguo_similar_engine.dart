import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../data/repository/watch_later_repository.dart';
import '../hongguo_resolver.dart';
import 'hongguo_cloud_account_service.dart';
import 'hongguo_discovery_service.dart';

/// Model đại diện cho một Tag / Thể loại phim Hồng Quả
class HongguoTagItem {
  final String zhTag; // Tag gốc tiếng Trung
  final String viLabel; // Nhãn tiếng Việt hiển thị trên UI
  final String? genreSlug; // Slug website nếu có
  final String? icon;
  final String group; // 'male', 'female', 'fantasy', 'theme'

  const HongguoTagItem({
    required this.zhTag,
    required this.viLabel,
    this.genreSlug,
    this.icon,
    this.group = 'theme',
  });
}

/// Kết quả phim tương tự kèm phân loại Zone và điểm số tương đồng
class SimilarDramaResult {
  final HongguoDramaItem drama;
  final int zone; // 1: Đề xuất chuẩn từ Hồng Quả / Khớp sâu, 2: Cùng chủ đề & kho, 3: Mở rộng cùng hệ
  final List<String> matchedTags;
  final double score;
  final bool fromOfficialRelated;

  const SimilarDramaResult({
    required this.drama,
    required this.zone,
    required this.matchedTags,
    required this.score,
    this.fromOfficialRelated = false,
  });
}

/// Kết quả đầy đủ cho sheet Phim tương tự & Các phần liên quan (`相关推荐` + `相关作品`).
class SimilarBundleResult {
  final List<HongguoRelatedSeasonItem> seasons;
  final List<SimilarDramaResult> similar;

  const SimilarBundleResult({
    this.seasons = const <HongguoRelatedSeasonItem>[],
    this.similar = const <SimilarDramaResult>[],
  });
}

/// Kết quả feed tab Quan tâm (kèm số lượng phim trực tiếp từ tủ theo dõi/yêu thích).
class HongguoFollowFeedResult {
  final List<HongguoDramaItem> items;
  final int directFollowCount;
  final bool isCloudLoggedIn;

  const HongguoFollowFeedResult({
    this.items = const <HongguoDramaItem>[],
    this.directFollowCount = 0,
    this.isCloudLoggedIn = false,
  });
}

/// Bộ phân tích tương đồng theo Zone và Quản lý Đề xuất cá nhân hoá cho Hồng Quả.
/// Phiên bản nâng cấp dùng trực tiếp ByteDance App API (`plan/v:version/`, `bookmall/tab/v1/`, `landpage/v/`),
/// giữ nghiêm ngặt hệ sinh thái (Người thật / Hoạt hình / Phim AI) thay vì search web trộn lẫn.
class HongguoSimilarEngine {
  static final HongguoSimilarEngine instance = HongguoSimilarEngine._internal();
  HongguoSimilarEngine._internal();

  HongguoDiscoveryService _discovery = HongguoDiscoveryService.instance;
  HongguoOfficialFeedCursor _officialFeedCursor =
      const HongguoOfficialFeedCursor();

  @visibleForTesting
  void setDiscoveryServiceForTest(HongguoDiscoveryService service) {
    _discovery = service;
  }

  /// Đặt lại con trỏ feed trang chủ khi refresh/đổi tài khoản.
  void resetFeedSession() {
    _officialFeedCursor = const HongguoOfficialFeedCursor();
  }

  // Giữ tương thích với mọi caller đang dùng `HongguoSimilarEngine.tagLabels`
  static const Map<String, String> tagLabels = kHongguoTagLabels;

  /// Danh sách curated các thể loại & tag tiêu biểu được phân nhóm
  static const List<HongguoTagItem> curatedTags = [
    // === NHÓM 1: NAM TẦN & SẢNG VĂN (MALE) ===
    HongguoTagItem(zhTag: '逆袭', viLabel: 'Nghịch tập', genreSlug: 'comeback', icon: '⚡', group: 'male'),
    HongguoTagItem(zhTag: '战神', viLabel: 'Chiến thần', genreSlug: 'action-adventure', icon: '⚔️', group: 'male'),
    HongguoTagItem(zhTag: '打脸', viLabel: 'Vả mặt', icon: '🖐️', group: 'male'),
    HongguoTagItem(zhTag: '赘婿', viLabel: 'Ở rể', icon: '👑', group: 'male'),
    HongguoTagItem(zhTag: '神医', viLabel: 'Thần y', icon: '💊', group: 'male'),
    HongguoTagItem(zhTag: '神豪', viLabel: 'Thần hào / Tỷ phú ngầm', icon: '💰', group: 'male'),
    HongguoTagItem(zhTag: '下山', viLabel: 'Cao thủ xuống núi', icon: '⛰️', group: 'male'),
    HongguoTagItem(zhTag: '无敌', viLabel: 'Vô địch thiên hạ', icon: '🔥', group: 'male'),
    HongguoTagItem(zhTag: '兵王', viLabel: 'Binh vương', icon: '🎖️', group: 'male'),
    HongguoTagItem(zhTag: '鉴宝', viLabel: 'Giám bảo / Thần nhãn', icon: '💎', group: 'male'),
    HongguoTagItem(zhTag: '逆风翻盘', viLabel: 'Lật ngược thế cờ', icon: '🔄', group: 'male'),
    HongguoTagItem(zhTag: '家族振兴', viLabel: 'Hưng thịnh gia tộc', genreSlug: 'clan', icon: '🏰', group: 'male'),

    // === NHÓM 2: NỮ TẦN & HÀO MÔN (FEMALE) ===
    HongguoTagItem(zhTag: '豪门', viLabel: 'Hào môn', genreSlug: 'wealthy-family', icon: '💎', group: 'female'),
    HongguoTagItem(zhTag: '总裁', viLabel: 'Tổng tài bá đạo', icon: '👔', group: 'female'),
    HongguoTagItem(zhTag: '马甲', viLabel: 'Mã giáp / Thân phận ngầm', icon: '🎭', group: 'female'),
    HongguoTagItem(zhTag: '真假千金', viLabel: 'Thật giả thiên kim', icon: '👯', group: 'female'),
    HongguoTagItem(zhTag: '甜宠', viLabel: 'Ngọt sủng', genreSlug: 'romance', icon: '🍬', group: 'female'),
    HongguoTagItem(zhTag: '先婚后爱', viLabel: 'Cưới trước yêu sau', icon: '💍', group: 'female'),
    HongguoTagItem(zhTag: '读心术', viLabel: 'Đọc tâm thuật', icon: '🧠', group: 'female'),
    HongguoTagItem(zhTag: '萌宝', viLabel: 'Manh bảo / Nuôi con', genreSlug: 'cute-kids', icon: '🍼', group: 'female'),
    HongguoTagItem(zhTag: '团宠', viLabel: 'Đoàn sủng', icon: '👑', group: 'female'),
    HongguoTagItem(zhTag: '虐恋', viLabel: 'Ngược luyến', icon: '💔', group: 'female'),
    HongguoTagItem(zhTag: '追妻', viLabel: 'Truy thê / Giữ vợ', icon: '🏃‍♂️', group: 'female'),
    HongguoTagItem(zhTag: '大女主', viLabel: 'Đại nữ chủ / Nữ cường', icon: '👠', group: 'female'),
    HongguoTagItem(zhTag: '闪婚', viLabel: 'Cưới chớp nhoáng', icon: '⚡', group: 'female'),
    HongguoTagItem(zhTag: '白月光', viLabel: 'Bạch nguyệt quang', icon: '🌙', group: 'female'),
    HongguoTagItem(zhTag: '破镜重圆', viLabel: 'Gương vỡ lại lành', icon: '🕊️', group: 'female'),
    HongguoTagItem(zhTag: '宫斗宅斗', viLabel: 'Cung đấu trạch đấu', icon: '🏮', group: 'female'),

    // === NHÓM 3: VIỄN TƯỞNG & NÃO ĐỘNG (FANTASY) ===
    HongguoTagItem(zhTag: '重生', viLabel: 'Trọng sinh', icon: '⏳', group: 'fantasy'),
    HongguoTagItem(zhTag: '穿越', viLabel: 'Xuyên không', icon: '🌀', group: 'fantasy'),
    HongguoTagItem(zhTag: '系统', viLabel: 'Hệ thống', genreSlug: 'creative', icon: '⚙️', group: 'fantasy'),
    HongguoTagItem(zhTag: '脑洞', viLabel: 'Não động sáng tạo', genreSlug: 'creative', icon: '💡', group: 'fantasy'),
    HongguoTagItem(zhTag: '玄幻', viLabel: 'Tu tiên / Huyền huyễn', genreSlug: 'fantasy', icon: '✨', group: 'fantasy'),
    HongguoTagItem(zhTag: '末世', viLabel: 'Mạt thế / Sinh tồn', genreSlug: 'apocalypse', icon: '☣️', group: 'fantasy'),
    HongguoTagItem(zhTag: '科幻', viLabel: 'Khoa huyễn', genreSlug: 'sci-fi', icon: '🚀', group: 'fantasy'),
    HongguoTagItem(zhTag: '异能', viLabel: 'Dị năng', icon: '⚡', group: 'fantasy'),
    HongguoTagItem(zhTag: '空间', viLabel: 'Không gian tùy thân', icon: '📦', group: 'fantasy'),
    HongguoTagItem(zhTag: '无限流', viLabel: 'Vô hạn lưu', icon: '🔁', group: 'fantasy'),

    // === NHÓM 4: BỐI CẢNH & THỂ TÀI (THEME) ===
    HongguoTagItem(zhTag: '古装', viLabel: 'Cổ trang', genreSlug: 'costume', icon: '🏯', group: 'theme'),
    HongguoTagItem(zhTag: '都市', viLabel: 'Đô thị', genreSlug: 'urban', icon: '🏙️', group: 'theme'),
    HongguoTagItem(zhTag: '年代', viLabel: 'Niên đại', genreSlug: 'period', icon: '📻', group: 'theme'),
    HongguoTagItem(zhTag: '悬疑', viLabel: 'Hồi hộp / Trinh thám', genreSlug: 'suspense', icon: '🔍', group: 'theme'),
    HongguoTagItem(zhTag: '喜剧', viLabel: 'Hài hước', genreSlug: 'comedy', icon: '😂', group: 'theme'),
    HongguoTagItem(zhTag: '志怪', viLabel: 'Linh dị / Huyền bí', genreSlug: 'supernatural', icon: '👻', group: 'theme'),
    HongguoTagItem(zhTag: '动作冒险', viLabel: 'Hành động phiêu lưu', genreSlug: 'action-adventure', icon: '💥', group: 'theme'),
    HongguoTagItem(zhTag: '爱情', viLabel: 'Tình cảm', genreSlug: 'romance', icon: '❤️', group: 'theme'),
    HongguoTagItem(zhTag: '家庭', viLabel: 'Gia đình', genreSlug: 'family', icon: '🏡', group: 'theme'),
    HongguoTagItem(zhTag: '种田', viLabel: 'Điền văn / Làm nông', icon: '🌾', group: 'theme'),
    HongguoTagItem(zhTag: '校园', viLabel: 'Học đường', genreSlug: 'youth', icon: '🎓', group: 'theme'),
    HongguoTagItem(zhTag: '青春', viLabel: 'Thanh xuân học đường', genreSlug: 'youth', icon: '🎓', group: 'theme'),
    HongguoTagItem(zhTag: '灾难', viLabel: 'Thảm họa', genreSlug: 'disaster', icon: '🌋', group: 'theme'),
    HongguoTagItem(zhTag: '复仇', viLabel: 'Báo thù', icon: '⚔️', group: 'theme'),
  ];

  /// Lấy nhãn tiếng Việt cho 1 tag tiếng Trung.
  static String getTagLabel(String tag) => translateHongguoTag(tag);

  /// Trích xuất danh sách tag từ một bộ phim (nếu detail.tags rỗng, phân tích từ title và intro).
  List<String> extractTagsFromDrama({
    required List<String> tags,
    required String title,
    required String intro,
  }) {
    final result = <String>{};
    for (final t in tags) {
      if (t.trim().isNotEmpty) result.add(t.trim());
    }

    final combinedText = '$title $intro';
    for (final key in tagLabels.keys) {
      if (key.length >= 2 && combinedText.contains(key)) {
        result.add(key);
      }
    }

    if (result.isEmpty) {
      result.add('剧情');
    }

    return result.toList();
  }

  /// Lấy cả Các phần/mùa liên quan (`show_type == 547`) VÀ danh sách Đề xuất tương tự (`506` `猜你喜欢`)
  /// đồng nhất cùng hệ sinh thái phim (AI -> AI, Hoạt hình -> Hoạt hình, Người thật -> Người thật).
  Future<SimilarBundleResult> findSimilarBundle({
    required HongguoDramaDetail detail,
    int maxResults = 30,
  }) async {
    final currentTags = extractTagsFromDrama(
      tags: detail.tags,
      title: detail.title,
      intro: detail.intro,
    );
    final currentSid = detail.seriesId;

    var expectedSource = detail.sourceCategory;
    if (expectedSource.isEmpty) {
      expectedSource = HongguoResolver.inferSourceCategoryFromIds(
        detail.categoryIds,
        tags: currentTags,
      );
    }

    // 1. Gọi thẳng API đề xuất liên quan của ByteDance: /reading/bookapi/plan/v:version/ (scene=10)
    final bundle = await _discovery.fetchRelatedAndSimilar(
      currentSid,
      sourceCategory: expectedSource,
      categoryIds: detail.categoryIds,
      tags: currentTags,
    );

    final candidateMap = <String, HongguoDramaItem>{};
    final officialIds = <String>{};

    for (final item in bundle.similarDramas) {
      if (item.seriesId == currentSid) continue;
      // Nếu server chưa gắn sourceCategory, suy luận lại từ categoryIds hoặc kế thừa nguồn đang xem
      final fixedSource = item.sourceCategory.isNotEmpty
          ? item.sourceCategory
          : expectedSource;
      candidateMap[item.seriesId] = item.copyWith(sourceCategory: fixedSource);
      officialIds.add(item.seriesId);
    }

    // 2. Nếu danh sách server trả về < 15 bộ, bổ sung thêm bằng landpage CÙNG LOẠI PHIM + ĐÚNG TRỤC TAG
    if (candidateMap.length < 15) {
      final anchorTag = currentTags.isNotEmpty ? currentTags.first : '';
      final sel = _discovery.resolveSelectionForTag(
        anchorTag,
        preferredSourceCategory: expectedSource,
        categoryIds: detail.categoryIds,
        allDramaTags: currentTags,
      );
      // Kết hợp thêm tag thứ 2 nếu rơi vào trục khác (vd: tag1=爱情 -> gender=0, tag2=校园 -> epoch=cate_4)
      var combinedSel = sel;
      for (final extraTag in currentTags.skip(1).take(3)) {
        final extraSel = _discovery.resolveSelectionForTag(
          extraTag,
          preferredSourceCategory: expectedSource,
          categoryIds: detail.categoryIds,
          allDramaTags: currentTags,
        );
        for (final entry in extraSel.filters.entries) {
          if (entry.key == 'sort') continue;
          if (combinedSel.valueOf(entry.key).isEmpty) {
            combinedSel = combinedSel.withFilter(entry.key, entry.value);
          }
        }
      }

      try {
        final discoveryPage = await _discovery.fetchDiscovery(
          combinedSel,
          seenIds: <String>{currentSid, ...candidateMap.keys},
        );
        for (final item in discoveryPage.items) {
          if (item.seriesId != currentSid && !candidateMap.containsKey(item.seriesId)) {
            candidateMap[item.seriesId] = item;
          }
        }
      } catch (_) {}

      // Nếu kết hợp đa trục quá hẹp (chỉ < 6 kết quả), nới lỏng giữ đúng Kho + Bối cảnh/Đối tượng
      if (candidateMap.length < 6) {
        try {
          final broader = await _discovery.fetchDiscovery(
            sel,
            seenIds: <String>{currentSid, ...candidateMap.keys},
          );
          for (final item in broader.items) {
            if (item.seriesId != currentSid && !candidateMap.containsKey(item.seriesId)) {
              candidateMap[item.seriesId] = item;
            }
          }
        } catch (_) {}
      }
    }

    // 3. Chấm điểm & chia Zone (ưu tiên tối đa phim từ 猜你喜欢 cùng hệ sinh thái)
    final scoredList = <SimilarDramaResult>[];
    final primaryTag = currentTags.isNotEmpty ? currentTags.first : '';

    for (final candidate in candidateMap.values) {
      final isOfficial = officialIds.contains(candidate.seriesId);
      final candTags = extractTagsFromDrama(
        tags: candidate.tags,
        title: candidate.title,
        intro: candidate.intro,
      );

      final matched = <String>[];
      for (final t in candTags) {
        if (currentTags.contains(t) && !matched.contains(t)) {
          matched.add(t);
        }
      }

      double score = matched.length * 10.0;
      if (isOfficial) score += 50.0;

      final hasPrimaryMatch =
          primaryTag.isNotEmpty && candTags.contains(primaryTag);
      if (hasPrimaryMatch) score += 15.0;

      final titleOverlap = _hasKeywordOverlap(detail.title, candidate.title);
      if (titleOverlap) score += 8.0;

      final sameEcosystem = expectedSource.isEmpty ||
          candidate.sourceCategory.isEmpty ||
          candidate.sourceCategory == expectedSource;
      if (sameEcosystem) {
        score += 20.0;
      } else {
        score -= 40.0;
      }

      int zone = 3;
      if (isOfficial || (sameEcosystem && matched.length >= 2)) {
        zone = 1;
      } else if (sameEcosystem && (hasPrimaryMatch || matched.isNotEmpty)) {
        zone = 2;
      }

      scoredList.add(
        SimilarDramaResult(
          drama: candidate,
          zone: zone,
          matchedTags: matched.isNotEmpty ? matched : candTags.take(3).toList(),
          score: score,
          fromOfficialRelated: isOfficial,
        ),
      );
    }

    scoredList.sort((a, b) {
      if (a.zone != b.zone) return a.zone.compareTo(b.zone);
      return b.score.compareTo(a.score);
    });

    return SimilarBundleResult(
      seasons: bundle.seasons,
      similar: scoredList.take(maxResults).toList(),
    );
  }

  /// Tìm danh sách phim tương tự theo Zone (giữ tương thích chữ ký cũ).
  Future<List<SimilarDramaResult>> findSimilarDramas({
    required HongguoDramaDetail detail,
    int maxResults = 30,
  }) async {
    final res = await findSimilarBundle(detail: detail, maxResults: maxResults);
    return res.similar;
  }

  bool _hasKeywordOverlap(String t1, String t2) {
    if (t1.isEmpty || t2.isEmpty) return false;
    final clean1 = t1.replaceAll(RegExp(r'[\s\p{P}]', unicode: true), '');
    final clean2 = t2.replaceAll(RegExp(r'[\s\p{P}]', unicode: true), '');

    for (var i = 0; i < clean1.length - 1; i++) {
      final sub = clean1.substring(i, i + 2);
      if (clean2.contains(sub)) return true;
    }
    return false;
  }

  // ==========================================
  // HỆ THỐNG GHI NHẬN SỞ THÍCH CÁ NHÂN HÓA
  // ==========================================

  static const String _prefTagScoresKey = 'hongguo_user_tag_scores';

  /// Ghi nhận điểm sở thích của người dùng khi có tương tác.
  Future<void> recordInterest(List<String> tags, double points) async {
    if (tags.isEmpty || points == 0) return;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_prefTagScoresKey);
      Map<String, dynamic> scoreMap = {};
      if (raw != null && raw.isNotEmpty) {
        try {
          scoreMap = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {}
      }

      for (final tag in tags) {
        final current = (scoreMap[tag] as num?)?.toDouble() ?? 0.0;
        scoreMap[tag] = (current + points).clamp(0.0, 500.0);
      }

      await sp.setString(_prefTagScoresKey, jsonEncode(scoreMap));
    } catch (_) {}
  }

  /// Lấy Top các thể loại người dùng xem nhiều nhất.
  Future<List<String>> getTopFavoriteTags({int limit = 4}) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_prefTagScoresKey);
      if (raw == null || raw.isEmpty) return [];

      final scoreMap = jsonDecode(raw) as Map<String, dynamic>;
      final sortedEntries = scoreMap.entries.toList()
        ..sort(
          (a, b) =>
              ((b.value as num).toDouble()).compareTo((a.value as num).toDouble()),
        );

      return sortedEntries.take(limit).map((e) => e.key).toList();
    } catch (_) {
      return [];
    }
  }

  /// Tạo luồng Shorts đề xuất chuẩn từ ByteDance Official Account API (`bookmall/tab/v1/` -> `cell/change/v1/`),
  /// hoặc lấy luồng tự nhiên cá nhân hóa theo kho nếu `preferredKind` được chỉ định (không trộn thuật toán local).
  Future<List<HongguoDramaItem>> getPersonalizedDiscoverList({
    Set<String>? excludedSeriesIds,
    HongguoGenreKind? preferredKind,
    bool resetCursor = false,
  }) async {
    if (resetCursor) {
      resetFeedSession();
    }
    final seenIds = <String>{...?excludedSeriesIds};
    try {
      final prefs = await SharedPreferences.getInstance();
      seenIds.addAll(prefs.getStringList('hongguo_seen_series_ids') ?? []);
    } catch (_) {}

    final result = <HongguoDramaItem>[];
    final localSeen = <String>{...seenIds};

    // Nếu khóa 1 kho cụ thể (vd chỉ AI / chỉ Hoạt hình / chỉ Người thật) -> gọi landpage luồng mặc định (sort: [])
    // để server ByteDance trả đề xuất cá nhân hóa theo tài khoản Hồng Quả.
    if (preferredKind != null) {
      try {
        final page = await _discovery.fetchDiscovery(
          HongguoDiscoverySelection(genreKind: preferredKind),
          seenIds: localSeen,
          useDefaultFeedSort: true,
        );
        for (final item in page.items) {
          if (localSeen.add(item.seriesId)) {
            result.add(item);
          }
        }
      } catch (_) {}
      return result;
    }

    // Chế độ mặc định ("Dành cho bạn"): gọi trực tiếp feed trang chủ chính thức theo tài khoản Hồng Quả
    try {
      _officialFeedCursor = _officialFeedCursor.copyWith(
        seenIds: <String>{..._officialFeedCursor.seenIds, ...seenIds},
      );
      final officialPage = await _discovery.fetchOfficialRecommendations(
        cursor: _officialFeedCursor,
      );
      _officialFeedCursor = officialPage.nextCursor;
      for (final item in officialPage.items) {
        if (localSeen.add(item.seriesId)) {
          result.add(item);
        }
      }
    } catch (_) {}

    return result;
  }

  /// Lấy luồng phim cho tab Quan tâm (`关注`):
  /// 1. Tổng hợp phim Yêu thích Cloud, Đặt trước đã lên sóng và Tủ Xem sau Hồng Quả.
  /// 2. Mở rộng tiếp bằng đề xuất liên quan chính thức (`/reading/bookapi/plan/v:version/`)
  ///    từ chính các phim đang theo dõi; bổ sung Đề xuất cá nhân hóa khi danh sách ít.
  Future<HongguoFollowFeedResult> getFollowFeedList({
    Set<String>? excludedSeriesIds,
    int seedOffset = 0,
  }) async {
    final excluded = <String>{...?excludedSeriesIds};
    final result = <HongguoDramaItem>[];
    final localSeen = <String>{...excluded};
    final seedIds = <String>[];
    final numericId = RegExp(r'^[0-9]{1,30}$');

    final cloud = HongguoCloudAccountService.instance;
    final isLoggedIn = cloud.state.value.isLoggedIn;
    if (isLoggedIn && cloud.state.value.favorites.isEmpty) {
      try {
        await cloud.refreshFavorites();
      } catch (_) {}
    }

    final state = cloud.state.value;
    void collectSeed(String id, HongguoDramaItem item) {
      if (!numericId.hasMatch(id)) return;
      if (!seedIds.contains(id)) seedIds.add(id);
      if (localSeen.add(id)) {
        result.add(item);
      }
    }

    for (final fav in state.favorites) {
      collectSeed(
        fav.seriesId,
        HongguoDramaItem(
          seriesId: fav.seriesId,
          title: fav.title,
          cover: fav.cover,
          episodeCount: fav.totalEpisodes,
          intro: fav.badge,
        ),
      );
    }

    for (final res in state.onlineReservations) {
      collectSeed(
        res.seriesId,
        HongguoDramaItem(
          seriesId: res.seriesId,
          title: res.title,
          cover: res.cover,
          episodeCount: 0,
          intro: res.badge,
        ),
      );
    }

    try {
      final repo = await WatchLaterRepository.getInstance();
      for (final wl in repo.getItems()) {
        if (!wl.isHongguo) continue;
        final sid = (wl.seriesId?.trim().isNotEmpty == true
                ? wl.seriesId!
                : wl.targetUrl)
            .replaceAll(RegExp(r'^hg_'), '')
            .trim();
        collectSeed(
          sid,
          HongguoDramaItem(
            seriesId: sid,
            title: wl.displayTitle,
            cover: wl.coverUrl ?? '',
            episodeCount: wl.totalEpisodes ?? 0,
          ),
        );
      }
    } catch (_) {}

    final directCount = result.length;

    // Mở rộng thêm phim tương tự sát gu từ chính các bộ người dùng đã theo dõi.
    if (seedIds.isNotEmpty) {
      final count = min(3, seedIds.length);
      for (var i = 0; i < count; i++) {
        final seed = seedIds[(seedOffset + i) % seedIds.length];
        try {
          final bundle = await _discovery.fetchRelatedAndSimilar(seed);
          for (final related in bundle.similarDramas) {
            if (localSeen.add(related.seriesId)) {
              result.add(related);
            }
          }
        } catch (_) {}
      }
    }

    // Fallback nhẹ nếu user chưa theo dõi đủ phim để lướt liên tục không bị trống.
    if (result.length < 10) {
      try {
        final extra = await getPersonalizedDiscoverList(
          excludedSeriesIds: localSeen,
        );
        for (final item in extra) {
          if (localSeen.add(item.seriesId)) {
            result.add(item);
          }
        }
      } catch (_) {}
    }

    return HongguoFollowFeedResult(
      items: result,
      directFollowCount: directCount,
      isCloudLoggedIn: isLoggedIn,
    );
  }
}
