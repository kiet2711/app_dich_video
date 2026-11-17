import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../hongguo_resolver.dart';
import 'hongguo_cloud_account_service.dart';
import 'hongguo_device_service.dart';
import 'hongguo_sixgod_signer.dart';
import 'hongguo_v5_constants.dart';
import 'hongguo_v5_signer.dart';

/// Bảng ánh xạ toàn diện từ tag / nhãn tiếng Trung của ByteDance sang tiếng Việt.
const Map<String, String> kHongguoTagLabels = <String, String>{
  // --- Loại hình & Phong cách ---
  '真人剧': 'Người thật',
  '短剧': 'Phim ngắn',
  '漫剧': 'Hoạt hình',
  'AI剧': 'Phim AI',
  'AI短剧': 'Phim AI',
  '3D漫': 'Hoạt hình 3D',
  '2D漫': 'Hoạt hình 2D',
  '表情包': 'Meme / Chibi',
  '动态漫': 'Truyện tranh động',
  '漫画': 'Truyện tranh',
  '女频': 'Nữ tần (Ngôn tình)',
  '男频': 'Nam tần (Sảng văn)',
  '全部': 'Tất cả',

  // --- Sắp xếp, Thời gian & Trạng thái ---
  '最高热度': 'Hot nhất',
  '最新上架': 'Mới nhất',
  '最高收藏': 'Lưu nhiều nhất',
  '7天内上新': '7 ngày gần đây',
  '14天内上新': '14 ngày gần đây',
  '30天内上新': '30 ngày gần đây',
  '90天内上新': '90 ngày gần đây',
  '已完结': 'Đã hoàn thành',
  '连载中': 'Đang ra tập mới',

  // --- Bối cảnh & Chủ đề ---
  '古装': 'Cổ trang',
  '都市': 'Đô thị',
  '现代': 'Hiện đại',
  '古代': 'Cổ đại',
  '年代': 'Niên đại',
  '年代爱情': 'Tình cảm niên đại',
  '民国': 'Dân quốc',
  '民国爱情': 'Tình cảm dân quốc',
  '民国传奇': 'Truyền kỳ dân quốc',
  '乡村': 'Nông thôn',
  '种田': 'Điền văn',
  '校园': 'Học đường',
  '校园生活': 'Đời sống học đường',
  '青春': 'Thanh xuân',
  '青春爱情': 'Thanh xuân ái tình',
  '青春成长': 'Thanh xuân trưởng thành',
  '青春励志': 'Thanh xuân nhiệt huyết',
  '家庭': 'Gia đình',
  '家庭伦理': 'Gia đình luân lý',
  '家庭温情': 'Gia đình ấm áp',
  '职场': 'Công sở',
  '商界': 'Thương giới',
  '商战': 'Thương chiến',
  '剧情': 'Chính kịch / Tâm lý',
  '成长': 'Trưởng thành',
  '女性成长': 'Nữ tính trưởng thành',
  '小人物': 'Tiểu nhân vật',
  '综艺': 'Tạp kỹ / Show',
  '架空': 'Giả tưởng / Giá không',
  '异界': 'Dị giới',
  '星际': 'Tinh tế / Vũ trụ',
  '未来': 'Tương lai',
  '游戏世界': 'Thế giới game',
  '荒岛': 'Hoang đảo',
  '娱乐圈': 'Showbiz / Giải trí',
  '多朝代': 'Đa triều đại',
  '方言': 'Phương ngữ',

  // --- Nam tần & Sảng văn ---
  '逆袭': 'Nghịch tập',
  '逆袭翻身': 'Nghịch tập lật kèo',
  '逆风翻盘': 'Lật ngược thế cờ',
  '战神': 'Chiến thần',
  '战王': 'Chiến vương',
  '兵王': 'Binh vương',
  '龙王': 'Long vương',
  '修罗': 'Tu la',
  '赘婿': 'Ở rể',
  '赘婿逆袭': 'Ở rể nghịch tập',
  '神医': 'Thần y',
  '无敌神医': 'Thần y vô địch',
  '神豪': 'Thần hào',
  '鉴宝': 'Giám bảo',
  '下山': 'Xuống núi',
  '无敌': 'Vô địch',
  '大男主': 'Đại nam chủ',
  '男强': 'Nam cường',
  '升级流': 'Thăng cấp tu luyện',
  '任务流': 'Hệ thống nhiệm vụ',
  '极品': 'Cực phẩm',
  '极品亲戚': 'Họ hàng cực phẩm',
  '打脸': 'Vả mặt',
  '打脸反派': 'Vả mặt phản diện',
  '打脸虐渣': 'Vả mặt tra nam tiện nữ',
  '虐渣': 'Ngược tra',
  '复仇': 'Báo thù',
  '家族振兴': 'Hưng thịnh gia tộc',
  '朝堂权谋': 'Quyền mưu triều đình',
  '强者回归': 'Cường giả trở về',
  '隐藏大佬': 'Đại lão ẩn thân',
  '扮猪吃虎': 'Giả heo ăn thịt hổ',

  // --- Nữ tần & Hào môn / Tình cảm ---
  '豪门': 'Hào môn',
  '豪门千金': 'Thiên kim hào môn',
  '落魄千金': 'Thiên kim sa sút',
  '世家': 'Thế gia',
  '家族': 'Gia tộc',
  '总裁': 'Tổng tài',
  '霸总': 'Bá đạo tổng tài',
  '霸道男主': 'Nam chính bá đạo',
  '千金': 'Thiên kim',
  '真假千金': 'Thật giả thiên kim',
  '马甲': 'Thân phận ngầm',
  '大女主': 'Đại nữ chủ',
  '女强': 'Nữ cường',
  '女尊': 'Nữ tôn',
  '神女': 'Thần nữ',
  '女帝': 'Nữ đế',
  '萌宝': 'Manh bảo',
  '萌宠': 'Thú cưng',
  '带球跑': 'Mang thai bỏ trốn',
  '团宠': 'Đoàn sủng',
  '甜宠': 'Ngọt sủng',
  '都市甜宠': 'Đô thị ngọt sủng',
  '爱情': 'Tình cảm',
  '恋爱': 'Yêu đương',
  '都市爱情': 'Đô thị ái tình',
  '古风爱情': 'Cổ phong ái tình',
  '奇幻爱情': 'Kỳ ảo ái tình',
  '先婚后爱': 'Cưới trước yêu sau',
  '闪婚': 'Cưới chớp nhoáng',
  '契约': 'Hợp đồng hôn nhân',
  '虐恋': 'Ngược luyến',
  '追妻': 'Truy thê',
  '追妻火葬场': 'Truy thê hỏa táng tràng',
  '破镜重圆': 'Gương vỡ lại lành',
  '双向救赎': 'Song hướng cứu rỗi',
  '自我救赎': 'Tự cứu rỗi',
  '情感觉醒': 'Thức tỉnh tình cảm',
  '日久生情': 'Lâu ngày sinh tình',
  '暗恋成真': 'Thầm yêu thành thật',
  '青梅竹马': 'Thanh mai trúc mã',
  '欢喜冤家': 'Oan gia ngõ hẹp',
  '暧昧拉扯': 'Kéo co mập mờ',
  '故人重逢': 'Cố nhân trùng phùng',
  '替身': 'Thế thân',
  '白月光': 'Bạch nguyệt quang',
  '读心术': 'Đọc tâm thuật',
  '宫斗': 'Cung đấu',
  '宅斗': 'Trạch đấu',
  '宫斗宅斗': 'Cung đấu trạch đấu',
  '宫廷': 'Cung đình',
  '姐妹情': 'Tình chị em',
  '姐弟恋': 'Tình chị em',
  '宠妻': 'Sủng thê',
  '宠夫': 'Sủng phu',
  '高冷': 'Cao lãnh',
  '高冷禁欲': 'Cao lãnh cấm dục',
  '傲娇': 'Ngạo kiều',
  '病娇': 'Bệnh kiều',
  '御姐': 'Ngự tỷ',
  '甜妹': 'Em gái ngọt ngào',
  '直爽女主': 'Nữ chính thẳng thắn',
  '高智商': 'IQ cao',
  '学神': 'Học thần',

  // --- Viễn tưởng, Huyền huyễn & Não động ---
  '重生': 'Trọng sinh',
  '双重生': 'Song trọng sinh',
  '重生逆袭': 'Trọng sinh nghịch tập',
  '重生虐渣': 'Trọng sinh ngược tra',
  '穿越': 'Xuyên không',
  '穿书': 'Xuyên sách',
  '系统': 'Hệ thống',
  '脑洞': 'Não động / Sáng tạo',
  '都市脑洞': 'Đô thị não động',
  '奇幻脑洞': 'Kỳ ảo não động',
  '无限流': 'Vô hạn lưu',
  '修仙': 'Tu tiên',
  '修真': 'Tu chân',
  '修仙问道': 'Tu tiên vấn đạo',
  '玄幻': 'Huyền huyễn',
  '玄幻仙侠': 'Huyền huyễn tiên hiệp',
  '都市玄幻': 'Đô thị huyền huyễn',
  '仙侠': 'Tiên hiệp',
  '魔幻': 'Ma huyễn',
  '异能': 'Dị năng',
  '战力觉醒': 'Thức tỉnh chiến lực',
  '意识觉醒': 'Thức tỉnh ý thức',
  '末世': 'Mạt thế',
  '末世灾难': 'Thảm họa mạt thế',
  '高能生存': 'Sinh tồn kịch tính',
  '求生': 'Sinh tồn',
  '绝地逃生': 'Thoát hiểm đường cùng',
  '科幻': 'Khoa huyễn',
  '奇幻': 'Kỳ ảo',
  '空间': 'Không gian',
  '囤货': 'Tích trữ vật tư',

  // --- Trinh thám, Linh dị & Hành động ---
  '悬疑': 'Hồi hộp / Trinh thám',
  '悬疑情感': 'Trinh thám tình cảm',
  '悬疑推理': 'Trinh thám suy luận',
  '推理解谜': 'Giải mã phá án',
  '揭露阴谋': 'Vạch trần âm mưu',
  '探案': 'Phá án',
  '犯罪': 'Tội phạm',
  '反转': 'Quay xe / Lật kèo',
  '惊悚': 'Giật gân',
  '恐怖': 'Kinh dị',
  '规则怪谈': 'Quy tắc quái đàm',
  '灵异': 'Linh dị',
  '玄学': 'Huyền học',
  '志怪': 'Chí quái',
  '诡秘': 'Quỷ bí',
  '诡秘冒险': 'Phiêu lưu quỷ bí',
  '盗墓': 'Đạo mộ',
  '灾难': 'Thảm họa',
  '战争': 'Chiến tranh',
  '热血': 'Nhiệt huyết',
  '动作': 'Hành động',
  '动作冒险': 'Hành động phiêu lưu',
  '冒险': 'Phiêu lưu',
  '团队冒险': 'Phiêu lưu đồng đội',
  '奇幻冒险': 'Phiêu lưu kỳ ảo',
  '传奇': 'Truyền kỳ',
  '喜剧': 'Hài hước',
  '搞笑': 'Gây cười',
  '轻松搞笑': 'Hài nhẹ nhàng',
  '轻喜剧': 'Hài nhẹ nhàng',
  '黑化归来': 'Hắc hóa trở lại',

  // --- BXH / Khác ---
  '热播榜': 'Thịnh hành',
  '红果热播榜': 'Bảng Hot Hồng Quả',
  '真人剧热播榜': 'Hot Người Thật',
  '漫剧热播榜': 'Hot Hoạt Hình',
  'AI剧热播榜': 'Hot Phim AI',
  '新剧': 'Phim mới',
};

/// Dịch nhanh tên tag/nhãn tiếng Trung sang tiếng Việt thân thiện.
String translateHongguoTag(String raw) {
  final clean = raw.replaceAll(RegExp(r'[\[\]#\s]'), '').trim();
  if (clean.isEmpty) return raw;
  return kHongguoTagLabels[clean] ?? clean;
}

/// 3 kho nội dung chính thức của Hồng Quả trên ByteDance App API.
enum HongguoGenreKind {
  realPlay(
    id: 'short_play',
    categorySlug: 'category/real-drama',
    reqScene: 'default',
    label: 'Người thật',
    shortLabel: 'Người thật',
    emoji: '🎬',
    searchTab: 11,
  ),
  comicSeries(
    id: 'comic_series',
    categorySlug: 'category/comic-drama',
    reqScene: 'comic_series',
    label: 'Hoạt hình',
    shortLabel: 'Hoạt hình',
    emoji: '🎨',
    searchTab: 19,
  ),
  aiSeries(
    id: 'ai_series',
    categorySlug: 'category/ai-drama',
    reqScene: 'ai_series',
    label: 'Phim AI',
    shortLabel: 'Phim AI',
    emoji: '🤖',
    searchTab: 11,
  );

  final String id;
  final String categorySlug;
  final String reqScene;
  final String label;
  final String shortLabel;
  final String emoji;
  final int searchTab;

  const HongguoGenreKind({
    required this.id,
    required this.categorySlug,
    required this.reqScene,
    required this.label,
    required this.shortLabel,
    required this.emoji,
    required this.searchTab,
  });

  static HongguoGenreKind fromAny(String? raw, {HongguoGenreKind fallback = HongguoGenreKind.realPlay}) {
    final lower = (raw ?? '').trim().toLowerCase();
    if (lower.isEmpty) return fallback;
    if (lower.contains('comic') || lower == 'comic_series') {
      return HongguoGenreKind.comicSeries;
    }
    if (lower.contains('ai') || lower == 'ai_series') {
      return HongguoGenreKind.aiSeries;
    }
    if (lower.contains('real') || lower == 'short_play') {
      return HongguoGenreKind.realPlay;
    }
    return fallback;
  }
}

/// Một lựa chọn trong hàng bộ lọc của server ByteDance.
class HongguoSelectorOption {
  final String id;
  final String showName;

  const HongguoSelectorOption({
    required this.id,
    required this.showName,
  });

  String get viLabel => translateHongguoTag(showName);
}

/// Một hàng bộ lọc đa chiều (vd: `category_dim_theme`, `category_dim_epoch`, `gender`...).
class HongguoSelectorGroup {
  final String type;
  final String label;
  final List<HongguoSelectorOption> options;

  const HongguoSelectorGroup({
    required this.type,
    required this.label,
    required this.options,
  });
}

/// Tổ hợp lựa chọn bộ lọc đa chiều cho API `/reading/distribution/category/landpage/v/`.
class HongguoDiscoverySelection {
  static const List<String> allSelectorTypes = <String>[
    'category_dim_art_style',
    'category_dim_theme',
    'category_dim_epoch',
    'category_dim_role',
    'gender',
    'sort',
    'online_time',
    'creation_status',
  ];

  static const Map<String, String> axisLabels = <String, String>{
    'category_dim_art_style': 'Phong cách',
    'category_dim_theme': 'Chủ đề',
    'category_dim_epoch': 'Bối cảnh',
    'category_dim_role': 'Thiết lập',
    'gender': 'Đối tượng',
    'sort': 'Sắp xếp',
    'online_time': 'Thời gian',
    'creation_status': 'Trạng thái',
  };

  final HongguoGenreKind genreKind;
  final Map<String, String> filters;
  final String tagHint;

  const HongguoDiscoverySelection({
    this.genreKind = HongguoGenreKind.realPlay,
    this.filters = const <String, String>{},
    this.tagHint = '',
  });

  String valueOf(String type) => filters[type] ?? '';

  String get effectiveSort =>
      (filters['sort'] ?? '').isNotEmpty ? filters['sort']! : 'hot_score';

  int get activeFilterCount {
    var count = 0;
    for (final entry in filters.entries) {
      if (entry.key == 'sort' && entry.value == 'hot_score') continue;
      if (entry.value.isNotEmpty) count++;
    }
    return count;
  }

  /// Đổi kho nội dung (Người thật / Hoạt hình / AI) và xóa các điều kiện taxonomy cũ không tương thích.
  HongguoDiscoverySelection withGenreKind(
    HongguoGenreKind nextKind, {
    bool keepSortAndGender = true,
  }) {
    if (nextKind == genreKind && tagHint.isEmpty) return this;
    final preserved = <String, String>{};
    if (keepSortAndGender) {
      final sortVal = filters['sort'];
      if (sortVal != null && sortVal.isNotEmpty) preserved['sort'] = sortVal;
      final genderVal = filters['gender'];
      if (genderVal != null && genderVal.isNotEmpty) {
        preserved['gender'] = genderVal;
      }
      final onlineVal = filters['online_time'];
      if (onlineVal != null && onlineVal.isNotEmpty) {
        preserved['online_time'] = onlineVal;
      }
    }
    return HongguoDiscoverySelection(genreKind: nextKind, filters: preserved);
  }

  /// Đặt hoặc gỡ điều kiện lọc trên một trục (`id == ''` để xóa).
  HongguoDiscoverySelection withFilter(String type, String id) {
    final next = Map<String, String>.from(filters);
    if (id.isEmpty) {
      next.remove(type);
    } else {
      next[type] = id;
    }
    return HongguoDiscoverySelection(
      genreKind: genreKind,
      filters: Map.unmodifiable(next),
      tagHint: type == 'sort' ? tagHint : '',
    );
  }

  HongguoDiscoverySelection resetFilters() => HongguoDiscoverySelection(
    genreKind: genreKind,
    filters: const <String, String>{'sort': 'hot_score'},
  );

  /// Tạo payload JSON gửi cho `/reading/distribution/category/landpage/v/`.
  /// Khi [useDefaultFeedSort] = true (dùng cho Feed `Mạn kịch` / `Người thật`),
  /// giữ `sort: []` giống `RecommendationFeed.kt` để lấy luồng đề xuất tự nhiên của kênh.
  Map<String, dynamic> toRequestBody({
    HongguoDiscoveryCursor? cursor,
    Set<String>? filterIds,
    bool useDefaultFeedSort = false,
  }) {
    final selectItems = <String, dynamic>{
      'genre': <String>[genreKind.id],
    };
    for (final type in allSelectorTypes) {
      if (type == 'category_dim_art_style' &&
          genreKind != HongguoGenreKind.comicSeries) {
        continue;
      }
      final val = filters[type];
      if (type == 'sort' && (val == null || val.isEmpty)) {
        selectItems[type] = useDefaultFeedSort
            ? const <String>[]
            : const <String>['hot_score'];
      } else {
        selectItems[type] = (val != null && val.isNotEmpty)
            ? <String>[val]
            : const <String>[];
      }
    }
    final isInitial = cursor == null;
    final excluded = (filterIds == null || filterIds.isEmpty)
        ? ''
        : filterIds.take(120).join(',');
    return <String, dynamic>{
      'offset': cursor?.offset ?? 0,
      'limit': 24,
      'need_selector_panel': isInitial,
      'select_items': selectItems,
      'session_id': cursor?.sessionId ?? '',
      'req_type': isInitial ? 'default' : 'only_content',
      'client_req_type': isInitial ? 3 : 2,
      'filter_ids': excluded,
      'req_scene': genreKind.reqScene,
    };
  }

  String toJsonString() => jsonEncode(<String, dynamic>{
    'genre': genreKind.id,
    'filters': filters,
    if (tagHint.isNotEmpty) 'tagHint': tagHint,
  });

  static HongguoDiscoverySelection fromJsonString(
    String raw, {
    HongguoGenreKind fallbackKind = HongguoGenreKind.realPlay,
  }) {
    if (raw.trim().isEmpty) {
      return HongguoDiscoverySelection(
        genreKind: fallbackKind,
        filters: const <String, String>{'sort': 'hot_score'},
      );
    }
    try {
      final map = jsonDecode(raw);
      if (map is Map) {
        final kind = HongguoGenreKind.fromAny(
          map['genre']?.toString(),
          fallback: fallbackKind,
        );
        final rawFilters = map['filters'];
        final clean = <String, String>{};
        if (rawFilters is Map) {
          for (final e in rawFilters.entries) {
            final k = e.key.toString();
            final v = e.value?.toString() ?? '';
            if (allSelectorTypes.contains(k) &&
                RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(v)) {
              clean[k] = v;
            }
          }
        }
        return HongguoDiscoverySelection(
          genreKind: kind,
          filters: Map.unmodifiable(clean),
          tagHint: map['tagHint']?.toString() ?? '',
        );
      }
    } catch (_) {}
    return HongguoDiscoverySelection(
      genreKind: fallbackKind,
      filters: const <String, String>{'sort': 'hot_score'},
    );
  }

  /// Tạo nhãn tóm tắt ngắn gọn để hiển thị trên Tab / Header.
  String buildSummaryLabel(List<HongguoSelectorGroup> groups) {
    final parts = <String>[genreKind.shortLabel];
    for (final type in const [
      'category_dim_art_style',
      'category_dim_epoch',
      'category_dim_theme',
      'category_dim_role',
      'gender',
    ]) {
      final id = filters[type] ?? '';
      if (id.isEmpty) continue;
      final label = _lookupOptionLabel(groups, type, id);
      if (label.isNotEmpty) parts.add(label);
      if (parts.length >= 3) break;
    }
    if (parts.length == 1 && tagHint.isNotEmpty) {
      parts.add(translateHongguoTag(tagHint));
    }
    return parts.join(' · ');
  }

  static String _lookupOptionLabel(
    List<HongguoSelectorGroup> groups,
    String type,
    String id,
  ) {
    for (final g in groups) {
      if (g.type != type) continue;
      for (final opt in g.options) {
        if (opt.id == id) return opt.viLabel;
      }
    }
    if (type == 'gender') {
      return id == '0' ? 'Nữ tần' : (id == '1' ? 'Nam tần' : '');
    }
    return '';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! HongguoDiscoverySelection) return false;
    if (other.genreKind != genreKind || other.tagHint != tagHint) return false;
    if (other.filters.length != filters.length) return false;
    for (final e in filters.entries) {
      if (other.filters[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(genreKind, tagHint, Object.hashAllUnordered(filters.entries.map((e) => Object.hash(e.key, e.value))));
}

/// Con trỏ phân trang server cho API `landpage/v/`.
class HongguoDiscoveryCursor {
  final int offset;
  final String sessionId;
  final int page;

  const HongguoDiscoveryCursor({
    required this.offset,
    required this.sessionId,
    required this.page,
  });
}

/// Kết quả một trang lọc đa chiều từ `landpage/v/`.
class HongguoDiscoveryPage {
  final List<HongguoDramaItem> items;
  final List<HongguoSelectorGroup> selectorGroups;
  final HongguoDiscoveryCursor? nextCursor;
  final bool hasMore;
  final bool fromFallback;

  const HongguoDiscoveryPage({
    required this.items,
    required this.selectorGroups,
    this.nextCursor,
    required this.hasMore,
    this.fromFallback = false,
  });
}

/// Con trỏ phân trang luồng Đề xuất trang chủ (`bookmall/tab/v1` -> `cell/change/v1`).
class HongguoOfficialFeedCursor {
  final String sessionId;
  final int offset;
  final String cellId;
  final String planId;
  final String versionTag;
  final bool unsignedFallback;
  final Set<String> seenIds;

  const HongguoOfficialFeedCursor({
    this.sessionId = '',
    this.offset = 0,
    this.cellId = '',
    this.planId = '',
    this.versionTag = '',
    this.unsignedFallback = false,
    this.seenIds = const <String>{},
  });

  bool get hasCellContinuation =>
      cellId.isNotEmpty && planId.isNotEmpty && versionTag.isNotEmpty;

  HongguoOfficialFeedCursor copyWith({
    String? sessionId,
    int? offset,
    String? cellId,
    String? planId,
    String? versionTag,
    bool? unsignedFallback,
    Set<String>? seenIds,
  }) {
    return HongguoOfficialFeedCursor(
      sessionId: sessionId ?? this.sessionId,
      offset: offset ?? this.offset,
      cellId: cellId ?? this.cellId,
      planId: planId ?? this.planId,
      versionTag: versionTag ?? this.versionTag,
      unsignedFallback: unsignedFallback ?? this.unsignedFallback,
      seenIds: seenIds ?? this.seenIds,
    );
  }
}

class HongguoOfficialFeedPage {
  final List<HongguoDramaItem> items;
  final HongguoOfficialFeedCursor nextCursor;

  const HongguoOfficialFeedPage({
    required this.items,
    required this.nextCursor,
  });
}

/// Một phần/mùa liên quan trong mục `相关作品` (`show_type == 547`).
class HongguoRelatedSeasonItem {
  final HongguoDramaItem drama;
  final String seasonLabel;
  final int seasonIndex;
  final bool upcoming;

  const HongguoRelatedSeasonItem({
    required this.drama,
    this.seasonLabel = '',
    this.seasonIndex = 0,
    this.upcoming = false,
  });
}

/// Gói kết quả từ `/reading/bookapi/plan/v:version/` (`scene=10`):
/// gồm cả Các mùa liên quan (`547`) và Có thể bạn sẽ thích (`506`).
class HongguoRelatedBundle {
  final List<HongguoRelatedSeasonItem> seasons;
  final List<HongguoDramaItem> similarDramas;

  const HongguoRelatedBundle({
    this.seasons = const <HongguoRelatedSeasonItem>[],
    this.similarDramas = const <HongguoDramaItem>[],
  });
}

/// Dịch vụ khám phá, lọc đa chiều, đề xuất cá nhân hóa và liên quan chính thức của ByteDance.
class HongguoDiscoveryService {
  static final HongguoDiscoveryService instance = HongguoDiscoveryService._internal();

  factory HongguoDiscoveryService({Dio? dio}) =>
      dio == null ? instance : HongguoDiscoveryService._custom(dio);

  HongguoDiscoveryService._internal()
      : _dio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 12),
            receiveTimeout: const Duration(seconds: 22),
            validateStatus: (status) => status != null && status < 500,
          ),
        );

  HongguoDiscoveryService._custom(this._dio);

  @visibleForTesting
  HongguoDiscoveryService.forSubclass() : this._internal();

  final Dio _dio;

  static const List<String> _feedHosts = <String>[
    'https://api5-normal-sinfonlineb.fqnovel.com',
    'https://api5-normal-sinfonlinea.fqnovel.com',
    'https://api5-normal-sinfonlinec.fqnovel.com',
    'https://api5-normal-hl.fqnovel.com',
    'https://api5-normal-lf.fqnovel.com',
  ];

  final Map<HongguoGenreKind, List<HongguoSelectorGroup>> _selectorCache = {};

  /// Lấy danh sách nhóm điều kiện lọc cho kho phim (`cache` + fallback tĩnh chuẩn ByteDance).
  List<HongguoSelectorGroup> getSelectorGroups(HongguoGenreKind kind) {
    return _selectorCache[kind] ?? defaultSelectorGroups(kind);
  }

  /// Trả về bộ điều kiện mặc định đã xác thực từ server ByteDance (dùng ngay khi chưa có mạng/cache).
  static List<HongguoSelectorGroup> defaultSelectorGroups(HongguoGenreKind kind) {
    final commonTail = <HongguoSelectorGroup>[
      const HongguoSelectorGroup(
        type: 'sort',
        label: 'Sắp xếp',
        options: <HongguoSelectorOption>[
          HongguoSelectorOption(id: 'hot_score', showName: '最高热度'),
          HongguoSelectorOption(id: 'online_time', showName: '最新上架'),
          HongguoSelectorOption(id: 'hot_collect', showName: '最高收藏'),
        ],
      ),
      const HongguoSelectorGroup(
        type: 'gender',
        label: 'Đối tượng',
        options: <HongguoSelectorOption>[
          HongguoSelectorOption(id: '0', showName: '女频'),
          HongguoSelectorOption(id: '1', showName: '男频'),
        ],
      ),
      const HongguoSelectorGroup(
        type: 'online_time',
        label: 'Thời gian',
        options: <HongguoSelectorOption>[
          HongguoSelectorOption(id: 'days_7', showName: '7天内上新'),
          HongguoSelectorOption(id: 'days_14', showName: '14天内上新'),
          HongguoSelectorOption(id: 'days_30', showName: '30天内上新'),
          HongguoSelectorOption(id: 'days_90', showName: '90天内上新'),
        ],
      ),
    ];

    if (kind == HongguoGenreKind.comicSeries) {
      return <HongguoSelectorGroup>[
        const HongguoSelectorGroup(
          type: 'category_dim_art_style',
          label: 'Phong cách',
          options: <HongguoSelectorOption>[
            HongguoSelectorOption(id: 'cate_5416', showName: '2D漫'),
            HongguoSelectorOption(id: 'cate_5415', showName: '3D漫'),
            HongguoSelectorOption(id: 'cate_5417', showName: '表情包'),
          ],
        ),
        const HongguoSelectorGroup(
          type: 'category_dim_theme',
          label: 'Chủ đề',
          options: <HongguoSelectorOption>[
            HongguoSelectorOption(id: 'cate_7', showName: '玄幻'),
            HongguoSelectorOption(id: 'cate_755', showName: '脑洞'),
            HongguoSelectorOption(id: 'cate_316', showName: '剧情'),
            HongguoSelectorOption(id: 'cate_936', showName: '豪门'),
            HongguoSelectorOption(id: 'cate_6', showName: '奇幻'),
            HongguoSelectorOption(id: 'cate_1182', showName: '冒险'),
            HongguoSelectorOption(id: 'cate_68', showName: '末世'),
            HongguoSelectorOption(id: 'cate_1092', showName: '科幻'),
          ],
        ),
        const HongguoSelectorGroup(
          type: 'category_dim_epoch',
          label: 'Bối cảnh',
          options: <HongguoSelectorOption>[
            HongguoSelectorOption(id: 'cate_4', showName: '校园'),
            HongguoSelectorOption(id: 'cate_1', showName: '都市'),
            HongguoSelectorOption(id: 'cate_758', showName: '古代'),
            HongguoSelectorOption(id: 'cate_452', showName: '架空'),
            HongguoSelectorOption(id: 'cate_599', showName: '异界'),
            HongguoSelectorOption(id: 'cate_79', showName: '年代'),
            HongguoSelectorOption(id: 'cate_127', showName: '职场'),
            HongguoSelectorOption(id: 'cate_390', showName: '民国'),
            HongguoSelectorOption(id: 'cate_11', showName: '乡村'),
          ],
        ),
        const HongguoSelectorGroup(
          type: 'category_dim_role',
          label: 'Thiết lập',
          options: <HongguoSelectorOption>[
            HongguoSelectorOption(id: 'cate_739', showName: '逆袭'),
            HongguoSelectorOption(id: 'cate_36', showName: '重生'),
            HongguoSelectorOption(id: 'cate_37', showName: '穿越'),
            HongguoSelectorOption(id: 'cate_19', showName: '系统'),
            HongguoSelectorOption(id: 'cate_756', showName: '反转'),
            HongguoSelectorOption(id: 'cate_29', showName: '总裁'),
            HongguoSelectorOption(id: 'cate_43', showName: '娱乐圈'),
            HongguoSelectorOption(id: 'cate_598', showName: '异能'),
          ],
        ),
        ...commonTail,
        const HongguoSelectorGroup(
          type: 'creation_status',
          label: 'Trạng thái',
          options: <HongguoSelectorOption>[
            HongguoSelectorOption(id: 'creation_status_0', showName: '已完结'),
            HongguoSelectorOption(id: 'creation_status_1', showName: '连载中'),
          ],
        ),
      ];
    }

    if (kind == HongguoGenreKind.aiSeries) {
      return <HongguoSelectorGroup>[
        const HongguoSelectorGroup(
          type: 'category_dim_theme',
          label: 'Chủ đề',
          options: <HongguoSelectorOption>[
            HongguoSelectorOption(id: 'cate_316', showName: '剧情'),
            HongguoSelectorOption(id: 'cate_7', showName: '玄幻'),
            HongguoSelectorOption(id: 'cate_755', showName: '脑洞'),
            HongguoSelectorOption(id: 'cate_936', showName: '豪门'),
            HongguoSelectorOption(id: 'cate_6', showName: '奇幻'),
            HongguoSelectorOption(id: 'cate_1182', showName: '冒险'),
            HongguoSelectorOption(id: 'cate_68', showName: '末世'),
            HongguoSelectorOption(id: 'cate_1092', showName: '科幻'),
          ],
        ),
        const HongguoSelectorGroup(
          type: 'category_dim_epoch',
          label: 'Bối cảnh',
          options: <HongguoSelectorOption>[
            HongguoSelectorOption(id: 'cate_4', showName: '校园'),
            HongguoSelectorOption(id: 'cate_1', showName: '都市'),
            HongguoSelectorOption(id: 'cate_758', showName: '古代'),
            HongguoSelectorOption(id: 'cate_452', showName: '架空'),
            HongguoSelectorOption(id: 'cate_599', showName: '异界'),
            HongguoSelectorOption(id: 'cate_79', showName: '年代'),
            HongguoSelectorOption(id: 'cate_127', showName: '职场'),
            HongguoSelectorOption(id: 'cate_390', showName: '民国'),
            HongguoSelectorOption(id: 'cate_11', showName: '乡村'),
          ],
        ),
        const HongguoSelectorGroup(
          type: 'category_dim_role',
          label: 'Thiết lập',
          options: <HongguoSelectorOption>[
            HongguoSelectorOption(id: 'cate_739', showName: '逆袭'),
            HongguoSelectorOption(id: 'cate_36', showName: '重生'),
            HongguoSelectorOption(id: 'cate_37', showName: '穿越'),
            HongguoSelectorOption(id: 'cate_19', showName: '系统'),
            HongguoSelectorOption(id: 'cate_756', showName: '反转'),
            HongguoSelectorOption(id: 'cate_29', showName: '总裁'),
            HongguoSelectorOption(id: 'cate_43', showName: '娱乐圈'),
            HongguoSelectorOption(id: 'cate_598', showName: '异能'),
          ],
        ),
        ...commonTail,
      ];
    }

    // short_play (Người thật)
    return <HongguoSelectorGroup>[
      const HongguoSelectorGroup(
        type: 'category_dim_theme',
        label: 'Chủ đề',
        options: <HongguoSelectorOption>[
          HongguoSelectorOption(id: 'cate_5000', showName: '爱情'),
          HongguoSelectorOption(id: 'cate_5023', showName: '青春'),
          HongguoSelectorOption(id: 'cate_5022', showName: '都市'),
          HongguoSelectorOption(id: 'cate_5007', showName: '古装'),
          HongguoSelectorOption(id: 'cate_5031', showName: '逆袭'),
          HongguoSelectorOption(id: 'cate_5002', showName: '家族'),
          HongguoSelectorOption(id: 'cate_5001', showName: '家庭'),
          HongguoSelectorOption(id: 'cate_5008', showName: '玄幻'),
          HongguoSelectorOption(id: 'cate_5004', showName: '悬疑'),
          HongguoSelectorOption(id: 'cate_5021', showName: '年代'),
          HongguoSelectorOption(id: 'cate_5003', showName: '萌宝'),
          HongguoSelectorOption(id: 'cate_5024', showName: '喜剧'),
          HongguoSelectorOption(id: 'cate_5030', showName: '剧情'),
          HongguoSelectorOption(id: 'cate_5009', showName: '奇幻'),
          HongguoSelectorOption(id: 'cate_5010', showName: '成长'),
          HongguoSelectorOption(id: 'cate_5011', showName: '传奇'),
          HongguoSelectorOption(id: 'cate_5006', showName: '志怪'),
          HongguoSelectorOption(id: 'cate_5025', showName: '科幻'),
          HongguoSelectorOption(id: 'cate_5132', showName: '惊悚'),
          HongguoSelectorOption(id: 'cate_5133', showName: '恐怖'),
          HongguoSelectorOption(id: 'cate_9165', showName: '动作'),
          HongguoSelectorOption(id: 'cate_9163', showName: '冒险'),
          HongguoSelectorOption(id: 'cate_5026', showName: '灾难'),
          HongguoSelectorOption(id: 'cate_5028', showName: '战争'),
        ],
      ),
      const HongguoSelectorGroup(
        type: 'category_dim_epoch',
        label: 'Bối cảnh',
        options: <HongguoSelectorOption>[
          HongguoSelectorOption(id: 'cate_5315', showName: '校园'),
          HongguoSelectorOption(id: 'cate_5338', showName: '现代'),
          HongguoSelectorOption(id: 'cate_5339', showName: '古代'),
          HongguoSelectorOption(id: 'cate_5340', showName: '民国'),
          HongguoSelectorOption(id: 'cate_5312', showName: '架空'),
          HongguoSelectorOption(id: 'cate_5318', showName: '豪门'),
          HongguoSelectorOption(id: 'cate_5301', showName: '职场'),
          HongguoSelectorOption(id: 'cate_5320', showName: '娱乐圈'),
          HongguoSelectorOption(id: 'cate_5314', showName: '乡村'),
          HongguoSelectorOption(id: 'cate_5319', showName: '世家'),
          HongguoSelectorOption(id: 'cate_5302', showName: '商界'),
          HongguoSelectorOption(id: 'cate_5305', showName: '黑道'),
          HongguoSelectorOption(id: 'cate_5311', showName: '未来'),
          HongguoSelectorOption(id: 'cate_5308', showName: '游戏世界'),
        ],
      ),
      const HongguoSelectorGroup(
        type: 'category_dim_role',
        label: 'Thiết lập',
        options: <HongguoSelectorOption>[
          HongguoSelectorOption(id: 'cate_5260', showName: '大女主'),
          HongguoSelectorOption(id: 'cate_5224', showName: '大男主'),
          HongguoSelectorOption(id: 'cate_5221', showName: '女强'),
          HongguoSelectorOption(id: 'cate_5206', showName: '总裁'),
          HongguoSelectorOption(id: 'cate_5201', showName: '战神'),
          HongguoSelectorOption(id: 'cate_5203', showName: '神豪'),
          HongguoSelectorOption(id: 'cate_5241', showName: '团宠'),
          HongguoSelectorOption(id: 'cate_5220', showName: '真假千金'),
          HongguoSelectorOption(id: 'cate_5275', showName: '宠妻'),
          HongguoSelectorOption(id: 'cate_5279', showName: '白月光'),
          HongguoSelectorOption(id: 'cate_5280', showName: '欢喜冤家'),
          HongguoSelectorOption(id: 'cate_5300', showName: '姐弟恋'),
          HongguoSelectorOption(id: 'cate_5284', showName: '学神'),
          HongguoSelectorOption(id: 'cate_5326', showName: '病娇'),
          HongguoSelectorOption(id: 'cate_5332', showName: '强强联合'),
        ],
      ),
      ...commonTail,
    ];
  }

  /// Ánh xạ thông minh một tag tiếng Trung khi người dùng bấm trực tiếp trên thẻ phim
  /// sang đúng bộ lọc `landpage` của KHO PHIM HIỆN TẠI (không nhảy nhầm về Người thật).
  HongguoDiscoverySelection resolveSelectionForTag(
    String rawZhTag, {
    String? preferredSourceCategory,
    List<String> categoryIds = const <String>[],
    List<String> allDramaTags = const <String>[],
  }) {
    final cleanZh = rawZhTag.replaceAll(RegExp(r'[\[\]#\s]'), '').trim();

    // 1. Khóa chặt loại kho nội dung (ưu tiên categoryIds -> allDramaTags -> ngữ cảnh đang mở)
    var resolvedCat = preferredSourceCategory ?? '';
    final inferred = HongguoResolver.inferSourceCategoryFromIds(
      categoryIds,
      tags: allDramaTags,
    );
    if (inferred.isNotEmpty) {
      resolvedCat = inferred;
    }
    final kind = HongguoGenreKind.fromAny(
      resolvedCat,
      fallback: HongguoGenreKind.realPlay,
    );

    final groups = getSelectorGroups(kind);
    final filters = <String, String>{'sort': 'hot_score'};

    // 2. Khớp trực tiếp theo tên hiển thị trong selector_rows của đúng kho đó
    bool matchedDirect = false;
    for (final g in groups) {
      for (final opt in g.options) {
        if (opt.showName == cleanZh) {
          filters[g.type] = opt.id;
          matchedDirect = true;
          break;
        }
      }
      if (matchedDirect) break;
    }

    // 3. Ánh xạ thông minh cho các tag phổ biến không đứng trực tiếp thành chip 1-1
    // (đặc biệt các tag như 校园, 青春爱情, 都市爱情, 现代, 甜宠, 总裁 bên Hoạt hình / AI)
    if (!matchedDirect) {
      if (kind == HongguoGenreKind.realPlay) {
        _applyRealPlayTagFallback(cleanZh, filters);
      } else {
        _applyComicOrAiTagFallback(cleanZh, filters);
      }
    } else if ((cleanZh == '爱情' || cleanZh == '青春爱情' || cleanZh == '都市爱情') &&
        kind != HongguoGenreKind.realPlay) {
      filters['gender'] = '0';
    }

    return HongguoDiscoverySelection(
      genreKind: kind,
      filters: Map.unmodifiable(filters),
      tagHint: cleanZh,
    );
  }

  static void _applyRealPlayTagFallback(
    String zh,
    Map<String, String> filters,
  ) {
    switch (zh) {
      case '校园':
      case '校园生活':
        filters['category_dim_epoch'] = 'cate_5315';
        return;
      case '青春':
      case '青春爱情':
      case '青春成长':
      case '青春励志':
        filters['category_dim_theme'] = 'cate_5023';
        return;
      case '爱情':
      case '恋爱':
      case '都市爱情':
      case '古风爱情':
      case '甜宠':
      case '都市甜宠':
      case '先婚后爱':
      case '闪婚':
      case '虐恋':
      case '暗恋成真':
      case '日久生情':
        filters['category_dim_theme'] = 'cate_5000';
        filters['gender'] = '0';
        return;
      case '现代':
        filters['category_dim_epoch'] = 'cate_5338';
        return;
      case '古代':
        filters['category_dim_epoch'] = 'cate_5339';
        return;
      case '都市':
      case '都市脑洞':
        filters['category_dim_theme'] = 'cate_5022';
        return;
      case '豪门':
      case '豪门千金':
        filters['category_dim_epoch'] = 'cate_5318';
        return;
      case '霸总':
      case '总裁':
        filters['category_dim_role'] = 'cate_5206';
        return;
      case '逆袭翻身':
      case '逆风翻盘':
      case '重生逆袭':
        filters['category_dim_theme'] = 'cate_5031';
        return;
      case '修仙':
      case '修真':
      case '仙侠':
      case '玄幻仙侠':
        filters['category_dim_theme'] = 'cate_5008';
        return;
      case '女性成长':
        filters['category_dim_theme'] = 'cate_5010';
        filters['gender'] = '0';
        return;
      case '悬疑推理':
      case '悬疑情感':
      case '推理解谜':
        filters['category_dim_theme'] = 'cate_5004';
        return;
      case '规则怪谈':
        filters['category_dim_theme'] = 'cate_5133';
        return;
      case '动作冒险':
        filters['category_dim_theme'] = 'cate_9163';
        return;
      case '末世':
      case '末世灾难':
        filters['category_dim_theme'] = 'cate_5026';
        return;
      default:
        // Nếu tag nằm ở Bối cảnh/Chủ đề chung thì cố gắng map theo từ khóa con
        if (zh.contains('校园')) {
          filters['category_dim_epoch'] = 'cate_5315';
        } else if (zh.contains('现代') || zh.contains('都市')) {
          filters['category_dim_epoch'] = 'cate_5338';
        } else if (zh.contains('古')) {
          filters['category_dim_theme'] = 'cate_5007';
        }
    }
  }

  static void _applyComicOrAiTagFallback(
    String zh,
    Map<String, String> filters,
  ) {
    switch (zh) {
      case '校园':
      case '校园生活':
        filters['category_dim_epoch'] = 'cate_4';
        return;
      case '青春':
      case '青春成长':
      case '青春励志':
        filters['category_dim_epoch'] = 'cate_4';
        return;
      case '青春爱情':
      case '青梅竹马':
      case '暗恋成真':
        filters['category_dim_epoch'] = 'cate_4';
        filters['gender'] = '0';
        return;
      case '爱情':
      case '恋爱':
      case '都市爱情':
      case '都市甜宠':
      case '甜宠':
      case '先婚后爱':
      case '闪婚':
      case '虐恋':
      case '双向救赎':
      case '日久生情':
      case '情感觉醒':
        filters['gender'] = '0';
        if (zh.contains('都市')) {
          filters['category_dim_epoch'] = 'cate_1';
        }
        return;
      case '现代':
        filters['category_dim_epoch'] = 'cate_1';
        return;
      case '修仙':
      case '修真':
      case '仙侠':
      case '玄幻仙侠':
      case '都市玄幻':
      case '修仙问道':
        filters['category_dim_theme'] = 'cate_7';
        return;
      case '都市脑洞':
        filters['category_dim_theme'] = 'cate_755';
        filters['category_dim_epoch'] = 'cate_1';
        return;
      case '奇幻脑洞':
        filters['category_dim_theme'] = 'cate_6';
        return;
      case '大女主':
      case '女强':
      case '女性成长':
        filters['gender'] = '0';
        return;
      case '大男主':
      case '男强':
      case '升级流':
        filters['gender'] = '1';
        return;
      case '逆袭翻身':
      case '逆风翻盘':
      case '打脸反派':
      case '打脸虐渣':
        filters['category_dim_role'] = 'cate_739';
        return;
      case '重生逆袭':
      case '双重生':
      case '重生虐渣':
        filters['category_dim_role'] = 'cate_36';
        return;
      case '穿书':
        filters['category_dim_role'] = 'cate_37';
        return;
      case '霸总':
        filters['category_dim_role'] = 'cate_29';
        return;
      case '末世灾难':
      case '高能生存':
        filters['category_dim_theme'] = 'cate_68';
        return;
      case '悬疑':
      case '悬疑推理':
      case '悬疑情感':
      case '规则怪谈':
      case '恐怖':
      case '惊悚':
        filters['category_dim_theme'] = 'cate_755';
        return;
      case '家庭':
      case '家庭伦理':
      case '成长':
      case '年代':
        filters['category_dim_theme'] = 'cate_316';
        if (zh == '年代') filters['category_dim_epoch'] = 'cate_79';
        return;
      default:
        if (zh.contains('校园')) {
          filters['category_dim_epoch'] = 'cate_4';
        } else if (zh.contains('现代') || zh.contains('都市')) {
          filters['category_dim_epoch'] = 'cate_1';
        } else if (zh.contains('古')) {
          filters['category_dim_epoch'] = 'cate_758';
        }
    }
  }

  /// Duyệt & lọc đa chiều qua API chính thức `/reading/distribution/category/landpage/v/`.
  Future<HongguoDiscoveryPage> fetchDiscovery(
    HongguoDiscoverySelection selection, {
    HongguoDiscoveryCursor? cursor,
    Set<String>? seenIds,
    bool useDefaultFeedSort = false,
  }) async {
    final creds = HongguoCloudAccountService.instance.state.value.credentials;
    final cachedDevice = await _safeGetDevice();
    final bodyObj = selection.toRequestBody(
      cursor: cursor,
      filterIds: seenIds,
      useDefaultFeedSort: useDefaultFeedSort,
    );

    final baseParams = _baseAppParams(
      versionCode: '73532',
      versionName: '7.3.5.32',
    );

    Exception? lastErr;
    for (var i = 0; i < 3; i++) {
      final host = _feedHosts[i % _feedHosts.length];
      final baseUri = Uri.parse('$host/reading/distribution/category/landpage/v/')
          .replace(queryParameters: baseParams);

      final signed = HongguoSixgodSigner.signRequest(
        url: baseUri.toString(),
        body: bodyObj,
        deviceId: cachedDevice?.deviceId,
        installId: cachedDevice?.installId,
        includeHelios: true,
        userAgentOverride:
            HongguoV5Constants.appUa.replaceAll('72232', '73532'),
      );

      final headers = <String, String>{
        ...signed.headers,
        'Accept': 'application/json',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'X-XS-From-Web': '0',
        'Sdk-Version': '2',
      };
      if (creds != null && creds.isValid) {
        headers['Cookie'] = creds.cookie;
      } else if (cachedDevice != null && cachedDevice.cookieHeader.isNotEmpty) {
        headers['Cookie'] = cachedDevice.cookieHeader;
      }

      try {
        final res = await _dio.post<String>(
          signed.signedUrl,
          data: signed.bodyBytes,
          options: Options(headers: headers),
        );
        if (res.statusCode == 200 && (res.data ?? '').isNotEmpty) {
          final parsed = parseDiscoveryResponse(
            res.data!,
            selection: selection,
            cursor: cursor,
          );
          if (parsed.selectorGroups.isNotEmpty) {
            _selectorCache[selection.genreKind] = parsed.selectorGroups;
          }
          if (parsed.items.isNotEmpty || !parsed.hasMore) {
            return parsed;
          }
        }
      } catch (e) {
        lastErr = e is Exception ? e : Exception(e.toString());
      }
    }

    // Fallback gracefully to website SSR if upstream App API unreachable
    try {
      final fallbackGenre = _mapThemeIdToWebSlug(
        selection.genreKind,
        selection.valueOf('category_dim_theme'),
      );
      final webPage = (cursor?.page ?? 1);
      final webRes = await HongguoResolver(dio: _dio).browseList(
        category: selection.genreKind.categorySlug,
        genre: fallbackGenre,
        page: webPage,
      );
      final groups = getSelectorGroups(selection.genreKind);
      final nextCursor = webPage < webRes.totalPages
          ? HongguoDiscoveryCursor(
              offset: webPage * 24,
              sessionId: 'web-fallback',
              page: webPage + 1,
            )
          : null;
      return HongguoDiscoveryPage(
        items: webRes.items,
        selectorGroups: groups,
        nextCursor: nextCursor,
        hasMore: nextCursor != null,
        fromFallback: true,
      );
    } catch (e) {
      if (lastErr != null) throw lastErr;
      rethrow;
    }
  }

  /// Parse JSON trả về từ `/reading/distribution/category/landpage/v/`.
  @visibleForTesting
  HongguoDiscoveryPage parseDiscoveryResponse(
    String raw, {
    required HongguoDiscoverySelection selection,
    HongguoDiscoveryCursor? cursor,
  }) {
    final root = jsonDecode(raw);
    if (root is! Map || (root['code'] ?? -1) != 0) {
      throw StateError('landpage error code=${root is Map ? root['code'] : 'invalid'}');
    }
    final data = root['data'];
    if (data is! Map) {
      throw StateError('landpage data missing');
    }

    final seen = <String>{};
    final items = <HongguoDramaItem>[];
    final rows = data['video_data'];
    if (rows is List) {
      for (final rawItem in rows) {
        if (rawItem is! Map) continue;
        final parsed = HongguoResolver.parseDramaItemMap(
          Map<String, dynamic>.from(rawItem),
          seen,
          inferredSourceCategory: selection.genreKind.categorySlug,
        );
        if (parsed != null) {
          items.add(parsed);
        }
      }
    }

    final parsedGroups = <HongguoSelectorGroup>[];
    final selectorRows = data['selector_rows'];
    if (selectorRows is List && selectorRows.isNotEmpty) {
      final seenGroupTypes = <String>{};
      for (final row in selectorRows) {
        if (row is! Map) continue;
        final type = (row['type'] ?? '').toString().trim();
        final label = HongguoDiscoverySelection.axisLabels[type];
        if (label == null || !seenGroupTypes.add(type)) continue;
        final rawOptions = row['items'];
        final options = <HongguoSelectorOption>[];
        final seenOptIds = <String>{};
        if (rawOptions is List) {
          for (final o in rawOptions) {
            if (o is! Map) continue;
            final id = (o['selector_item_id'] ?? '').toString().trim();
            final name = (o['show_name'] ?? '').toString().trim();
            if (RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id) &&
                name.isNotEmpty &&
                seenOptIds.add(id)) {
              options.add(HongguoSelectorOption(id: id, showName: name));
            }
          }
        }
        if (options.isNotEmpty) {
          parsedGroups.add(
            HongguoSelectorGroup(type: type, label: label, options: options),
          );
        }
      }
    }

    final groups = parsedGroups.isNotEmpty
        ? parsedGroups
        : getSelectorGroups(selection.genreKind);

    final page = cursor?.page ?? 1;
    final hasMoreFlag = data['has_more'] == true && page < 100;
    HongguoDiscoveryCursor? nextCursor;
    if (hasMoreFlag) {
      final nextOffset =
          int.tryParse((data['next_offset'] ?? -1).toString()) ?? -1;
      final prevOffset = cursor?.offset ?? 0;
      final session = (data['session_id'] ?? '').toString().trim();
      final effectiveSession =
          session.isNotEmpty ? session : (cursor?.sessionId ?? '');
      if (nextOffset > prevOffset && effectiveSession.isNotEmpty) {
        nextCursor = HongguoDiscoveryCursor(
          offset: nextOffset,
          sessionId: effectiveSession,
          page: page + 1,
        );
      }
    }

    // Nếu người dùng bấm tag phụ (như 青梅竹马, 甜宠) không có nút chọn riêng trên server,
    // đẩy phim khớp đúng tag phụ lên trước trong vẫn đúng kho nội dung đang lọc.
    final hint = selection.tagHint;
    if (hint.isNotEmpty && items.length > 1) {
      items.sort((a, b) {
        final aExact = a.tags.contains(hint) || a.title.contains(hint) ? 1 : 0;
        final bExact = b.tags.contains(hint) || b.title.contains(hint) ? 1 : 0;
        return bExact.compareTo(aExact);
      });
    }

    return HongguoDiscoveryPage(
      items: items,
      selectorGroups: groups,
      nextCursor: nextCursor,
      hasMore: nextCursor != null,
    );
  }

  /// Kéo luồng Đề xuất trang chủ chính thức của App Hồng Quả:
  /// `bookmall/tab/v1/` (trang 1) -> `bookmall/cell/change/v1/` (kéo vô tận không lặp).
  Future<HongguoOfficialFeedPage> fetchOfficialRecommendations({
    HongguoOfficialFeedCursor cursor = const HongguoOfficialFeedCursor(),
  }) async {
    final creds = HongguoCloudAccountService.instance.state.value.credentials;
    final useCookie = creds != null && creds.isValid;
    var activeCursor = cursor;

    for (var attempt = 0; attempt < 3; attempt++) {
      final host = _feedHosts[(attempt + 1) % _feedHosts.length];
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final useCellFlow = activeCursor.hasCellContinuation;
      final path = useCellFlow
          ? '/reading/bookapi/bookmall/cell/change/v1/'
          : '/reading/bookapi/bookmall/tab/v1/';

      final params = <String, String>{
        'aid': '8662',
        'app_name': 'novelread',
        'channel': 'update_64',
        'device_platform': 'android',
        'os': 'android',
        'ssmix': 'a',
        'device_type': '25053RT47C',
        'device_brand': 'Redmi',
        'language': 'zh',
        'os_api': '36',
        'os_version': '16',
        'resolution': '1280*2772',
        'dpi': '520',
        'ac': 'wifi',
        'version_code': '73532',
        'version_name': '7.3.5.32',
        'manifest_version_code': '73532',
        'update_version_code': '73532',
        'tab_type': '16',
        'bottom_tab_type': '7',
        'landing_bottom_tab_type': '7',
        'offset': activeCursor.offset.toString(),
        'client_req_type': useCellFlow || activeCursor.offset > 0 ? '2' : '1',
        '_rticket': nowMs.toString(),
      };
      if (activeCursor.sessionId.isNotEmpty) {
        params['session_id'] = activeCursor.sessionId;
      }
      if (useCellFlow) {
        params['cell_id'] = activeCursor.cellId;
        params['plan_id'] = activeCursor.planId;
        params['version_tag'] = activeCursor.versionTag;
        params['client_template'] = '7';
        params['change_type'] = '0';
        params['client_req_type'] = '2';
        if (activeCursor.seenIds.isNotEmpty) {
          params['filter_ids'] = activeCursor.seenIds.take(150).join(',');
        }
      }

      // Chế độ unsigned GET theo RecommendationFeed.kt (không nhét device_id/iid kèm cookie tài khoản).
      // Nếu có tài khoản đăng nhập + v5 không bị 110, kèm Cookie để cá nhân hóa theo lịch sử thật!
      final uri = Uri.parse('$host$path').replace(queryParameters: params);
      final headers = <String, String>{
        'User-Agent': 'com.dragon.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C)',
        'Accept': 'application/json',
        'X-XS-From-Web': '0',
        'Sdk-Version': '2',
        'Accept-Language': 'zh-CN,zh;q=0.9',
      };
      if (useCookie && !activeCursor.unsignedFallback) {
        headers['Cookie'] = creds.cookie;
      }

      try {
        final res = await _dio.get<String>(
          uri.toString(),
          options: Options(headers: headers),
        );
        final raw = res.data ?? '';
        if (res.statusCode != 200 || raw.isEmpty) continue;
        final json = jsonDecode(raw);
        if (json is! Map) continue;
        final code = json['code'];
        if (code == 110) {
          activeCursor = const HongguoOfficialFeedCursor(unsignedFallback: true);
          continue;
        }
        if (code != 0) continue;

        final parsed = useCellFlow
            ? parseBookmallCellResponse(raw, activeCursor)
            : parseBookmallTabResponse(raw, activeCursor);

        final fresh = parsed.items
            .where((d) => !activeCursor.seenIds.contains(d.seriesId))
            .toList();
        final mergedSeen = <String>{
          ...activeCursor.seenIds,
          ...parsed.items.map((e) => e.seriesId),
        };
        activeCursor = parsed.nextCursor.copyWith(seenIds: mergedSeen);
        if (fresh.isNotEmpty) {
          return HongguoOfficialFeedPage(
            items: fresh,
            nextCursor: activeCursor,
          );
        }
      } catch (_) {}
    }

    // Fallback về landpage hot_score nếu bookmall tạm thời không trả item mới
    final fallbackPage = await fetchDiscovery(
      const HongguoDiscoverySelection(
        genreKind: HongguoGenreKind.realPlay,
        filters: <String, String>{'sort': 'hot_score'},
      ),
      seenIds: activeCursor.seenIds,
    );
    return HongguoOfficialFeedPage(
      items: fallbackPage.items,
      nextCursor: activeCursor.copyWith(
        seenIds: <String>{
          ...activeCursor.seenIds,
          ...fallbackPage.items.map((e) => e.seriesId),
        },
      ),
    );
  }

  /// Parse response từ `GET /reading/bookapi/bookmall/tab/v1/`.
  @visibleForTesting
  HongguoOfficialFeedPage parseBookmallTabResponse(
    String raw,
    HongguoOfficialFeedCursor cursor,
  ) {
    final root = jsonDecode(raw) as Map<String, dynamic>;
    final data = root['data'] as Map?;
    final tabItems = data?['tab_item'] as List? ?? const [];
    Map? tab16;
    for (final t in tabItems) {
      if (t is Map && t['tab_type'].toString() == '16') {
        tab16 = t;
        break;
      }
    }
    if (tab16 == null) {
      throw const FormatException('bookmall tab_type=16 missing');
    }

    final session = (tab16['session_id'] ?? '').toString().trim();
    final cellData = tab16['cell_data'] as List? ?? const [];
    final items = _extractVideosFromBookmallCells(cellData);

    var cellId = '';
    var planId = '';
    var versionTag = '';
    if (tab16['bottom_unlimited'] == true &&
        (int.tryParse((tab16['client_template'] ?? -1).toString()) == 7)) {
      if (cellData.isNotEmpty && cellData.first is Map) {
        final firstCell = cellData.first as Map;
        cellId = (firstCell['cell_id_str'] ?? firstCell['cell_id'] ?? '')
            .toString()
            .trim();
      }
      planId = (tab16['bookstore_id'] ?? '').toString().trim();
      versionTag = (tab16['version_tag'] ?? '').toString().trim();
    }

    final int nextOffset = (cellId.isNotEmpty && planId.isNotEmpty)
        ? 0
        : cursor.offset + max<int>(1, items.length);

    return HongguoOfficialFeedPage(
      items: items,
      nextCursor: cursor.copyWith(
        sessionId: session.isNotEmpty ? session : cursor.sessionId,
        offset: nextOffset,
        cellId: cellId,
        planId: planId,
        versionTag: versionTag,
      ),
    );
  }

  /// Parse response từ `GET /reading/bookapi/bookmall/cell/change/v1/`.
  @visibleForTesting
  HongguoOfficialFeedPage parseBookmallCellResponse(
    String raw,
    HongguoOfficialFeedCursor cursor,
  ) {
    final root = jsonDecode(raw) as Map<String, dynamic>;
    final data = root['data'] as Map? ?? const {};
    final cellView = data['cell_view'];
    final cells = <dynamic>[
      if (cellView is Map && cellView.containsKey('cell_data'))
        cellView
      else if (cellView is Map)
        <String, dynamic>{'cell_data': <dynamic>[cellView]},
    ];
    final items = _extractVideosFromBookmallCells(cells);
    final nextOffset =
        int.tryParse((data['next_offset'] ?? '').toString()) ??
        (cursor.offset + max(1, items.length));
    final session = (data['session_id'] ?? '').toString().trim();
    return HongguoOfficialFeedPage(
      items: items,
      nextCursor: cursor.copyWith(
        sessionId: session.isNotEmpty ? session : cursor.sessionId,
        offset: nextOffset,
      ),
    );
  }

  List<HongguoDramaItem> _extractVideosFromBookmallCells(List<dynamic> cells) {
    final seen = <String>{};
    final items = <HongguoDramaItem>[];

    void addVideos(dynamic rawList) {
      if (rawList is! List) return;
      for (final rawVideo in rawList) {
        if (rawVideo is! Map) continue;
        final detail = rawVideo['video_detail'] is Map
            ? Map<String, dynamic>.from(rawVideo['video_detail'] as Map)
            : Map<String, dynamic>.from(rawVideo);
        final parsed = HongguoResolver.parseDramaItemMap(detail, seen);
        if (parsed != null) items.add(parsed);
      }
    }

    for (final cell in cells) {
      if (cell is! Map) continue;
      addVideos(cell['video_data']);
      final inner = cell['cell_data'] as List? ?? const [];
      for (final card in inner) {
        if (card is! Map) continue;
        addVideos(card['video_data']);
      }
    }
    return items;
  }

  /// Lấy đề xuất chính thức từ `/reading/bookapi/plan/v:version/` (`scene=10`):
  /// - `show_type == 547` (`相关作品`): Các phần / mùa liên quan.
  /// - `show_type == 506` (`猜你喜欢`): Đề xuất tương tự chuẩn xác từ ByteDance (`相关推荐`).
  Future<HongguoRelatedBundle> fetchRelatedAndSimilar(
    String seriesId, {
    String? sourceCategory,
    List<String> categoryIds = const <String>[],
    List<String> tags = const <String>[],
  }) async {
    final cleanId = seriesId.trim();
    if (cleanId.isEmpty) return const HongguoRelatedBundle();

    final cachedDevice = await _safeGetDevice();
    final params = <String, String>{
      ..._baseAppParams(versionCode: '72232', versionName: '7.2.2.32'),
      'scene': '10',
      'from': 'detail_page_more_related',
      'book_id': cleanId,
      'new_search_middle_page': 'false',
      'bookstore_tab_type': '0',
      'query_history_removed': 'false',
      'user_is_login': '0',
      'bookstore_tab': '0',
      'search_middle_page_version': '0',
      'pad_column_detail': '0',
      'hot_word_exchange': 'false',
      'device_level': '3',
      'limit': '0',
      'offset': '0',
      'is_horizontal_screen': 'false',
      'reader_single_col_from_ip_strategy': 'false',
    };

    const hosts = <String>[
      'https://api5-normal-sinfonlinec.fqnovel.com',
      'https://api5-normal-hl.fqnovel.com',
      'https://api5-normal-lf.fqnovel.com',
    ];

    for (final host in hosts) {
      try {
        final signedHeaders = HongguoV5Signer.signHeadersV3(
          baseUrl: '$host/reading/bookapi/plan/v:version/',
          extraParams: params,
          device: cachedDevice,
          playback: false,
          includeHelios: true,
        );
        final signedUrl = signedHeaders['_signedUrl']!;
        final reqHeaders = Map<String, String>.from(signedHeaders)
          ..remove('_signedUrl');
        reqHeaders['User-Agent'] = HongguoV5Constants.appUa;
        reqHeaders['Accept'] = 'application/json';

        final res = await _dio.get<String>(
          signedUrl,
          options: Options(headers: reqHeaders),
        );
        final raw = res.data ?? '';
        if (res.statusCode == 200 && raw.isNotEmpty) {
          final bundle = parseRelatedPlanResponse(
            raw,
            currentSeriesId: cleanId,
            fallbackSourceCategory: sourceCategory,
          );
          if (bundle.seasons.isNotEmpty || bundle.similarDramas.isNotEmpty) {
            return bundle;
          }
        }
      } catch (_) {}
    }

    // Fallback: truy vấn đúng kho & tag tương ứng qua `landpage` (không trộn Người thật)
    if (tags.isNotEmpty || (sourceCategory ?? '').isNotEmpty) {
      try {
        final fallbackTag = tags.isNotEmpty ? tags.first : '';
        final selection = resolveSelectionForTag(
          fallbackTag,
          preferredSourceCategory: sourceCategory,
          categoryIds: categoryIds,
          allDramaTags: tags,
        );
        final page = await fetchDiscovery(selection, seenIds: <String>{cleanId});
        return HongguoRelatedBundle(
          similarDramas:
              page.items.where((d) => d.seriesId != cleanId).toList(),
        );
      } catch (_) {}
    }

    return const HongguoRelatedBundle();
  }

  /// Parse JSON từ `/reading/bookapi/plan/v:version/` cho cả `547` và `506`.
  @visibleForTesting
  HongguoRelatedBundle parseRelatedPlanResponse(
    String raw, {
    required String currentSeriesId,
    String? fallbackSourceCategory,
  }) {
    final root = jsonDecode(raw);
    if (root is! Map || (root['code'] ?? -1) != 0) {
      return const HongguoRelatedBundle();
    }
    final cells = root['data'];
    if (cells is! List) return const HongguoRelatedBundle();

    final seasons = <HongguoRelatedSeasonItem>[];
    final seenSeasonIds = <String>{currentSeriesId};
    final similar = <HongguoDramaItem>[];
    final seenSimilarIds = <String>{currentSeriesId};

    for (final rawCell in cells) {
      if (rawCell is! Map) continue;
      final showType = int.tryParse((rawCell['show_type'] ?? -1).toString());
      final cellName = (rawCell['cell_name'] ?? '').toString().trim();

      // 1. Các mùa / phần liên quan (show_type == 547)
      if (showType == 547 || cellName == '相关作品') {
        final rows = rawCell['video_data'] as List? ?? const [];
        for (final row in rows) {
          if (row is! Map) continue;
          final map = Map<String, dynamic>.from(row);
          final contentType =
              int.tryParse((map['content_type'] ?? 0).toString()) ?? 0;
          if (contentType != 1004 && contentType != 1007) continue;
          final upcoming = contentType == 1007;
          final epCnt =
              int.tryParse((map['episode_cnt'] ?? 0).toString()) ?? 0;
          if (!upcoming && (map['disable_play'] == true || epCnt <= 0)) {
            continue;
          }
          final item = HongguoResolver.parseDramaItemMap(
            map,
            seenSeasonIds,
            inferredSourceCategory: fallbackSourceCategory ?? '',
          );
          if (item == null) continue;
          final seasonIndex =
              int.tryParse((map['season_index'] ?? 0).toString()) ?? 0;
          final tagInfo = map['tag_info'] is Map
              ? ((map['tag_info'] as Map)['text'] ?? '').toString().trim()
              : '';
          final seasonLabel = tagInfo.isNotEmpty
              ? tagInfo
              : (seasonIndex > 0 ? 'Phần $seasonIndex' : '');
          seasons.add(
            HongguoRelatedSeasonItem(
              drama: item,
              seasonLabel: seasonLabel,
              seasonIndex: seasonIndex < 0 ? 0 : seasonIndex,
              upcoming: upcoming,
            ),
          );
        }
      }

      // 2. Có thể bạn sẽ thích / 相关推荐 (show_type == 506)
      if (showType == 506 || cellName == '猜你喜欢') {
        final innerCells = rawCell['cell_data'] as List? ?? const [];
        for (final sub in innerCells) {
          if (sub is! Map) continue;
          final rows = sub['video_data'] as List? ?? const [];
          for (final row in rows) {
            if (row is! Map) continue;
            final map = Map<String, dynamic>.from(row);
            final item = HongguoResolver.parseDramaItemMap(
              map,
              seenSimilarIds,
              inferredSourceCategory: fallbackSourceCategory ?? '',
            );
            if (item != null) {
              similar.add(item);
            }
          }
        }
        final directRows = rawCell['video_data'] as List? ?? const [];
        for (final row in directRows) {
          if (row is! Map) continue;
          final item = HongguoResolver.parseDramaItemMap(
            Map<String, dynamic>.from(row),
            seenSimilarIds,
            inferredSourceCategory: fallbackSourceCategory ?? '',
          );
          if (item != null) similar.add(item);
        }
      }
    }

    seasons.sort((a, b) {
      final aIdx = a.seasonIndex > 0 ? a.seasonIndex : 9999;
      final bIdx = b.seasonIndex > 0 ? b.seasonIndex : 9999;
      return aIdx.compareTo(bIdx);
    });

    return HongguoRelatedBundle(seasons: seasons, similarDramas: similar);
  }

  /// Tìm kiếm tách biệt theo kho (`tab_type=19` cho Hoạt hình, `tab_type=11` cho Người thật/AI),
  /// fallback sang website search nếu App API không khả dụng.
  Future<HongguoBrowseResult> searchByType(
    String keyword, {
    HongguoGenreKind? genreFilter,
    int page = 1,
  }) async {
    final cleanKw = keyword.trim();
    if (cleanKw.isEmpty) return const HongguoBrowseResult(items: []);
    if (genreFilter == null) {
      return HongguoResolver(dio: _dio).searchList(cleanKw, page: page);
    }

    final cachedDevice = await _safeGetDevice();
    final tabType = genreFilter.searchTab.toString();
    final safePage = page < 1 ? 1 : page;
    final params = <String, String>{
      ..._baseAppParams(versionCode: '72232', versionName: '7.2.2.32'),
      'query': cleanKw,
      'count': '20',
      'offset': ((safePage - 1) * 20).toString(),
      'tab_type': tabType,
      'bookshelf_search_plan': '4',
      'use_correct': 'true',
      'user_is_login': '0',
    };

    try {
      final signedHeaders = HongguoV5Signer.signHeadersV3(
        baseUrl:
            'https://api5-normal-sinfonlinea.fqnovel.com/reading/bookapi/search/tab/v',
        extraParams: params,
        device: cachedDevice,
        includeHelios: true,
      );
      final signedUrl = signedHeaders['_signedUrl']!;
      final reqHeaders = Map<String, String>.from(signedHeaders)
        ..remove('_signedUrl');
      reqHeaders['User-Agent'] = HongguoV5Constants.appUa;
      reqHeaders['Accept'] = 'application/json';

      final res = await _dio.get<String>(
        signedUrl,
        options: Options(headers: reqHeaders),
      );
      final raw = res.data ?? '';
      if (res.statusCode == 200 && raw.isNotEmpty) {
        final root = jsonDecode(raw);
        if (root is Map && (root['code'] ?? -1) == 0) {
          final tabs = root['search_tabs'] ?? root['data']?['search_tabs'];
          if (tabs is List) {
            for (final tab in tabs) {
              if (tab is! Map) continue;
              if (tab['tab_type'].toString() != tabType) continue;
              final rows = tab['data'] as List? ?? const [];
              final seen = <String>{};
              final items = <HongguoDramaItem>[];
              for (final cell in rows) {
                if (cell is! Map) continue;
                final subCells = <dynamic>[cell];
                final lynx = cell['lynx_data'];
                if (lynx is String && lynx.trim().startsWith('{')) {
                  try {
                    final decoded = jsonDecode(lynx);
                    if (decoded is Map && decoded['cell_data'] is List) {
                      subCells.addAll(decoded['cell_data'] as List);
                    }
                  } catch (_) {}
                } else if (lynx is Map && lynx['cell_data'] is List) {
                  subCells.addAll(lynx['cell_data'] as List);
                }
                for (final sub in subCells) {
                  if (sub is! Map) continue;
                  final vids = sub['video_data'];
                  final vidList = vids is List
                      ? vids
                      : (vids is Map ? <dynamic>[vids] : const <dynamic>[]);
                  for (final v in vidList) {
                    if (v is! Map) continue;
                    final map = Map<String, dynamic>.from(v);
                    final parsed = HongguoResolver.parseDramaItemMap(
                      map,
                      seen,
                      inferredSourceCategory: genreFilter.categorySlug,
                    );
                    if (parsed != null) items.add(parsed);
                  }
                }
              }
              final hasMore = tab['has_more'] == true || tab['has_more'] == 1;
              return HongguoBrowseResult(
                items: items,
                currentPage: safePage,
                totalPages: hasMore ? safePage + 1 : safePage,
                totalItems: items.length,
              );
            }
          }
        }
      }
    } catch (_) {}

    // Website fallback filtered by target category when possible
    final webRes = await HongguoResolver(dio: _dio).searchList(cleanKw, page: safePage);
    if (genreFilter == HongguoGenreKind.comicSeries) {
      final comics = webRes.items
          .where((d) =>
              d.sourceCategory == 'category/comic-drama' ||
              d.sourceCategory.isEmpty)
          .toList();
      if (comics.isNotEmpty) {
        return HongguoBrowseResult(
          items: comics,
          currentPage: webRes.currentPage,
          totalPages: webRes.totalPages,
          totalItems: comics.length,
        );
      }
    }
    return webRes;
  }

  Future<HongguoDeviceInfo?> _safeGetDevice() async {
    try {
      return await HongguoDeviceService.instance.getOrRegisterDevice();
    } catch (_) {
      return null;
    }
  }

  static Map<String, String> _baseAppParams({
    required String versionCode,
    required String versionName,
  }) => <String, String>{
    'ac': 'wifi',
    'channel': 'update_64',
    'aid': '8662',
    'app_name': 'novelread',
    'version_code': versionCode,
    'version_name': versionName,
    'device_platform': 'android',
    'os': 'android',
    'ssmix': 'a',
    'device_type': '25053RT47C',
    'device_brand': 'Redmi',
    'language': 'zh',
    'os_api': '36',
    'os_version': '16',
    'manifest_version_code': versionCode,
    'resolution': '1280*2772',
    'dpi': '520',
    'update_version_code': versionCode,
    'host_abi': 'arm64-v8a',
    'dragon_device_type': 'phone',
    'pv_player': versionCode,
    'compliance_status': '0',
    'need_personal_recommend': '1',
    'player_so_load': '1',
    'is_android_pad_screen': '0',
  };

  static String _mapThemeIdToWebSlug(HongguoGenreKind kind, String themeId) {
    if (themeId.isEmpty) return '';
    if (kind == HongguoGenreKind.realPlay) {
      const m = <String, String>{
        'cate_5000': 'romance',
        'cate_5023': 'youth',
        'cate_5022': 'urban',
        'cate_5007': 'costume',
        'cate_5031': 'comeback',
        'cate_5002': 'clan',
        'cate_5001': 'family',
        'cate_5008': 'fantasy',
        'cate_5004': 'suspense',
        'cate_5021': 'period',
        'cate_5003': 'cute-kids',
        'cate_5024': 'comedy',
        'cate_5030': 'drama',
        'cate_5009': 'wonder',
        'cate_5010': 'growth',
        'cate_5011': 'legend',
        'cate_5006': 'supernatural',
        'cate_5025': 'sci-fi',
        'cate_5132': 'thriller',
        'cate_5133': 'horror',
        'cate_9163': 'action-adventure',
        'cate_9165': 'action-adventure',
        'cate_5026': 'disaster',
        'cate_5028': 'war',
        'cate_5029': 'variety',
      };
      return m[themeId] ?? '';
    }
    const m = <String, String>{
      'cate_7': 'fantasy',
      'cate_755': 'creative',
      'cate_316': 'drama',
      'cate_936': 'wealthy-family',
      'cate_6': 'wonder',
      'cate_1182': 'adventure',
      'cate_68': 'apocalypse',
      'cate_1092': 'sci-fi',
    };
    return m[themeId] ?? '';
  }
}
