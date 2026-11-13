import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../ai/live/gemini_live_client.dart';
import '../../ai/offline_mlkit_translator.dart';
import '../hongguo_resolver.dart';

typedef HongguoTitleTranslator = Future<String> Function(String zhTitle);

enum HongguoSourceConfidence {
  confirmed,
  keywordHybrid,
  unknown,
}

class HongguoAssistantCandidate {
  final int displayIndex;
  final HongguoDramaItem item;
  final String viTitle;
  final String matchReason;
  final String sourceBadge;
  final HongguoSourceConfidence sourceConfidence;
  final double score;
  final int matchedTier;

  const HongguoAssistantCandidate({
    required this.displayIndex,
    required this.item,
    required this.viTitle,
    required this.matchReason,
    required this.sourceBadge,
    required this.sourceConfidence,
    required this.score,
    this.matchedTier = 0,
  });

  String get seriesId => item.seriesId;

  HongguoAssistantCandidate copyWith({
    int? displayIndex,
    HongguoDramaItem? item,
    String? viTitle,
    String? matchReason,
    String? sourceBadge,
    HongguoSourceConfidence? sourceConfidence,
    double? score,
    int? matchedTier,
  }) {
    return HongguoAssistantCandidate(
      displayIndex: displayIndex ?? this.displayIndex,
      item: item ?? this.item,
      viTitle: viTitle ?? this.viTitle,
      matchReason: matchReason ?? this.matchReason,
      sourceBadge: sourceBadge ?? this.sourceBadge,
      sourceConfidence: sourceConfidence ?? this.sourceConfidence,
      score: score ?? this.score,
      matchedTier: matchedTier ?? this.matchedTier,
    );
  }
}

class HongguoSearchReport {
  final String traceSummary;
  final List<String> executedQueries;
  final String sourceLabel;
  final String modeLabel;
  final int totalPoolCount;
  final List<HongguoAssistantCandidate> candidates;

  const HongguoSearchReport({
    required this.traceSummary,
    required this.executedQueries,
    required this.sourceLabel,
    required this.modeLabel,
    required this.totalPoolCount,
    required this.candidates,
  });
}

class HongguoUiLocks {
  /// '' (Tất cả) hoặc 'category/real-drama', 'category/comic-drama', 'category/ai-drama'
  final String sourceCategory;

  /// null nếu để AI tự lấy theo câu nói (mặc định 5), hoặc số lượng user chốt trên chip
  final int? lockedCount;

  /// Các phim user chạm "Chọn/Ghim" trên UI thẻ
  final List<String> pinnedSeriesIds;

  const HongguoUiLocks({
    this.sourceCategory = '',
    this.lockedCount,
    this.pinnedSeriesIds = const [],
  });
}

class _RawCandidateAccumulator {
  HongguoDramaItem item;
  int bestTier = 99;
  final Set<String> hitQueries = {};
  final Set<String> matchedConcepts = {};
  bool inTagBrowse = false;
  bool inRankBoard = false;
  bool confirmedExpectedSource = false;

  _RawCandidateAccumulator(this.item);
}

/// Bộ não điều phối Tool Calling, Tìm kiếm Hẹp → Rộng (Phương án A Lai),
/// Chấm điểm cục bộ, Ghim/Đánh số `#STT` và Tổng hợp cốt truyện cho Trợ lý Hồng Quả.
class HongguoAssistantEngine {
  final HongguoResolver resolver;
  final HongguoTitleTranslator _translateTitle;

  final List<HongguoAssistantCandidate> _lastDisplayed = [];
  final Map<String, HongguoAssistantCandidate> _candidateCache = {};
  HongguoSearchReport? _lastSearchReport;
  HongguoUiLocks _currentLocks = const HongguoUiLocks();

  HongguoAssistantEngine({
    HongguoResolver? resolver,
    HongguoTitleTranslator? translateTitle,
  }) : resolver = resolver ?? HongguoResolver(),
       _translateTitle =
           translateTitle ?? OfflineMlKitTranslator.translateHongguoTitle;

  List<HongguoAssistantCandidate> get lastDisplayedCandidates =>
      List.unmodifiable(_lastDisplayed);
  HongguoSearchReport? get lastSearchReport => _lastSearchReport;
  HongguoUiLocks get currentLocks => _currentLocks;

  void updateUiLocks(HongguoUiLocks locks) {
    _currentLocks = locks;
  }

  HongguoAssistantCandidate? getBySeriesId(String seriesId) =>
      _candidateCache[seriesId.trim()];

  HongguoAssistantCandidate? getByDisplayIndex(int index) {
    for (final c in _lastDisplayed) {
      if (c.displayIndex == index) return c;
    }
    return null;
  }

  static const Map<String, String> _genreAliasToSlug = {
    'school': 'youth',
    'campus': 'youth',
    'hocduong': 'youth',
    'thanhxuan': 'youth',
    '校园': 'youth',
    '青春': 'youth',
    'love': 'romance',
    'sweet': 'romance',
    'sweetlove': 'romance',
    'tinhcam': 'romance',
    '爱情': 'romance',
    '甜宠': 'romance',
    'ceo': 'clan',
    'haomon': 'clan',
    'wealthy': 'wealthy-family',
    '豪门': 'wealthy-family',
    '家族': 'clan',
    'xianxia': 'fantasy',
    'tutien': 'fantasy',
    'huyenhuyen': 'fantasy',
    '玄幻': 'fantasy',
    '修仙': 'fantasy',
    'system': 'creative',
    'hethong': 'creative',
    'naodong': 'creative',
    '脑洞': 'creative',
    '系统': 'creative',
    '末世': 'apocalypse',
    'matthe': 'apocalypse',
    '科幻': 'sci-fi',
    'khoahuyen': 'sci-fi',
    '逆袭': 'comeback',
    'nghichtap': 'comeback',
    '都市': 'urban',
    'dothi': 'urban',
    '古装': 'costume',
    'cotrang': 'costume',
    '奇幻': 'wonder',
    'kyao': 'wonder',
    '剧情': 'drama',
    'chinhkich': 'drama',
    '悬疑': 'suspense',
    'trinhtham': 'suspense',
    '惊悚': 'thriller',
    'giatgan': 'thriller',
    '恐怖': 'horror',
    'kinhdi': 'horror',
    '传奇': 'legend',
    'kytruyen': 'legend',
    '灾难': 'disaster',
    'thamhoa': 'disaster',
    '战争': 'war',
    'chientranh': 'war',
    '动作': 'action-adventure',
    'hanhdong': 'action-adventure',
    '冒险': 'adventure',
    'phieuluu': 'adventure',
    '志怪': 'supernatural',
    'linhdi': 'supernatural',
    '萌宝': 'cute-kids',
    'manhbao': 'cute-kids',
    '成长': 'growth',
    'truongthanh': 'growth',
    '家庭': 'family',
    'giadinh': 'family',
    '年代': 'period',
    'niendai': 'period',
    '喜剧': 'comedy',
    'haihuoc': 'comedy',
    '综艺': 'variety',
    'show': 'variety',
  };

  static const Map<String, String> _slugToFallbackZh = {
    'youth': '校园',
    'romance': '甜宠',
    'clan': '豪门',
    'wealthy-family': '豪门',
    'comeback': '逆袭',
    'urban': '都市',
    'costume': '古装',
    'fantasy': '玄幻',
    'sci-fi': '科幻',
    'wonder': '奇幻',
    'drama': '剧情',
    'creative': '脑洞',
    'adventure': '冒险',
    'apocalypse': '末世',
    'action-adventure': '动作',
    'supernatural': '志怪',
    'cute-kids': '萌宝',
    'growth': '成长',
    'family': '家庭',
    'period': '年代',
    'suspense': '悬疑',
    'thriller': '惊悚',
    'horror': '恐怖',
    'legend': '传奇',
    'disaster': '灾难',
    'war': '战争',
    'comedy': '喜剧',
    'variety': '综艺',
  };

  /// Khai báo System Instruction sinh động trực tiếp từ danh mục thật của `HongguoResolver`.
  static String buildSystemPrompt({
    bool compactVoiceStyle = false,
    int defaultCount = 5,
  }) {
    final realList = HongguoResolver.realDramaGenres
        .where((g) => g.slug.isNotEmpty)
        .map((g) => '${g.slug}=${g.label}')
        .join(', ');
    final comicList = HongguoResolver.comicDramaGenres
        .where((g) => g.slug.isNotEmpty)
        .map((g) => '${g.slug}=${g.label}')
        .join(', ');
    final aiList = HongguoResolver.aiDramaGenres
        .where((g) => g.slug.isNotEmpty)
        .map((g) => '${g.slug}=${g.label}')
        .join(', ');
    final rankList = HongguoResolver.rankBoards
        .map((r) => '${r.slug.replaceFirst('rank/', '')} (${r.label})')
        .join(', ');

    return '''Bạn là **Trợ lý AI Tìm Phim Ngắn Hồng Quả** thông minh nói Tiếng Việt tự nhiên.
NGUYÊN TẮC BẮT BUỘC:
1. KHÔNG BAO GIỜ tự bịa tên phim, mô tả hay link ngoài dữ liệu thật. ỨNG DỤNG CHỈ HIỂN THỊ ĐƯỢC ẢNH BÌA VÀ THẺ PHIM KHI BẠN GỌI TOOL (`progressive_search`, `browse_by_category`, `get_rankings`) — vì vậy với MỌI yêu cầu tìm phim, gợi ý phim, hỏi BXH hay đổi chủ đề phim mới, BẮT BUỘC phải gọi tool trước khi trả lời chữ/thoại.
2. LUÔN dùng đúng các mã danh mục / thể loại / BXH thực tế của app dưới đây (KHÔNG tự chế slug):
   - Loại nguồn (`source_type`): `all` (Tất cả), `real-drama` (Người thật), `comic-drama` (Hoạt hình), `ai-drama` (Phim AI).
   - Thể loại của `real-drama` (24 loại): $realList
   - Thể loại của `comic-drama` (8 loại): $comicList
   - Thể loại của `ai-drama` (8 loại): $aiList
   - 10 Bảng xếp hạng (`rank_board`): $rankList
3. CHIẾN LƯỢC TÌM THEO MÔ TẢ (HẸP → RỘNG):
   - Khi người dùng mô tả phim bằng Tiếng Việt (vd: "học đường thanh xuân, nữ chính mạnh mẽ, tình yêu ngọt ngào"), hãy gọi `progressive_search` với:
     * `queries_narrow_to_broad`: mảng 3–5 từ khóa tiếng Trung sắp từ HẸP nhất đến RỘNG dần (Lớp 1 ghép ý chính vd `["校园 甜宠", "青春 女强"]`, Lớp 2 cặp ý/gần nghĩa vd `["校园甜宠", "大女主 甜宠"]`, Lớp 3 ý đơn cốt lõi vd `["校园", "甜宠", "女强"]`).
     * `target_zh_keywords`: các từ khóa cốt lõi (`["校园", "青春", "甜宠", "女强", "大女主"]`) để app tự đối chiếu tag và cốt truyện.
     * Nếu người dùng yêu cầu loại phim (`real-drama`, `comic-drama`, `ai-drama`) mà thể loại họ mô tả KHÔNG có trong enum của loại đó (vd `ai-drama` không có `youth` hay `romance`), ĐỪNG bịa slug; hãy BỎ QUA hoàn toàn tham số `genre_slug` (không truyền key này) hoặc chọn slug gần nhất như `drama` kết hợp với `progressive_search`!
4. SỐ LƯỢNG GỢI Ý (`limit`): Mặc định $defaultCount phim trừ khi người dùng nêu rõ số lượng (vd "gợi ý 3 phim", "tìm 12 bộ") hoặc UI đã khóa số lượng.
5. BẢNG XẾP HẠNG: Khi người dùng hỏi phim hot, phổ biến, mới ra, điểm cao, nhiều người xem/theo dõi/đặt lịch, hãy gọi `get_rankings` đúng bảng tương ứng (`new-drama`, `prestige-drama`, `followed-drama`, `must-watch-drama`, `hot-search-drama`, `hot-real-drama`, `hot-comic-drama`, `hot-ai-drama`, `subscribe-drama`, `hot-drama`).
6. TỔNG HỢP CỐT TRUYỆN & THAM CHIẾU PHIM:
   - Khi người dùng hỏi về **phim số N** (vd "phim số 2", "#3"), nói tên tiếng Việt trên thẻ, hoặc ghim `seriesId` ở phần `[BỐI CẢNH ĐANG CHỌN]`, hãy ánh xạ chính xác `seriesId` đó.
   - Khi người dùng yêu cầu **"tổng hợp tất cả cốt truyện trong danh sách / chọn cái sát mô tả nhất / tóm tắt"**, hãy gọi ngay `analyze_candidate_plots`, đối chiếu từng tiêu chí của họ với toàn bộ `intro` nhận được, chỉ rõ phim khớp nhất + mức độ khớp + tóm tắt cốt truyện súc tích bằng Tiếng Việt.
7. PHONG CÁCH TRẢ LỜI:
   - Trả lời hoàn toàn bằng Tiếng Việt. Sau khi tool trả kết quả, app đã tự hiển thị thẻ ảnh bìa (#1, #2...) trên màn hình; trong câu trả lời hãy luôn kèm **#1, #2, #3... + Tên Tiếng Việt** và tuyệt đối không kể thêm tên phim ngoài kết quả tool.
   - ${compactVoiceStyle ? 'Chế độ thoại đang bật: nói súc tích, tự nhiên, tránh đọc nguyên chuỗi ID hay ký tự tiếng Trung dài ngoằng.' : 'Trình bày rõ ràng, súc tích, nêu ngắn gọn lý do từng phim khớp mô tả (tag/nguồn/chỉ số).'}''';
  }

  /// Khai báo Function Calling Declarations chuẩn Gemini Live API.
  static List<Map<String, dynamic>> buildFunctionDeclarations({
    bool includeNonBlockingBehavior = false,
  }) {
    final realSlugs = HongguoResolver.realDramaGenres
        .map((g) => g.slug)
        .where((s) => s.isNotEmpty)
        .toList();
    final comicSlugs = HongguoResolver.comicDramaGenres
        .map((g) => g.slug)
        .where((s) => s.isNotEmpty)
        .toList();
    final aiSlugs = HongguoResolver.aiDramaGenres
        .map((g) => g.slug)
        .where((s) => s.isNotEmpty)
        .toList();
    final allGenreSlugs = <String>{
      ...realSlugs,
      ...comicSlugs,
      ...aiSlugs,
    }.toList();
    final rankSlugs = HongguoResolver.rankBoards
        .map((r) => r.slug.replaceFirst('rank/', ''))
        .toList();

    final declarations = <Map<String, dynamic>>[
      {
        'name': 'progressive_search',
        'description':
            'Tìm phim theo mô tả tiếng Việt bằng chiến lược Hẹp → Rộng (từ tổ hợp sát ý đến từng ý đơn) kết hợp lọc nguồn Người thật / Hoạt hình / Phim AI và đối chiếu tag/cốt truyện.',
        'parameters': {
          'type': 'OBJECT',
          'properties': {
            'queries_narrow_to_broad': {
              'type': 'ARRAY',
              'items': {'type': 'STRING'},
              'description':
                  'Danh sách 2-5 từ khóa tìm kiếm tiếng Trung xếp theo thứ tự từ HẸP (ghép 2-3 ý) đến RỘNG dần (từng ý đơn). Ví dụ: ["校园 甜宠", "青春 女强", "校园", "甜宠", "女强"].',
            },
            'target_zh_keywords': {
              'type': 'ARRAY',
              'items': {'type': 'STRING'},
              'description':
                  'Các khái niệm/tag tiếng Trung cốt lõi dùng để chấm điểm khớp trong tên, tag và cốt truyện.',
            },
            'source_type': {
              'type': 'STRING',
              'enum': ['all', 'real-drama', 'comic-drama', 'ai-drama'],
              'description': 'Loại nguồn phim người dùng yêu cầu.',
            },
            'genre_slug': {
              'type': 'STRING',
              'enum': allGenreSlugs,
              'description':
                  'Thể loại bổ trợ khớp với source_type (để rỗng nếu nguồn không có thể loại đó).',
            },
            'limit': {
              'type': 'INTEGER',
              'description':
                  'Số lượng phim trả về theo yêu cầu của người dùng (1..20, mặc định 5).',
            },
          },
          'required': ['queries_narrow_to_broad'],
        },
      },
      {
        'name': 'browse_by_category',
        'description':
            'Duyệt kho phim theo đúng loại nguồn (Người thật / Hoạt hình / Phim AI) và thể loại chính thức của Hồng Quả.',
        'parameters': {
          'type': 'OBJECT',
          'properties': {
            'source_type': {
              'type': 'STRING',
              'enum': ['real-drama', 'comic-drama', 'ai-drama'],
              'description': 'Loại nguồn phim.',
            },
            'genre_slug': {
              'type': 'STRING',
              'enum': allGenreSlugs,
              'description': 'Mã thể loại chuẩn thuộc nguồn đã chọn (rỗng = Tất cả).',
            },
            'page': {
              'type': 'INTEGER',
              'description': 'Trang muốn lấy (mặc định 1).',
            },
            'limit': {
              'type': 'INTEGER',
              'description': 'Số lượng phim gợi ý (1..20).',
            },
          },
          'required': ['source_type'],
        },
      },
      {
        'name': 'get_rankings',
        'description':
            'Lấy danh sách phim từ 10 Bảng Xếp Hạng thật của Hồng Quả (Hot tổng hợp, Hot từng loại, Phim mới, Điểm cao uy tín, Phải xem, Sưu tầm nhiều, Hot tìm kiếm, Đặt lịch).',
        'parameters': {
          'type': 'OBJECT',
          'properties': {
            'board': {
              'type': 'STRING',
              'enum': rankSlugs,
              'description': 'Mã bảng xếp hạng chuẩn.',
            },
            'limit': {
              'type': 'INTEGER',
              'description': 'Số lượng phim Top đầu muốn lấy (1..20).',
            },
          },
          'required': ['board'],
        },
      },
      {
        'name': 'analyze_candidate_plots',
        'description':
            'Lấy toàn bộ cốt truyện đầy đủ (series_intro) của danh sách phim hiện tại (hoặc các số thứ tự / phim đang chọn) để AI tổng hợp, so sánh và chọn ra phim sát mô tả nhất kèm tóm tắt tiếng Việt.',
        'parameters': {
          'type': 'OBJECT',
          'properties': {
            'user_criteria': {
              'type': 'STRING',
              'description': 'Tiêu chí / mô tả của người dùng dùng để so khớp cốt truyện.',
            },
            'indices': {
              'type': 'ARRAY',
              'items': {'type': 'INTEGER'},
              'description':
                  'Danh sách số thứ tự #STT muốn kiểm tra (để trống = tổng hợp toàn bộ danh sách hiện tại).',
            },
            'series_ids': {
              'type': 'ARRAY',
              'items': {'type': 'STRING'},
              'description': 'Danh sách seriesId cụ thể nếu đã chọn/ghim.',
            },
          },
          'required': ['user_criteria'],
        },
      },
    ];
    if (includeNonBlockingBehavior) {
      for (final d in declarations) {
        d['behavior'] = 'NON_BLOCKING';
      }
    }
    return declarations;
  }

  /// Chuẩn hóa nguồn từ mọi cách viết của AI về `'category/...'` hoặc `''`.
  static String normalizeSourceCategory(String? raw) {
    final lower = (raw ?? '').trim().toLowerCase();
    if (lower.isEmpty || lower == 'all') return '';
    if (lower.contains('real') || lower.contains('người') || lower.contains('真人')) {
      return 'category/real-drama';
    }
    if (lower.contains('comic') ||
        lower.contains('hoạt') ||
        lower.contains('anime') ||
        lower.contains('漫')) {
      return 'category/comic-drama';
    }
    if (lower.contains('ai') || lower.contains('trí tuệ')) {
      return 'category/ai-drama';
    }
    return '';
  }

  /// Tool Guard: Kiểm tra & sửa slug thể loại; nếu nguồn không hỗ trợ slug này thì trả fallback keyword Trung.
  static ({String validSlug, String? fallbackKeywordZh, String? guardNote})
  guardGenreForSource(String? rawGenre, String sourceCategory) {
    var candidate = (rawGenre ?? '').trim().toLowerCase();
    if (candidate.isEmpty || candidate == 'all') {
      return (validSlug: '', fallbackKeywordZh: null, guardNote: null);
    }

    // Chuẩn hóa alias nếu AI truyền tiếng Trung/Anh
    final stripped = candidate.replaceAll(RegExp(r'[\s_\-]'), '');
    if (_genreAliasToSlug.containsKey(candidate)) {
      candidate = _genreAliasToSlug[candidate]!;
    } else if (_genreAliasToSlug.containsKey(stripped)) {
      candidate = _genreAliasToSlug[stripped]!;
    }

    if (sourceCategory.isEmpty) {
      // Nếu nguồn = Tất cả, kiểm tra xem slug có thuộc danh sách hợp lệ nào không
      final allValid = {
        ...HongguoResolver.realDramaGenres.map((e) => e.slug),
        ...HongguoResolver.comicDramaGenres.map((e) => e.slug),
        ...HongguoResolver.aiDramaGenres.map((e) => e.slug),
      };
      if (allValid.contains(candidate)) {
        return (validSlug: candidate, fallbackKeywordZh: null, guardNote: null);
      }
      return (
        validSlug: '',
        fallbackKeywordZh: _slugToFallbackZh[candidate] ?? rawGenre?.trim(),
        guardNote: 'Thể loại "$rawGenre" không có slug URL chung, chuyển sang tìm từ khóa.',
      );
    }

    final supported = HongguoResolver.genresForCategory(sourceCategory)
        .map((e) => e.slug)
        .where((s) => s.isNotEmpty)
        .toSet();

    if (supported.contains(candidate)) {
      return (validSlug: candidate, fallbackKeywordZh: null, guardNote: null);
    }

    // Xử lý chéo giữa `clan` (real-drama) và `wealthy-family` (comic/ai)
    if (candidate == 'clan' && supported.contains('wealthy-family')) {
      return (
        validSlug: 'wealthy-family',
        fallbackKeywordZh: null,
        guardNote: 'Đã tự chuẩn hóa `clan` ➔ `wealthy-family` cho nguồn $sourceCategory.',
      );
    }
    if (candidate == 'wealthy-family' && supported.contains('clan')) {
      return (
        validSlug: 'clan',
        fallbackKeywordZh: null,
        guardNote: 'Đã tự chuẩn hóa `wealthy-family` ➔ `clan` cho Người Thật.',
      );
    }
    if ((candidate == 'romance' || candidate == 'youth') &&
        supported.contains('drama') &&
        sourceCategory != 'category/real-drama') {
      return (
        validSlug: 'drama',
        fallbackKeywordZh: _slugToFallbackZh[candidate],
        guardNote:
            'Kho $sourceCategory không có slug `$candidate` (chỉ có ở Người Thật); dùng kết hợp `drama` + tìm từ khóa "${_slugToFallbackZh[candidate]}".',
      );
    }

    final zhFallback = _slugToFallbackZh[candidate] ?? rawGenre?.trim();
    return (
      validSlug: '',
      fallbackKeywordZh: zhFallback,
      guardNote:
          'Kho $sourceCategory không có tag `$rawGenre`; tự chuyển sang tìm kiếm theo từ khóa "$zhFallback".',
    );
  }

  /// Tool Guard: Chuẩn hóa mã 10 BXH thành `rank/...`.
  static String normalizeRankBoard(String? rawBoard) {
    var b = (rawBoard ?? '').trim().toLowerCase();
    b = b.replaceFirst(RegExp(r'^/?rank/'), '');
    final validSlugs = HongguoResolver.rankBoards
        .map((r) => r.slug.replaceFirst('rank/', ''))
        .toSet();
    if (validSlugs.contains(b)) {
      return 'rank/$b';
    }
    if (b.contains('new') || b.contains('mới')) return 'rank/new-drama';
    if (b.contains('prestige') || b.contains('score') || b.contains('điểm')) {
      return 'rank/prestige-drama';
    }
    if (b.contains('follow') || b.contains('lưu') || b.contains('xem')) {
      return 'rank/followed-drama';
    }
    if (b.contains('must') || b.contains('phải')) {
      return 'rank/must-watch-drama';
    }
    if (b.contains('search') || b.contains('tìm')) {
      return 'rank/hot-search-drama';
    }
    if (b.contains('sub') || b.contains('đặt') || b.contains('hóng')) {
      return 'rank/subscribe-drama';
    }
    if (b.contains('ai')) return 'rank/hot-ai-drama';
    if (b.contains('comic') || b.contains('hoạt')) {
      return 'rank/hot-comic-drama';
    }
    if (b.contains('real') || b.contains('người')) {
      return 'rank/hot-real-drama';
    }
    return 'rank/hot-drama';
  }

  /// Thực thi một `LiveFunctionCall` nhận từ Gemini Live và trả `LiveFunctionResponse`.
  Future<LiveFunctionResponse> executeToolCall(
    LiveFunctionCall call, {
    void Function(String statusText)? onProgress,
    void Function(HongguoSearchReport report)? onSearchResultsUpdated,
  }) async {
    try {
      switch (call.name) {
        case 'progressive_search':
          final payload = await _handleProgressiveSearch(
            call.args,
            onProgress: onProgress,
            onSearchResultsUpdated: onSearchResultsUpdated,
          );
          return LiveFunctionResponse(
            id: call.id,
            name: call.name,
            response: payload,
          );
        case 'browse_by_category':
          final payload = await _handleBrowseByCategory(
            call.args,
            onProgress: onProgress,
            onSearchResultsUpdated: onSearchResultsUpdated,
          );
          return LiveFunctionResponse(
            id: call.id,
            name: call.name,
            response: payload,
          );
        case 'get_rankings':
          final payload = await _handleGetRankings(
            call.args,
            onProgress: onProgress,
            onSearchResultsUpdated: onSearchResultsUpdated,
          );
          return LiveFunctionResponse(
            id: call.id,
            name: call.name,
            response: payload,
          );
        case 'analyze_candidate_plots':
          final payload = await _handleAnalyzeCandidatePlots(
            call.args,
            onProgress: onProgress,
          );
          return LiveFunctionResponse(
            id: call.id,
            name: call.name,
            response: payload,
          );
        default:
          return LiveFunctionResponse(
            id: call.id,
            name: call.name,
            response: {'error': 'Hàm không được hỗ trợ: ${call.name}'},
          );
      }
    } catch (e) {
      return LiveFunctionResponse(
        id: call.id,
        name: call.name,
        response: {'error': 'Lỗi khi gọi dữ liệu Hồng Quả: $e'},
      );
    }
  }

  int _resolveEffectiveLimit(dynamic rawLimit) {
    if (_currentLocks.lockedCount != null) {
      return _currentLocks.lockedCount!.clamp(1, 20);
    }
    final parsed = int.tryParse((rawLimit ?? '').toString()) ?? 5;
    return parsed.clamp(1, 20);
  }

  String _resolveEffectiveSource(dynamic rawSource) {
    if (_currentLocks.sourceCategory.isNotEmpty) {
      return _currentLocks.sourceCategory;
    }
    return normalizeSourceCategory(rawSource?.toString());
  }

  Future<Map<String, dynamic>> _handleProgressiveSearch(
    Map<String, dynamic> args, {
    void Function(String)? onProgress,
    void Function(HongguoSearchReport)? onSearchResultsUpdated,
  }) async {
    final limit = _resolveEffectiveLimit(args['limit']);
    final expectedSource = _resolveEffectiveSource(args['source_type']);
    final guard = guardGenreForSource(
      args['genre_slug']?.toString(),
      expectedSource,
    );

    final queries = <String>[];
    final seenQueries = <String>{};
    final rawQueries = args['queries_narrow_to_broad'];
    if (rawQueries is List) {
      for (final q in rawQueries) {
        final clean = q.toString().trim();
        if (clean.isNotEmpty && seenQueries.add(clean)) {
          queries.add(clean);
        }
        if (queries.length >= 5) break;
      }
    }
    if (guard.fallbackKeywordZh != null &&
        guard.fallbackKeywordZh!.isNotEmpty &&
        seenQueries.add(guard.fallbackKeywordZh!)) {
      queries.insert(0, guard.fallbackKeywordZh!);
    }

    final targetKeywords = <String>{};
    final rawTargetKw = args['target_zh_keywords'];
    if (rawTargetKw is List) {
      for (final k in rawTargetKw) {
        final clean = k.toString().trim();
        if (clean.isNotEmpty) targetKeywords.add(clean);
      }
    }
    for (final q in queries) {
      for (final token in q.split(RegExp(r'\s+'))) {
        final t = token.trim();
        if (t.isNotEmpty) targetKeywords.add(t);
      }
    }
    if (guard.fallbackKeywordZh != null && guard.fallbackKeywordZh!.isNotEmpty) {
      targetKeywords.add(guard.fallbackKeywordZh!);
    }

    onProgress?.call(
      'Đang quét Hẹp → Rộng (${queries.take(3).join(" · ")})...',
    );

    // 1. Chạy song song các tầng tìm kiếm (Hẹp -> Rộng)
    final searchFutures = <Future<({int tier, String query, List<HongguoDramaItem> items})>>[];
    for (var i = 0; i < queries.length; i++) {
      final q = queries[i];
      final tier = i;
      searchFutures.add(() async {
        try {
          final res = await resolver.searchList(q, page: 1);
          final combined = List<HongguoDramaItem>.from(res.items);
          // Nếu cần lấy nhiều (>8 phim) và tầng hẹp nhất có trang 2, lấy thêm trang 2
          if (tier == 0 && limit > 8 && res.totalPages > 1) {
            try {
              final resP2 = await resolver.searchList(q, page: 2);
              combined.addAll(resP2.items);
            } catch (_) {}
          }
          return (tier: tier, query: q, items: combined);
        } catch (_) {
          return (tier: tier, query: q, items: <HongguoDramaItem>[]);
        }
      }());
    }

    // 2. Nếu có chỉ định nguồn (hoặc genre), chạy song song Phương án A (Lai thông minh)
    final verifiedSourceIds = <String>{};
    final browseItems = <HongguoDramaItem>[];
    final browseFutures = <Future<void>>[];

    if (expectedSource.isNotEmpty) {
      // Quét trang 1-2 của kho nguồn (+ genre hợp lệ nếu có) và BXH của nguồn đó
      browseFutures.add(() async {
        try {
          final r1 = await resolver.browseList(
            category: expectedSource,
            genre: guard.validSlug,
            page: 1,
          );
          for (final it in r1.items) {
            verifiedSourceIds.add(it.seriesId);
            browseItems.add(it);
          }
        } catch (_) {}
      }());

      if (guard.validSlug.isNotEmpty) {
        browseFutures.add(() async {
          try {
            final rBase = await resolver.browseList(
              category: expectedSource,
              genre: '',
              page: 1,
            );
            for (final it in rBase.items) {
              verifiedSourceIds.add(it.seriesId);
              browseItems.add(it);
            }
          } catch (_) {}
        }());
      } else {
        browseFutures.add(() async {
          try {
            final r2 = await resolver.browseList(
              category: expectedSource,
              page: 2,
            );
            for (final it in r2.items) {
              verifiedSourceIds.add(it.seriesId);
              browseItems.add(it);
            }
          } catch (_) {}
        }());
      }

      final hotRankForSource = switch (expectedSource) {
        'category/ai-drama' => 'rank/hot-ai-drama',
        'category/comic-drama' => 'rank/hot-comic-drama',
        _ => 'rank/hot-real-drama',
      };
      browseFutures.add(() async {
        try {
          final rk = await resolver.browseList(category: hotRankForSource);
          for (final it in rk.items) {
            verifiedSourceIds.add(it.seriesId);
            browseItems.add(it);
          }
        } catch (_) {}
      }());
    } else if (guard.validSlug.isNotEmpty) {
      browseFutures.add(() async {
        try {
          final r = await resolver.browseList(
            category: 'category/real-drama',
            genre: guard.validSlug,
            page: 1,
          );
          browseItems.addAll(r.items);
        } catch (_) {}
      }());
    }

    final searchResults = await Future.wait(searchFutures);
    await Future.wait(browseFutures);

    // 3. Hợp nhất & chấm điểm Hybrid ngay tại Dart
    final rankedPool = rankHybridPool(
      searchTiers: searchResults,
      browseItems: browseItems,
      verifiedSourceIds: verifiedSourceIds,
      expectedSourceCategory: expectedSource,
      targetKeywords: targetKeywords.toList(),
    );

    // Fallback: nếu toàn bộ tìm kiếm từ khóa trả về rỗng (vd từ khóa quá hẹp), lấy kho nổi bật đúng nguồn
    var effectiveRankedPool = rankedPool;
    var usedFallbackBrowse = false;
    if (effectiveRankedPool.isEmpty) {
      final fallbackCategory = expectedSource.isNotEmpty
          ? expectedSource
          : 'rank/hot-drama';
      var fbItems = <HongguoDramaItem>[];
      try {
        final fbRes = await resolver.browseList(
          category: fallbackCategory,
          genre: guard.validSlug,
          page: 1,
        );
        fbItems = fbRes.items;
        if (fbItems.isEmpty && guard.validSlug.isNotEmpty) {
          final fbResWide = await resolver.browseList(
            category: fallbackCategory,
            page: 1,
          );
          fbItems = fbResWide.items;
        }
      } catch (_) {}
      if (fbItems.isNotEmpty) {
        usedFallbackBrowse = true;
        effectiveRankedPool = [
          for (var i = 0; i < fbItems.length; i++)
            HongguoAssistantCandidate(
              displayIndex: i + 1,
              item: fbItems[i],
              viTitle: fbItems[i].title,
              matchReason: fbItems[i].tags.isNotEmpty
                  ? 'Gợi ý nổi bật · ${fbItems[i].tags.take(3).join(" · ")}'
                  : 'Gợi ý phổ biến từ kho Hồng Quả',
              sourceBadge: fbItems[i].sourceCategory.isNotEmpty
                  ? _labelForSource(fbItems[i].sourceCategory)
                  : _labelForSource(expectedSource),
              sourceConfidence: HongguoSourceConfidence.confirmed,
              score: 50.0 - i,
            ),
        ];
      }
    }

    final topPool = effectiveRankedPool.take(math.max(limit * 2, 20)).toList();
    final selected = topPool.take(limit).toList();

    // Chỉ dịch nhanh nhóm phim hiển thị (timeout an toàn 1.8s/tên) để thẻ ảnh bìa hiện lên ngay
    onProgress?.call('Đang dịch tiêu đề & chuẩn bị ${selected.length} phim...');
    final displayed = await _translateCandidates(selected);
    final mergedPool = [
      ...displayed,
      ...topPool.skip(displayed.length),
    ];
    _savePoolToCache(mergedPool, displayed);

    final sourceText = _labelForSource(expectedSource);
    final trace =
        'Nguồn: $sourceText · Hẹp→Rộng [${queries.take(3).join(" → ")}]${usedFallbackBrowse ? " (Mở rộng kho)" : ""} · Chọn Top ${displayed.length}/${effectiveRankedPool.length} phim';

    final report = HongguoSearchReport(
      traceSummary: trace,
      executedQueries: queries,
      sourceLabel: sourceText,
      modeLabel: 'Tìm Hẹp → Rộng${guard.validSlug.isNotEmpty ? " + Tag ${guard.validSlug}" : ""}',
      totalPoolCount: effectiveRankedPool.length,
      candidates: displayed,
    );
    _lastSearchReport = report;
    onSearchResultsUpdated?.call(report);

    return {
      if (guard.guardNote != null) 'guardNote': guard.guardNote,
      'searchTrace': trace,
      'sourceFilter': sourceText,
      'totalPoolMatched': effectiveRankedPool.length,
      'returnedCount': displayed.length,
      'results': displayed.map(_serializeCompactCandidate).toList(),
    };
  }

  /// Logic thuần để chấm điểm & xếp hạng gộp từ search nhiều tầng + browse tag (có thể test đơn vị không cần mạng).
  @visibleForTesting
  static List<HongguoAssistantCandidate> rankHybridPool({
    required List<({int tier, String query, List<HongguoDramaItem> items})>
    searchTiers,
    required List<HongguoDramaItem> browseItems,
    required Set<String> verifiedSourceIds,
    required String expectedSourceCategory,
    required List<String> targetKeywords,
  }) {
    final pool = <String, _RawCandidateAccumulator>{};

    _RawCandidateAccumulator upsert(HongguoDramaItem item) {
      final existing = pool[item.seriesId];
      if (existing == null) {
        final created = _RawCandidateAccumulator(item);
        pool[item.seriesId] = created;
        return created;
      }
      // Gộp thông tin giàu hơn (ưu tiên item có intro, tags, sourceCategory hoặc metricText đầy đủ)
      final mergedTags = <String>{...existing.item.tags, ...item.tags}.toList();
      final mergedIntro = existing.item.intro.length >= item.intro.length
          ? existing.item.intro
          : item.intro;
      final mergedSource = existing.item.sourceCategory.isNotEmpty
          ? existing.item.sourceCategory
          : item.sourceCategory;
      final mergedMetric = existing.item.metricText.isNotEmpty
          ? existing.item.metricText
          : item.metricText;
      final mergedCover = existing.item.cover.isNotEmpty
          ? existing.item.cover
          : item.cover;
      final mergedEp = math.max(existing.item.episodeCount, item.episodeCount);
      existing.item = existing.item.copyWith(
        tags: mergedTags,
        intro: mergedIntro,
        sourceCategory: mergedSource,
        metricText: mergedMetric,
        cover: mergedCover,
        episodeCount: mergedEp,
      );
      return existing;
    }

    for (final tierGroup in searchTiers) {
      for (final item in tierGroup.items) {
        final acc = upsert(item);
        acc.bestTier = math.min(acc.bestTier, tierGroup.tier);
        acc.hitQueries.add(tierGroup.query);
      }
    }

    for (final item in browseItems) {
      final acc = upsert(item);
      acc.inTagBrowse = true;
      if (item.rank != null) acc.inRankBoard = true;
    }

    final scored = <HongguoAssistantCandidate>[];

    for (final acc in pool.values) {
      final item = acc.item;
      final isVerifiedExpected =
          expectedSourceCategory.isNotEmpty &&
          (verifiedSourceIds.contains(item.seriesId) ||
              item.sourceCategory == expectedSourceCategory);
      final isConflictingSource =
          expectedSourceCategory.isNotEmpty &&
          item.sourceCategory.isNotEmpty &&
          item.sourceCategory != expectedSourceCategory &&
          !verifiedSourceIds.contains(item.seriesId);

      // Lọc bỏ nếu phim đã xác thực rõ thuộc loại KHÁC với loại user bắt buộc
      if (isConflictingSource) continue;

      final combinedTags = item.tags.join(' ');
      final searchableText = '${item.title} $combinedTags ${item.intro}';

      var conceptScore = 0.0;
      for (final kw in targetKeywords) {
        final cleanKw = kw.trim();
        if (cleanKw.isEmpty) continue;
        final inTag = item.tags.any((t) => t.contains(cleanKw));
        final inTitle = item.title.contains(cleanKw);
        final inIntro = item.intro.contains(cleanKw);
        if (inTag || inTitle || inIntro) {
          acc.matchedConcepts.add(cleanKw);
          if (inTag) conceptScore += 18;
          if (inTitle) conceptScore += 14;
          if (inIntro) conceptScore += 10;
        }
      }

      // Nếu nguồn bị khóa sang AI/Hoạt hình nhưng item chỉ từ Search chưa rõ nguồn và thậm chí không khớp từ khóa nào, bỏ qua
      if (expectedSourceCategory.isNotEmpty &&
          !isVerifiedExpected &&
          !acc.inTagBrowse &&
          acc.hitQueries.isEmpty) {
        continue;
      }

      double tierScore = 0;
      if (acc.bestTier == 0) {
        tierScore = 34;
      } else if (acc.bestTier == 1) {
        tierScore = 24;
      } else if (acc.bestTier == 2) {
        tierScore = 15;
      } else if (acc.bestTier < 99) {
        tierScore = 9;
      } else if (acc.inTagBrowse) {
        tierScore = 12;
      }

      final intersectionBonus = acc.hitQueries.length >= 2
          ? (acc.hitQueries.length - 1) * 24.0
          : 0.0;

      // Chỉ cho điểm thưởng browse tag khi nó cũng có ít nhất 1 từ khóa khớp hoặc search không có đủ ứng viên
      final browseBonus =
          (acc.inTagBrowse && (acc.matchedConcepts.isNotEmpty || acc.hitQueries.isNotEmpty))
          ? 16.0
          : 0.0;
      final sourceConfirmBonus = isVerifiedExpected ? 36.0 : 0.0;
      final popularityBonus = _parsePopularityBonus(item.metricText);

      // Không hiển thị phim từ browse kho chung nếu hoàn toàn không có concept trùng & chưa được search chạm tới (trừ trường hợp search rỗng toàn bộ)
      if (acc.hitQueries.isEmpty &&
          acc.matchedConcepts.isEmpty &&
          !searchableText.contains(RegExp(r'\S'))) {
        continue;
      }

      final totalScore =
          tierScore +
          intersectionBonus +
          conceptScore +
          browseBonus +
          sourceConfirmBonus +
          popularityBonus;

      // Xây dựng nhãn nguồn & lý do khớp minh bạch
      final HongguoSourceConfidence confidence;
      final String badge;
      if (expectedSourceCategory.isNotEmpty) {
        if (isVerifiedExpected) {
          confidence = HongguoSourceConfidence.confirmed;
          badge = '${_labelForSource(expectedSourceCategory)} (xác thực)';
        } else {
          confidence = HongguoSourceConfidence.keywordHybrid;
          badge = '🔍 Từ khóa (chưa rõ nguồn)';
        }
      } else if (item.sourceCategory.isNotEmpty) {
        confidence = HongguoSourceConfidence.confirmed;
        badge = _labelForSource(item.sourceCategory);
      } else {
        confidence = HongguoSourceConfidence.unknown;
        badge = '🔍 Kho Hồng Quả';
      }

      final reasons = <String>[];
      if (acc.bestTier == 0) {
        reasons.add('Khớp lớp tìm hẹp nhất');
      } else if (acc.hitQueries.length >= 2) {
        reasons.add('Giao ${acc.hitQueries.length} từ khóa');
      } else if (acc.hitQueries.isNotEmpty) {
        reasons.add('Trúng "${acc.hitQueries.first}"');
      }
      if (acc.matchedConcepts.isNotEmpty) {
        reasons.add('Khớp ý: ${acc.matchedConcepts.take(3).join(", ")}');
      } else if (item.tags.isNotEmpty) {
        reasons.add('Tag: ${item.tags.take(3).join(" · ")}');
      }

      scored.add(
        HongguoAssistantCandidate(
          displayIndex: 0,
          item: item,
          viTitle: item.title,
          matchReason: reasons.join(' · '),
          sourceBadge: badge,
          sourceConfidence: confidence,
          score: totalScore,
          matchedTier: acc.bestTier,
        ),
      );
    }

    scored.sort((a, b) {
      // Nếu người dùng không tìm được từ khóa nào trên browse thuần, đẩy mục có concept match lên trước mục browse nền
      final scoreCmp = b.score.compareTo(a.score);
      if (scoreCmp != 0) return scoreCmp;
      return b.item.episodeCount.compareTo(a.item.episodeCount);
    });

    return [
      for (var i = 0; i < scored.length; i++)
        scored[i].copyWith(displayIndex: i + 1),
    ];
  }

  static double _parsePopularityBonus(String metric) {
    if (metric.isEmpty) return 0;
    final m = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(metric);
    if (m == null) return 0;
    final numVal = double.tryParse(m.group(1)!) ?? 0;
    if (metric.contains('亿')) return math.min(12.0, 8.0 + numVal);
    if (metric.contains('万')) return math.min(10.0, numVal / 500.0);
    if (metric.contains('分')) return numVal.clamp(0, 10);
    return 1.0;
  }

  Future<Map<String, dynamic>> _handleBrowseByCategory(
    Map<String, dynamic> args, {
    void Function(String)? onProgress,
    void Function(HongguoSearchReport)? onSearchResultsUpdated,
  }) async {
    final limit = _resolveEffectiveLimit(args['limit']);
    var expectedSource = _resolveEffectiveSource(args['source_type']);
    if (expectedSource.isEmpty) {
      expectedSource = 'category/real-drama';
    }
    final guard = guardGenreForSource(
      args['genre_slug']?.toString(),
      expectedSource,
    );
    final page = (int.tryParse((args['page'] ?? 1).toString()) ?? 1).clamp(1, 34);

    // Nếu nguồn (AI / Hoạt hình) không có slug thể loại này, tự chuyển sang nhánh Lai
    if (guard.validSlug.isEmpty &&
        guard.fallbackKeywordZh != null &&
        guard.fallbackKeywordZh!.isNotEmpty) {
      return _handleProgressiveSearch(
        {
          'queries_narrow_to_broad': [guard.fallbackKeywordZh!],
          'target_zh_keywords': [guard.fallbackKeywordZh!],
          'source_type': expectedSource,
          'limit': limit,
        },
        onProgress: onProgress,
        onSearchResultsUpdated: onSearchResultsUpdated,
      );
    }

    onProgress?.call('Đang tải danh mục ${_labelForSource(expectedSource)}...');
    var res = await resolver.browseList(
      category: expectedSource,
      genre: guard.validSlug,
      page: page,
    );
    if (res.items.isEmpty && guard.validSlug.isNotEmpty) {
      try {
        res = await resolver.browseList(
          category: expectedSource,
          genre: '',
          page: 1,
        );
      } catch (_) {}
    }

    final pool = res.items.take(math.max(limit * 2, 20)).toList();
    final rawCandidates = [
      for (var i = 0; i < pool.length; i++)
        HongguoAssistantCandidate(
          displayIndex: i + 1,
          item: pool[i],
          viTitle: pool[i].title,
          matchReason: pool[i].tags.isNotEmpty
              ? 'Tag: ${pool[i].tags.take(3).join(" · ")}'
              : 'Danh mục chuẩn Hồng Quả',
          sourceBadge: _labelForSource(expectedSource),
          sourceConfidence: HongguoSourceConfidence.confirmed,
          score: 100.0 - i,
        ),
    ];

    final displayed = await _translateCandidates(
      rawCandidates.take(limit).toList(),
    );
    final mergedPool = [
      ...displayed,
      ...rawCandidates.skip(displayed.length),
    ];
    _savePoolToCache(mergedPool, displayed);

    final trace =
        'Danh mục: ${_labelForSource(expectedSource)}${guard.validSlug.isNotEmpty ? " · Thể loại ${guard.validSlug}" : ""} (Trang $page) · Chọn ${displayed.length} phim';
    final report = HongguoSearchReport(
      traceSummary: trace,
      executedQueries: const [],
      sourceLabel: _labelForSource(expectedSource),
      modeLabel: 'Duyệt Danh mục',
      totalPoolCount: res.totalItems > 0 ? res.totalItems : pool.length,
      candidates: displayed,
    );
    _lastSearchReport = report;
    onSearchResultsUpdated?.call(report);

    return {
      if (guard.guardNote != null) 'guardNote': guard.guardNote,
      'searchTrace': trace,
      'returnedCount': displayed.length,
      'totalPages': res.totalPages,
      'results': displayed.map(_serializeCompactCandidate).toList(),
    };
  }

  Future<Map<String, dynamic>> _handleGetRankings(
    Map<String, dynamic> args, {
    void Function(String)? onProgress,
    void Function(HongguoSearchReport)? onSearchResultsUpdated,
  }) async {
    final limit = _resolveEffectiveLimit(args['limit']);
    var rankRoute = normalizeRankBoard(args['board']?.toString());

    // Nếu người dùng khóa Nguồn trên UI và BXH yêu cầu là hot chung -> tự chuyển BXH hot theo nguồn đó
    if (_currentLocks.sourceCategory.isNotEmpty && rankRoute == 'rank/hot-drama') {
      rankRoute = switch (_currentLocks.sourceCategory) {
        'category/ai-drama' => 'rank/hot-ai-drama',
        'category/comic-drama' => 'rank/hot-comic-drama',
        _ => 'rank/hot-real-drama',
      };
    }

    final boardLabel = HongguoResolver.rankBoards
        .firstWhere(
          (r) => r.slug == rankRoute,
          orElse: () => const HongguoCategory(
            slug: 'rank/hot-drama',
            label: '🔥 Hot Tổng Hợp',
          ),
        )
        .label;

    onProgress?.call('Đang mở $boardLabel...');
    final res = await resolver.browseList(category: rankRoute, page: 1);

    final pool = res.items.where((item) {
      if (_currentLocks.sourceCategory.isEmpty) return true;
      if (item.sourceCategory.isEmpty) return true;
      return item.sourceCategory == _currentLocks.sourceCategory;
    }).toList();

    final effectivePool = (pool.isNotEmpty ? pool : res.items)
        .take(math.max(limit, 20))
        .toList();

    final rawCandidates = [
      for (var i = 0; i < effectivePool.length; i++)
        HongguoAssistantCandidate(
          displayIndex: i + 1,
          item: effectivePool[i],
          viTitle: effectivePool[i].title,
          matchReason: [
            if (effectivePool[i].rank != null) 'Top #${effectivePool[i].rank}',
            if (effectivePool[i].metricText.isNotEmpty)
              effectivePool[i].metricText,
            if (effectivePool[i].tags.isNotEmpty)
              effectivePool[i].tags.take(2).join(' · '),
          ].join(' · '),
          sourceBadge: effectivePool[i].sourceCategory.isNotEmpty
              ? _labelForSource(effectivePool[i].sourceCategory)
              : boardLabel,
          sourceConfidence: HongguoSourceConfidence.confirmed,
          score: 100.0 - i,
        ),
    ];

    final displayed = await _translateCandidates(
      rawCandidates.take(limit).toList(),
    );
    final mergedPool = [
      ...displayed,
      ...rawCandidates.skip(displayed.length),
    ];
    _savePoolToCache(mergedPool, displayed);

    final trace = '$boardLabel · Top ${displayed.length} phim';
    final report = HongguoSearchReport(
      traceSummary: trace,
      executedQueries: const [],
      sourceLabel: boardLabel,
      modeLabel: 'Bảng Xếp Hạng',
      totalPoolCount: res.items.length,
      candidates: displayed,
    );
    _lastSearchReport = report;
    onSearchResultsUpdated?.call(report);

    return {
      'searchTrace': trace,
      'board': rankRoute,
      'returnedCount': displayed.length,
      'results': displayed.map(_serializeCompactCandidate).toList(),
    };
  }

  Future<Map<String, dynamic>> _handleAnalyzeCandidatePlots(
    Map<String, dynamic> args, {
    void Function(String)? onProgress,
  }) async {
    final criteria = (args['user_criteria'] ?? '').toString().trim();
    final targetIds = <String>{};

    final rawIds = args['series_ids'];
    if (rawIds is List) {
      for (final id in rawIds) {
        final s = id.toString().trim();
        if (s.isNotEmpty) targetIds.add(s);
      }
    }

    final rawIndices = args['indices'];
    if (rawIndices is List) {
      for (final idx in rawIndices) {
        final i = int.tryParse(idx.toString());
        if (i != null) {
          final c = getByDisplayIndex(i);
          if (c != null) targetIds.add(c.seriesId);
        }
      }
    }

    if (targetIds.isEmpty && _currentLocks.pinnedSeriesIds.isNotEmpty) {
      targetIds.addAll(_currentLocks.pinnedSeriesIds);
    }

    final candidatesToInspect = targetIds.isNotEmpty
        ? targetIds
              .map((id) => _candidateCache[id])
              .whereType<HongguoAssistantCandidate>()
              .toList()
        : _lastDisplayed.take(20).toList();

    if (candidatesToInspect.isEmpty) {
      return {
        'error':
            'Hiện chưa có danh sách phim nào trong bộ nhớ để tổng hợp cốt truyện. Hãy tìm hoặc mở một BXH trước.',
      };
    }

    onProgress?.call(
      'Đang gom cốt truyện của ${candidatesToInspect.length} phim để phân tích...',
    );

    // Nạp bổ sung intro cho phim nào bị thiếu (phần lớn search & browse đã có sẵn 100%)
    final enriched = await Future.wait(
      candidatesToInspect.map((cand) async {
        if (cand.item.intro.trim().isNotEmpty) return cand;
        try {
          final detail = await resolver.getDramaDetail(cand.seriesId);
          final updatedItem = cand.item.copyWith(
            intro: detail.intro,
            tags: detail.tags.isNotEmpty ? detail.tags : cand.item.tags,
            episodeCount: detail.totalEpisodes > 0
                ? detail.totalEpisodes
                : cand.item.episodeCount,
          );
          final updated = cand.copyWith(item: updatedItem);
          _candidateCache[cand.seriesId] = updated;
          return updated;
        } catch (_) {
          return cand;
        }
      }),
    );

    return {
      'userCriteria': criteria,
      'analyzedCount': enriched.length,
      'instruction':
          'Hãy đối chiếu từng tiêu chí của người dùng với cốt truyện (intro) của toàn bộ ${enriched.length} phim dưới đây, xếp hạng các phim khớp sát nhất (nêu #STT + Tên Tiếng Việt) và tóm tắt cốt truyện tiếng Việt cho lựa chọn tốt nhất.',
      'candidates': enriched.map((c) {
        final trimmedIntro = c.item.intro.trim();
        final safeIntro = trimmedIntro.length > 260
            ? '${trimmedIntro.substring(0, 260)}...'
            : trimmedIntro;
        return {
          'index': c.displayIndex,
          'seriesId': c.seriesId,
          'viTitle': c.viTitle,
          'zhTitle': c.item.title,
          'tags': c.item.tags,
          'episodeCount': c.item.episodeCount,
          'sourceBadge': c.sourceBadge,
          'metricText': c.item.metricText,
          'intro': safeIntro.isNotEmpty ? safeIntro : '(Chưa có mô tả cốt truyện)',
        };
      }).toList(),
    };
  }

  Future<List<HongguoAssistantCandidate>> _translateCandidates(
    List<HongguoAssistantCandidate> items,
  ) async {
    return Future.wait(
      items.map((cand) async {
        try {
          final cached = OfflineMlKitTranslator.getCachedTitle(cand.item.title);
          if (cached != null && cached.trim().isNotEmpty) {
            return cand.copyWith(viTitle: cached.trim());
          }
          final translated = await _translateTitle(
            cand.item.title,
          ).timeout(const Duration(milliseconds: 1800), onTimeout: () => '');
          if (translated.trim().isNotEmpty) {
            return cand.copyWith(viTitle: translated.trim());
          }
        } catch (_) {}
        return cand;
      }),
    );
  }

  void _savePoolToCache(
    List<HongguoAssistantCandidate> pool,
    List<HongguoAssistantCandidate> displayed,
  ) {
    _lastDisplayed
      ..clear()
      ..addAll(displayed);
    for (final c in pool) {
      _candidateCache[c.seriesId] = c;
    }
  }

  static Map<String, dynamic> _serializeCompactCandidate(
    HongguoAssistantCandidate c,
  ) {
    final intro = c.item.intro.trim();
    final snippet = intro.length > 55 ? '${intro.substring(0, 55)}...' : intro;
    return {
      'index': c.displayIndex,
      'seriesId': c.seriesId,
      'viTitle': c.viTitle,
      'zhTitle': c.item.title,
      'tags': c.item.tags.take(5).toList(),
      'episodeCount': c.item.episodeCount,
      if (c.item.metricText.isNotEmpty) 'metric': c.item.metricText,
      'source': c.sourceBadge,
      if (c.matchReason.isNotEmpty) 'fit': c.matchReason,
      if (snippet.isNotEmpty) 'introSnippet': snippet,
    };
  }

  static String _labelForSource(String sourceCategory) {
    switch (sourceCategory) {
      case 'category/real-drama':
        return '🎬 Người thật';
      case 'category/comic-drama':
        return '🎨 Hoạt hình';
      case 'category/ai-drama':
        return '🤖 Phim AI';
      default:
        return '✨ Tất cả nguồn';
    }
  }

  /// Tạo dòng ngữ cảnh ngắn gọn về nguồn khóa / số lượng / phim đang ghim trên UI.
  String buildUiContextHeader() {
    final notes = <String>[];
    if (_currentLocks.sourceCategory.isNotEmpty) {
      notes.add(
        'NGUỒN ĐÃ CHỌN: ${_currentLocks.sourceCategory.replaceFirst("category/", "")}',
      );
    }
    if (_currentLocks.lockedCount != null) {
      notes.add('SỐ LƯỢNG GỢI Ý CỐ ĐỊNH: ${_currentLocks.lockedCount} phim');
    }
    if (_currentLocks.pinnedSeriesIds.isNotEmpty) {
      final pinnedDesc = _currentLocks.pinnedSeriesIds
          .map((id) {
            final c = _candidateCache[id];
            if (c != null) {
              return '#${c.displayIndex} (seriesId=$id, Tên Việt="${c.viTitle}", Tên Trung="${c.item.title}")';
            }
            return 'seriesId=$id';
          })
          .join('; ');
      notes.add('PHIM ĐANG ĐƯỢC USER CHỌN/GHIM TRÊN THẺ: $pinnedDesc');
    }
    if (notes.isEmpty) return '';
    return '[NGỮ CẢNH UI: ${notes.join(" | ")}]';
  }

  /// Nhận diện câu hỏi tìm kiếm / gợi ý / BXH phim để nhắc model gọi tool hoặc tự khôi phục thẻ ảnh bìa nếu model quên gọi tool.
  static bool looksLikeMovieDiscoveryQuery(String rawInput) {
    final q = rawInput.trim().toLowerCase();
    if (q.isEmpty) return false;

    final hasDiscoveryVerb = RegExp(
      r'(tìm|kiếm|gợi ý|đề xuất|muốn xem|cho\s+(?:mình|tôi|em)|bxh|bảng xếp hạng|xếp hạng|top\s*\d*)',
    ).hasMatch(q);

    final asksExistingSelection = RegExp(
      r'(?:#\d+|phim\s*(?:số|thứ)\s*\d+|phim\s*(?:này|đó|trên)|tổng hợp.*cốt truyện|trong danh sách|vừa tìm|vừa rồi|ở trên)',
    ).hasMatch(q);
    if (asksExistingSelection && !hasDiscoveryVerb) return false;
    if (hasDiscoveryVerb) return true;

    const genreOrCatalogHints = [
      'phim',
      'hot',
      'nổi bật',
      'phổ biến',
      'mới nhất',
      'xem nhiều',
      'người thật',
      'hoạt hình',
      'phim ai',
      'ngôn tình',
      'ngọt sủng',
      'học đường',
      'thanh xuân',
      'tổng tài',
      'hào môn',
      'cổ trang',
      'xuyên không',
      'huyền huyễn',
      'tu tiên',
      'nữ cường',
      'trả thù',
      'nghịch tập',
      'đô thị',
      'kinh dị',
      'trinh thám',
      'hài',
      'gia đình',
    ];
    return genreOrCatalogHints.any(q.contains);
  }

  /// Đóng gói prompt gửi cho Gemini kèm ngữ cảnh Phim đang ghim và Ràng buộc từ UI.
  String decorateUserInput(String rawInput) {
    final clean = rawInput.trim();
    final header = buildUiContextHeader();
    final parts = <String>[
      if (header.isNotEmpty) header,
      if (looksLikeMovieDiscoveryQuery(clean))
        '[LỆNH HỆ THỐNG: Bắt buộc gọi tool (`progressive_search`, `browse_by_category` hoặc `get_rankings`) để app tải ảnh bìa và thẻ phim thật trước khi trả lời.]',
      clean,
    ];
    return parts.join('\n');
  }

  /// Phương án an toàn: nếu model Live trả lời text/thoại mà quên gọi tool ở câu hỏi tìm phim,
  /// tự phân tích từ khóa Tiếng Việt -> Trung / BXH để tải thẻ ảnh bìa thật từ Hồng Quả.
  Future<HongguoSearchReport?> autoSearchFallbackFromPrompt(
    String rawPrompt, {
    void Function(String statusText)? onProgress,
    void Function(HongguoSearchReport report)? onSearchResultsUpdated,
  }) async {
    final clean = rawPrompt.trim();
    if (!looksLikeMovieDiscoveryQuery(clean)) return null;
    final lower = clean.toLowerCase();

    // 1. Trích số lượng nếu user ghi rõ ("3 phim", "top 8")
    int? parsedLimit;
    final countMatch = RegExp(
      r'(?:top\s*|gợi ý\s*|tìm\s*|chọn\s*)?(\d{1,2})\s*(?:phim|bộ|truyện)\b',
    ).firstMatch(lower);
    if (countMatch != null) {
      final n = int.tryParse(countMatch.group(1) ?? '');
      if (n != null && n >= 1 && n <= 15) parsedLimit = n;
    }
    final topMatch = RegExp(r'\btop\s*(\d{1,2})\b').firstMatch(lower);
    if (parsedLimit == null && topMatch != null) {
      final n = int.tryParse(topMatch.group(1) ?? '');
      if (n != null && n >= 1 && n <= 15) parsedLimit = n;
    }
    final limit = _resolveEffectiveLimit(parsedLimit);

    // 2. Xác định nguồn ưu tiên
    var sourceType = _currentLocks.sourceCategory.replaceFirst('category/', '');
    if (lower.contains('hoạt hình') || lower.contains('anime')) {
      sourceType = 'comic-drama';
    } else if (lower.contains('phim ai') ||
        lower.contains('nguồn ai') ||
        lower.contains('do ai') ||
        lower.contains('bằng ai') ||
        lower.contains('ai-drama')) {
      sourceType = 'ai-drama';
    } else if (lower.contains('người thật')) {
      sourceType = 'real-drama';
    }

    // 3. Nếu hỏi BXH / Hot / Mới / Phổ biến -> gọi get_rankings
    final asksRanking = RegExp(
      r'(bxh|bảng xếp hạng|xếp hạng|phổ biến|nổi bật|đang hot|\bhot\b|xem nhiều|mới nhất|mới ra|điểm cao|đánh giá|tìm nhiều|\btop\b)',
    ).hasMatch(lower);
    if (asksRanking) {
      var board = 'hot-drama';
      if (lower.contains('mới')) {
        board = 'new-drama';
      } else if (lower.contains('điểm cao') || lower.contains('đánh giá')) {
        board = 'prestige-drama';
      } else if (lower.contains('tìm nhiều') || lower.contains('tìm kiếm')) {
        board = 'hot-search-drama';
      } else if (lower.contains('theo dõi') || lower.contains('lưu')) {
        board = 'followed-drama';
      } else if (sourceType == 'comic-drama') {
        board = 'hot-comic-drama';
      } else if (sourceType == 'ai-drama') {
        board = 'hot-ai-drama';
      } else if (sourceType == 'real-drama') {
        board = 'hot-real-drama';
      }
      await _handleGetRankings(
        {'board': board, 'limit': limit},
        onProgress: onProgress,
        onSearchResultsUpdated: onSearchResultsUpdated,
      );
      return _lastSearchReport;
    }

    // 4. Ánh xạ mô tả Tiếng Việt -> từ khóa Tiếng Trung + slug chuẩn
    const viPhraseToZh = <(String, String, String?)>[
      ('học đường', '校园', 'youth'),
      ('thanh xuân', '青春', 'youth'),
      ('ngọt sủng', '甜宠', 'romance'),
      ('ngôn tình', '甜宠', 'romance'),
      ('tình cảm', '爱情', 'romance'),
      ('lãng mạn', '浪漫', 'romance'),
      ('nữ cường', '女强', null),
      ('mạnh mẽ', '女强', null),
      ('tổng tài', '总裁', 'clan'),
      ('hào môn', '豪门', 'clan'),
      ('cổ trang', '古装', 'costume'),
      ('xuyên không', '穿越', 'fantasy'),
      ('trọng sinh', '重生', 'comeback'),
      ('trùng sinh', '重生', 'comeback'),
      ('trả thù', '复仇', 'comeback'),
      ('báo thù', '复仇', 'comeback'),
      ('nghịch tập', '逆袭', 'comeback'),
      ('hệ thống', '系统', 'creative'),
      ('huyền huyễn', '玄幻', 'fantasy'),
      ('tu tiên', '修仙', 'fantasy'),
      ('đô thị', '都市', 'urban'),
      ('gia đình', '家庭', 'family'),
      ('manh bảo', '萌宝', 'cute-kids'),
      ('kinh dị', '恐怖', 'horror'),
      ('trinh thám', '悬疑', 'suspense'),
      ('hài hước', '喜剧', 'comedy'),
      ('hài', '喜剧', 'comedy'),
      ('mạt thế', '末世', 'apocalypse'),
      ('khoa huyễn', '科幻', 'sci-fi'),
    ];

    final zhKeywords = <String>[];
    String matchedSlug = '';
    for (final (vi, zh, slug) in viPhraseToZh) {
      if (lower.contains(vi)) {
        if (!zhKeywords.contains(zh)) zhKeywords.add(zh);
        if (matchedSlug.isEmpty && slug != null) matchedSlug = slug;
      }
    }
    // Bắt thêm chữ Hán nếu user nhập trực tiếp tiếng Trung
    for (final m in RegExp(r'[\u4e00-\u9fff]{2,}').allMatches(clean)) {
      final token = m.group(0)!;
      if (!zhKeywords.contains(token)) zhKeywords.add(token);
    }

    if (zhKeywords.isEmpty && matchedSlug.isEmpty) {
      await _handleGetRankings(
        {'board': 'hot-drama', 'limit': limit},
        onProgress: onProgress,
        onSearchResultsUpdated: onSearchResultsUpdated,
      );
      return _lastSearchReport;
    }

    final narrowToBroad = <String>[];
    if (zhKeywords.length >= 2) {
      narrowToBroad.add('${zhKeywords[0]} ${zhKeywords[1]}');
    }
    for (final kw in zhKeywords) {
      if (!narrowToBroad.contains(kw)) narrowToBroad.add(kw);
    }

    await _handleProgressiveSearch(
      {
        if (sourceType.isNotEmpty) 'source_type': sourceType,
        if (matchedSlug.isNotEmpty) 'genre_slug': matchedSlug,
        'queries_narrow_to_broad': narrowToBroad,
        'target_zh_keywords': zhKeywords,
        'limit': limit,
      },
      onProgress: onProgress,
      onSearchResultsUpdated: onSearchResultsUpdated,
    );
    return _lastSearchReport;
  }

  /// Tạo gói `clientContent` nén (~400-800 token) để giữ nguyên trí nhớ khi chuyển Model hoặc mở phiên mới.
  List<Map<String, dynamic>> buildCompressedSnapshotTurns(
    List<({bool isUser, String text})> recentDialogue,
  ) {
    final turns = <Map<String, dynamic>>[];

    final ctxLines = <String>[];
    ctxLines.add(
      'Ngữ cảnh đang giữ từ phiên trước (hãy dùng tiếp thông tin này, không cần chào lại từ đầu):',
    );
    if (_currentLocks.sourceCategory.isNotEmpty) {
      ctxLines.add('- Nguồn khóa: ${_currentLocks.sourceCategory}');
    }
    if (_currentLocks.lockedCount != null) {
      ctxLines.add('- Số lượng mặc định: ${_currentLocks.lockedCount} phim');
    }
    if (_lastDisplayed.isNotEmpty) {
      ctxLines.add('- Danh sách phim đang hiển thị cho người dùng:');
      for (final c in _lastDisplayed) {
        ctxLines.add(
          '  #${c.displayIndex} | id=${c.seriesId} | "${c.viTitle}" (${c.item.title}) | ${c.sourceBadge}',
        );
      }
    }
    if (_currentLocks.pinnedSeriesIds.isNotEmpty) {
      ctxLines.add(
        '- Phim đang ghim: ${_currentLocks.pinnedSeriesIds.join(", ")}',
      );
    }

    turns.add({
      'role': 'user',
      'parts': [
        {'text': ctxLines.join('\n')},
      ],
    });
    turns.add({
      'role': 'model',
      'parts': [
        {
          'text':
              'Đã nắm rõ ngữ cảnh và danh sách phim hiện tại, sẵn sàng hỗ trợ tiếp.',
        },
      ],
    });

    final recent = recentDialogue.length > 6
        ? recentDialogue.sublist(recentDialogue.length - 6)
        : recentDialogue;
    for (final msg in recent) {
      final clean = msg.text.trim();
      if (clean.isEmpty) continue;
      turns.add({
        'role': msg.isUser ? 'user' : 'model',
        'parts': [
          {'text': clean},
        ],
      });
    }

    return turns;
  }
}
