import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import '../hongguo_resolver.dart';

/// Kết quả phim tương tự kèm phân loại Zone và điểm số tương đồng
/// Model đại diện cho một Tag / Thể loại phim Hồng Quả
class HongguoTagItem {
  final String zhTag;       // Tag gốc tiếng Trung (dùng khi truy vấn, lọc, search ngầm)
  final String viLabel;     // Nhãn tiếng Việt hiển thị trên UI
  final String? genreSlug;  // Slug chính thức của Hongguo nếu có (vd: 'costume', 'comeback', 'clan'...)
  final String? icon;       // Icon emoji trực quan
  final String group;       // Nhóm: 'male' (Nam tần), 'female' (Nữ tần), 'fantasy' (Viễn tưởng), 'theme' (Bối cảnh/Thể loại)

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
  final int zone; // 1: Cực kỳ giống (High match), 2: Cùng chủ đề (Medium match), 3: Mở rộng (Broad match)
  final List<String> matchedTags;
  final double score;

  const SimilarDramaResult({
    required this.drama,
    required this.zone,
    required this.matchedTags,
    required this.score,
  });
}

/// Bộ phân tích tương đồng theo Zone và Quản lý Đề xuất cá nhân hoá cho Hồng Quả
class HongguoSimilarEngine {
  static final HongguoSimilarEngine instance = HongguoSimilarEngine._internal();
  HongguoSimilarEngine._internal();

  final HongguoResolver _resolver = HongguoResolver();

  // Bảng từ điển toàn diện ánh xạ tag tiếng Trung (Hồng Quả / Douyin) sang tiếng Việt
  static const Map<String, String> tagLabels = {
    // --- Bối cảnh & Thể tài chính (Hongguo Categories & Genres) ---
    '古装': 'Cổ trang',
    '都市': 'Đô thị',
    '现代': 'Hiện đại',
    '古代': 'Cổ đại',
    '年代': 'Niên đại',
    '民国': 'Dân quốc',
    '乡村': 'Nông thôn',
    '种田': 'Điền văn / Làm nông',
    '校园': 'Học đường',
    '青春': 'Thanh xuân',
    '家庭': 'Gia đình',
    '家庭伦理': 'Gia đình luân lý',
    '职场': 'Công sở',
    '商战': 'Thương chiến',
    '剧情': 'Chính kịch / Tâm lý',
    '成长': 'Trưởng thành',
    '女性成长': 'Nữ tính trưởng thành',
    '小人物': 'Tiểu nhân vật',
    '综艺': 'Tạp kỹ / Gameshow',

    // --- Nam tần & Sảng văn (Nghịch tập, Chiến thần, Vô địch) ---
    '逆袭': 'Nghịch tập',
    '逆风翻盘': 'Lật ngược thế cờ',
    '战神': 'Chiến thần',
    '战王': 'Chiến vương',
    '兵王': 'Binh vương',
    '龙王': 'Long vương',
    '修罗': 'Tu la',
    '赘婿': 'Ở rể',
    '神医': 'Thần y',
    '神豪': 'Thần hào / Tỷ phú ngầm',
    '鉴宝': 'Giám bảo / Thần nhãn',
    '下山': 'Xuống núi',
    '无敌': 'Vô địch thiên hạ',
    '大男主': 'Đại nam chủ',
    '升级流': 'Nâng cấp tu luyện',
    '极品': 'Cực phẩm',
    '打脸': 'Vả mặt',
    '打脸反派': 'Vả mặt phản diện',
    '虐渣': 'Trị tra nam tiện nữ',
    '复仇': 'Báo thù',
    '家族振兴': 'Hưng thịnh gia tộc',

    // --- Nữ tần & Hào môn (Tổng tài, Tình cảm, Trạch đấu) ---
    '豪门': 'Hào môn',
    '家族': 'Gia tộc',
    '总裁': 'Tổng tài',
    '霸总': 'Bá đạo tổng tài',
    '千金': 'Thiên kim',
    '真假千金': 'Thật giả thiên kim',
    '马甲': 'Mã giáp / Thân phận ngầm',
    '大女主': 'Đại nữ chủ',
    '女强': 'Nữ cường',
    '萌宝': 'Manh bảo',
    '带球跑': 'Mang thai bỏ trốn',
    '团宠': 'Đoàn sủng',
    '甜宠': 'Ngọt sủng',
    '爱情': 'Tình cảm',
    '恋爱': 'Yêu đương',
    '都市爱情': 'Đô thị ái tình',
    '古风爱情': 'Cổ phong ái tình',
    '先婚后爱': 'Cưới trước yêu sau',
    '闪婚': 'Cưới chớp nhoáng',
    '契约': 'Hợp đồng hôn nhân',
    '虐恋': 'Ngược luyến',
    '追妻': 'Truy thê / Tìm lại vợ',
    '破镜重圆': 'Gương vỡ lại lành',
    '双向救赎': 'Song hướng cứu rỗi',
    '日久生情': 'Lâu ngày sinh tình',
    '暗恋成真': 'Thầm yêu thành thật',
    '故人重逢': 'Cố nhân trùng phùng',
    '替身': 'Thế thân',
    '白月光': 'Bạch nguyệt quang',
    '读心术': 'Đọc tâm thuật',
    '宫斗': 'Cung đấu',
    '宅斗': 'Trạch đấu',
    '宫斗宅斗': 'Cung đấu trạch đấu',
    '宫廷': 'Cung đình',

    // --- Viễn tưởng, Huyền huyễn & Não động ---
    '重生': 'Trọng sinh',
    '重生逆袭': 'Trọng sinh nghịch tập',
    '穿越': 'Xuyên không',
    '穿书': 'Xuyên sách',
    '系统': 'Hệ thống',
    '脑洞': 'Não động / Sáng tạo',
    '脑  洞': 'Não động',
    '无限流': 'Vô hạn lưu',
    '修仙': 'Tu tiên',
    '修真': 'Tu chân',
    '玄幻': 'Huyền huyễn',
    '仙侠': 'Tiên hiệp',
    '异能': 'Dị năng',
    '异界': 'Dị giới',
    '末世': 'Mạt thế',
    '求生': 'Sinh tồn',
    '科幻': 'Khoa huyễn',
    '奇幻': 'Kỳ ảo',
    '空间': 'Không gian tùy thân',
    '囤货': 'Tích trữ vật tư',

    // --- Trinh thám, Linh dị & Cảm xúc mạnh ---
    '悬疑': 'Hồi hộp / Trinh thám',
    '悬疑情感': 'Trinh thám tình cảm',
    '探案': 'Phá án',
    '犯罪': 'Tội phạm',
    '反转': 'Quay xe / Bất ngờ',
    '惊悚': 'Giật gân',
    '恐怖': 'Kinh dị',
    '灵异': 'Linh dị / Huyền bí',
    '玄学': 'Huyền học / Phong thủy',
    '志怪': 'Chí quái / Yêu ma',
    '诡秘': 'Quỷ bí',
    '盗墓': 'Đạo mộ',
    '灾难': 'Thảm họa',
    '战争': 'Chiến tranh',
    '热血': 'Nhiệt huyết',
    '动作': 'Hành động',
    '动作冒险': 'Hành động phiêu lưu',
    '冒险': 'Phiêu lưu',
    '传奇': 'Truyền kỳ',
    '偏门传奇': 'Kỳ nhân dị sĩ',
    '喜剧': 'Hài hước',
    '搞笑': 'Gây cười',
    '轻喜剧': 'Hài nhẹ nhàng',

    // --- Thẻ Bảng xếp hạng / Dạng phim ---
    '真人剧': 'Người thật',
    '动态漫': 'Hoạt hình',
    '漫画': 'Truyện tranh',
    'AI短剧': 'Phim AI',
    '热播榜': 'Thịnh hành',
    '红果热播榜': 'Bảng Hot Hồng Quả',
    '真人剧热播榜': 'Hot Người Thật',
    '漫剧热播榜': 'Hot Hoạt Hình',
    'AI剧热播榜': 'Hot Phim AI',
    '新剧': 'Phim mới ra mắt',
    '全部': 'Tất cả',
  };

  /// Danh sách curated các thể loại & tag tiêu biểu được phân nhóm cho Sheet chọn
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
    HongguoTagItem(zhTag: '青春', viLabel: 'Thanh xuân học đường', genreSlug: 'youth', icon: '🎓', group: 'theme'),
    HongguoTagItem(zhTag: '灾难', viLabel: 'Thảm họa', genreSlug: 'disaster', icon: '🌋', group: 'theme'),
    HongguoTagItem(zhTag: '复仇', viLabel: 'Báo thù', icon: '⚔️', group: 'theme'),
  ];

  /// Lấy nhãn tiếng Việt cho 1 tag tiếng Trung (lọc bỏ ký tự thừa, tìm trong từ điển)
  static String getTagLabel(String tag) {
    var clean = tag.replaceAll(RegExp(r'[\[\]#\s]'), '').trim();
    if (tagLabels.containsKey(clean)) {
      return tagLabels[clean]!;
    }
    for (final entry in tagLabels.entries) {
      if (clean == entry.key) return entry.value;
    }
    return clean.isEmpty ? tag : clean;
  }

  /// Trích xuất danh sách tag từ một bộ phim (nếu detail.tags rỗng, phân tích từ title và intro)
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
      if (combinedText.contains(key)) {
        result.add(key);
      }
    }

    // Nếu vẫn rỗng, thêm mặc định
    if (result.isEmpty) {
      result.add('都市'); // Mặc định đô thị
    }

    return result.toList();
  }

  /// Tìm danh sách phim tương tự theo Zone:
  /// - Zone 1: Trùng từ 2 tag trở lên HOẶC trùng tag chính + từ khóa tên phim
  /// - Zone 2: Trùng tag chính hoặc 1 tag phụ quan trọng
  /// - Zone 3: Mở rộng / Đa dạng liên quan (cùng phong cách hoặc thể loại liên kết)
  Future<List<SimilarDramaResult>> findSimilarDramas({
    required HongguoDramaDetail detail,
    int maxResults = 30,
  }) async {
    final currentTags = extractTagsFromDrama(
      tags: detail.tags,
      title: detail.title,
      intro: detail.intro,
    );

    final currentSid = detail.seriesId;
    final candidateMap = <String, HongguoDramaItem>{};

    // 1. Thu thập ứng viên bằng cách tìm kiếm theo các tag chính
    // Lấy tối đa 3 tag đầu để tìm kiếm (tránh spam network)
    final searchTags = currentTags.take(3).toList();
    for (final tag in searchTags) {
      try {
        final list = await _resolver.search(tag);
        for (final item in list) {
          if (item.seriesId != currentSid) {
            candidateMap[item.seriesId] = item;
          }
        }
      } catch (_) {}
    }

    // Nếu ứng viên còn ít, bổ sung thêm từ Đề xuất ngẫu nhiên để có đủ dữ liệu so sánh
    if (candidateMap.length < 15) {
      try {
        final rec = await _resolver.getRandomRecommendations();
        for (final item in rec.items) {
          if (item.seriesId != currentSid) {
            candidateMap[item.seriesId] = item;
          }
        }
      } catch (_) {}
    }

    // 2. Chấm điểm và phân chia Zone cho từng ứng viên
    final scoredList = <SimilarDramaResult>[];
    final primaryTag = currentTags.isNotEmpty ? currentTags.first : '';

    for (final candidate in candidateMap.values) {
      final candTags = extractTagsFromDrama(
        tags: candidate.tags,
        title: candidate.title,
        intro: candidate.intro,
      );

      // Tìm các tag trùng khớp
      final matched = <String>[];
      for (final t in candTags) {
        if (currentTags.contains(t)) {
          matched.add(t);
        }
      }

      double score = matched.length * 10.0;

      // Ưu tiên cao nếu trùng Tag chính (Primary Tag)
      final hasPrimaryMatch = primaryTag.isNotEmpty && candTags.contains(primaryTag);
      if (hasPrimaryMatch) {
        score += 15.0;
      }

      // Kiểm tra trùng từ khóa trong tiêu đề
      final titleOverlap = _hasKeywordOverlap(detail.title, candidate.title);
      if (titleOverlap) {
        score += 8.0;
      }

      // Xác định Zone theo yêu cầu người dùng:
      // Zone 1 (Sát nhất): Trùng >= 2 tags HOẶC (trùng tag chính + từ khóa tương đồng)
      // Zone 2 (Sát vừa): Trùng 1 tag chính hoặc 1 tag phụ
      // Zone 3 (Xa hơn / Đa dạng): Các phim còn lại
      int zone = 3;
      if (matched.length >= 2 || (hasPrimaryMatch && (titleOverlap || score >= 20))) {
        zone = 1;
      } else if (hasPrimaryMatch || matched.isNotEmpty || score >= 10) {
        zone = 2;
      } else {
        zone = 3;
      }

      scoredList.add(
        SimilarDramaResult(
          drama: candidate,
          zone: zone,
          matchedTags: matched,
          score: score,
        ),
      );
    }

    // Sắp xếp: Zone 1 trước, sau đó Zone 2, sau đó Zone 3; trong cùng Zone sắp theo điểm số giảm dần
    scoredList.sort((a, b) {
      if (a.zone != b.zone) {
        return a.zone.compareTo(b.zone);
      }
      return b.score.compareTo(a.score);
    });

    return scoredList.take(maxResults).toList();
  }

  bool _hasKeywordOverlap(String t1, String t2) {
    if (t1.isEmpty || t2.isEmpty) return false;
    final clean1 = t1.replaceAll(RegExp(r'[\s\p{P}]', unicode: true), '');
    final clean2 = t2.replaceAll(RegExp(r'[\s\p{P}]', unicode: true), '');

    // Tìm cụm 2 ký tự trùng nhau
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

  /// Ghi nhận điểm sở thích của người dùng khi có tương tác
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

  /// Lấy Top các thể loại người dùng xem nhiều nhất
  Future<List<String>> getTopFavoriteTags({int limit = 4}) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_prefTagScoresKey);
      if (raw == null || raw.isEmpty) return [];

      final scoreMap = jsonDecode(raw) as Map<String, dynamic>;
      final sortedEntries = scoreMap.entries.toList()
        ..sort((a, b) => ((b.value as num).toDouble()).compareTo((a.value as num).toDouble()));

      return sortedEntries.take(limit).map((e) => e.key).toList();
    } catch (_) {
      return [];
    }
  }

  /// Tạo luồng Shorts đề xuất kết hợp tỷ lệ vàng:
  /// - 50% Gu yêu thích của bạn
  /// - 30% Siêu phẩm Hot Trend
  /// - 20% Khám phá mới lạ & Deep Explore
  Future<List<HongguoDramaItem>> getPersonalizedDiscoverList({
    Set<String>? excludedSeriesIds,
  }) async {
    final topTags = await getTopFavoriteTags();
    final rng = Random();
    final result = <HongguoDramaItem>[];
    final seenIds = <String>{};

    try {
      final prefs = await SharedPreferences.getInstance();
      final historySeen = prefs.getStringList('hongguo_seen_series_ids') ?? [];
      seenIds.addAll(historySeen);
    } catch (_) {}
    if (excludedSeriesIds != null) {
      seenIds.addAll(excludedSeriesIds);
    }

    void addUnique(List<HongguoDramaItem> list, int maxAdd) {
      var added = 0;
      for (final item in list) {
        if (added >= maxAdd) break;
        if (!seenIds.contains(item.seriesId)) {
          seenIds.add(item.seriesId);
          result.add(item);
          added++;
        }
      }
    }

    // 1. Lấy từ Top Tag yêu thích (nếu người dùng đã có lịch sử)
    if (topTags.isNotEmpty) {
      final sampleCount = min(2, topTags.length);
      final pickedTags = List<String>.from(topTags)..shuffle(rng);
      for (var i = 0; i < sampleCount; i++) {
        try {
          final tagList = await _resolver.search(pickedTags[i]);
          final shuffled = List<HongguoDramaItem>.from(tagList)..shuffle(rng);
          addUnique(shuffled, 5);
        } catch (_) {}
      }
    }

    // 2. Lấy từ Bảng xếp hạng Hot Trend (luân phiên cả 2 bảng rank)
    try {
      final rankCategories = ['rank/hot-drama', 'rank/hot-real-drama'];
      final pickedCategory = rankCategories[rng.nextInt(rankCategories.length)];
      final hotRes = await _resolver.browseList(
        category: pickedCategory,
        page: rng.nextInt(3) + 1,
      );
      final shuffledHot = List<HongguoDramaItem>.from(hotRes.items)..shuffle(rng);
      addUnique(shuffledHot, 6);
    } catch (_) {}

    // 3. Khám phá thể loại mới ngẫu nhiên (Deep Exploration)
    try {
      final exploreRes = await _resolver.getRandomRecommendations();
      final shuffledExp = List<HongguoDramaItem>.from(exploreRes.items)..shuffle(rng);
      addUnique(shuffledExp, 8);
    } catch (_) {}

    // 4. Nếu chưa đủ 15 phim mới, bổ sung thêm lượt quét ngẫu nhiên khác
    if (result.length < 15) {
      try {
        final extraRes = await _resolver.getRandomRecommendations();
        final shuffledExtra = List<HongguoDramaItem>.from(extraRes.items)..shuffle(rng);
        addUnique(shuffledExtra, 15 - result.length);
      } catch (_) {}
    }

    // 5. Fallback tuyệt đối nếu lọc quá gắt (toàn bộ phim mới đều đã xem hết)
    if (result.isEmpty) {
      try {
        final fallback = await _resolver.getRandomRecommendations();
        final shuffled = List<HongguoDramaItem>.from(fallback.items)..shuffle(rng);
        for (final item in shuffled) {
          if (result.length >= 10) break;
          result.add(item);
        }
      } catch (_) {}
    }

    result.shuffle(rng);
    return result;
  }
}
