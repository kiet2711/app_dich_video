import 'dart:async';
import 'dart:math' as math;

import '../../ai/live/gemini_live_client.dart';
import '../../ai/live/live_reply_title_sync.dart';
import '../bilibili_resolver.dart';
import 'bilibili_srt_service.dart';
import 'bilibili_taste_service.dart';

typedef BilibiliTitleTranslator = Future<String> Function(String zhTitle);

enum BilibiliCandidateKind {
  video,
  upChannel,
  pgc,
}

class BilibiliAssistantCandidate {
  final int displayIndex;
  final BilibiliCandidateKind kind;
  final BilibiliAnimeItem item;
  final String viTitle;
  final String matchReason;
  final String sourceBadge;
  final BilibiliUserSearchResult? userResult;
  final BilibiliPgcSearchResult? pgcResult;
  final double score;
  final int matchedTier;
  final bool hasSrtInMemory;
  final int srtChunkCount;
  final String srtSourceLabel;

  const BilibiliAssistantCandidate({
    required this.displayIndex,
    required this.kind,
    required this.item,
    required this.viTitle,
    required this.matchReason,
    required this.sourceBadge,
    this.userResult,
    this.pgcResult,
    required this.score,
    this.matchedTier = 0,
    this.hasSrtInMemory = false,
    this.srtChunkCount = 0,
    this.srtSourceLabel = '',
  });

  String get candidateKey {
    if (kind == BilibiliCandidateKind.upChannel && userResult != null) {
      return 'up_${userResult!.mid}';
    }
    if (kind == BilibiliCandidateKind.pgc && pgcResult != null) {
      return 'pgc_${pgcResult!.seasonId}';
    }
    final bvid = item.bvid?.trim() ?? '';
    if (bvid.isNotEmpty) return bvid;
    if (item.seasonId != null && item.seasonId! > 0) {
      return 'ss_${item.seasonId}';
    }
    if (item.epId != null && item.epId! > 0) {
      return 'ep_${item.epId}';
    }
    return 'bili_${item.title.hashCode}';
  }

  String get bvid => (item.bvid ?? '').trim();

  BilibiliAssistantCandidate copyWith({
    int? displayIndex,
    BilibiliCandidateKind? kind,
    BilibiliAnimeItem? item,
    String? viTitle,
    String? matchReason,
    String? sourceBadge,
    BilibiliUserSearchResult? userResult,
    BilibiliPgcSearchResult? pgcResult,
    double? score,
    int? matchedTier,
    bool? hasSrtInMemory,
    int? srtChunkCount,
    String? srtSourceLabel,
  }) {
    return BilibiliAssistantCandidate(
      displayIndex: displayIndex ?? this.displayIndex,
      kind: kind ?? this.kind,
      item: item ?? this.item,
      viTitle: viTitle ?? this.viTitle,
      matchReason: matchReason ?? this.matchReason,
      sourceBadge: sourceBadge ?? this.sourceBadge,
      userResult: userResult ?? this.userResult,
      pgcResult: pgcResult ?? this.pgcResult,
      score: score ?? this.score,
      matchedTier: matchedTier ?? this.matchedTier,
      hasSrtInMemory: hasSrtInMemory ?? this.hasSrtInMemory,
      srtChunkCount: srtChunkCount ?? this.srtChunkCount,
      srtSourceLabel: srtSourceLabel ?? this.srtSourceLabel,
    );
  }
}

class BilibiliSearchReport {
  final String traceSummary;
  final List<String> executedQueries;
  final String modeLabel;
  final int totalPoolCount;
  final List<BilibiliAssistantCandidate> candidates;

  const BilibiliSearchReport({
    required this.traceSummary,
    required this.executedQueries,
    required this.modeLabel,
    required this.totalPoolCount,
    required this.candidates,
  });

  BilibiliSearchReport copyWith({
    String? traceSummary,
    List<String>? executedQueries,
    String? modeLabel,
    int? totalPoolCount,
    List<BilibiliAssistantCandidate>? candidates,
  }) {
    return BilibiliSearchReport(
      traceSummary: traceSummary ?? this.traceSummary,
      executedQueries: executedQueries ?? this.executedQueries,
      modeLabel: modeLabel ?? this.modeLabel,
      totalPoolCount: totalPoolCount ?? this.totalPoolCount,
      candidates: candidates ?? this.candidates,
    );
  }
}

class BilibiliUiLocks {
  /// 0 = Tất cả phân khu, hoặc tid trong BilibiliPartition.catalog
  final int partitionTid;

  /// `true` = Chế độ lọc chuyên biệt Phim Hoạt Hình AI (chỉ giữ hoạt hình/AI漫剧 xem trực tiếp,
  /// loại bỏ video kiến thức/dạy làm AI, người thật và tiểu thuyết audio).
  final bool aiAnimeOnly;

  /// 0 = Tất cả, 1 = <10p, 2 = 10-30p, 3 = 30-60p, 4 = >60p
  final int durationBucket;

  /// 'any' | '24h' | '7d' | '30d' | '90d' | '1y'
  final String recencyBucket;

  /// 'totalrank' | 'click' | 'pubdate' | 'stow' | 'dm'
  final String sortOrder;

  final int? lockedCount;
  final List<String> pinnedKeys;

  const BilibiliUiLocks({
    this.partitionTid = 0,
    this.aiAnimeOnly = false,
    this.durationBucket = 0,
    this.recencyBucket = 'any',
    this.sortOrder = 'totalrank',
    this.lockedCount,
    this.pinnedKeys = const [],
  });
}

class _RawBiliAccumulator {
  BilibiliAnimeItem item;
  int bestTier = 99;
  int bestPos = 999;
  final Set<String> hitQueries = {};
  final Set<String> matchedConcepts = {};

  _RawBiliAccumulator(this.item);
}

/// Bộ điều phối Tool Calling, Tìm kiếm đa phân khu (Tìm đúng `exact` vs Đề xuất `discover`),
/// Cá nhân hóa gu xem, Kênh UP / PGC, Comment Hot và Đọc/Băm SRT từng đoạn cho Trợ lý Bilibili.
class BilibiliAssistantEngine {
  final BilibiliResolver resolver;
  final BilibiliSrtService srtService;
  final BilibiliTasteService tasteService;
  final BilibiliTitleTranslator? translateTitle;
  String Function()? cookieProvider;

  final List<BilibiliAssistantCandidate> _lastDisplayed = [];
  final Map<String, BilibiliAssistantCandidate> _candidateCache = {};
  final Map<String, String> _aiViTitleCache = {};
  BilibiliSearchReport? _lastSearchReport;
  BilibiliUiLocks _currentLocks = const BilibiliUiLocks();
  String? _activeSrtBvid;
  int _activeSrtPage = 1;

  BilibiliAssistantEngine({
    BilibiliResolver? resolver,
    BilibiliSrtService? srtService,
    BilibiliTasteService? tasteService,
    this.translateTitle,
    this.cookieProvider,
  }) : resolver = resolver ?? BilibiliResolver(),
       srtService = srtService ??
           BilibiliSrtService(resolver: resolver ?? BilibiliResolver()),
       tasteService = tasteService ??
           BilibiliTasteService(resolver: resolver ?? BilibiliResolver());

  List<BilibiliAssistantCandidate> get lastDisplayedCandidates =>
      List.unmodifiable(_lastDisplayed);
  BilibiliSearchReport? get lastSearchReport => _lastSearchReport;
  BilibiliUiLocks get currentLocks => _currentLocks;
  String? get activeSrtBvid => _activeSrtBvid;
  int get activeSrtPage => _activeSrtPage;

  Future<BilibiliTasteProfile> warmTasteProfile({
    bool forceRefresh = false,
    bool includeRecommendSample = true,
  }) {
    return tasteService.getTasteProfile(
      cookie: _cookie,
      forceRefresh: forceRefresh,
      includeRecommendSample: includeRecommendSample,
    );
  }

  BilibiliSrtSession? get activeSrtSession {
    final bvid = _activeSrtBvid;
    if (bvid == null || bvid.isEmpty) return null;
    return srtService.getCachedSession(bvid, pageIndex: _activeSrtPage);
  }

  String get _cookie => (cookieProvider?.call() ?? '').trim();

  void updateUiLocks(BilibiliUiLocks locks) {
    _currentLocks = locks;
  }

  BilibiliAssistantCandidate? getByKey(String key) =>
      _candidateCache[key.trim()];

  BilibiliAssistantCandidate? getByDisplayIndex(int index) {
    for (final c in _lastDisplayed) {
      if (c.displayIndex == index) return c;
    }
    return null;
  }

  static String durationLabel(int bucket) {
    return switch (bucket) {
      1 => 'Dưới 10 phút',
      2 => '10–30 phút',
      3 => '30–60 phút',
      4 => 'Trên 60 phút',
      _ => 'Mọi độ dài',
    };
  }

  static String recencyLabel(String bucket) {
    return switch (bucket.trim().toLowerCase()) {
      '24h' => '24 giờ qua',
      '7d' => '7 ngày qua',
      '30d' => '30 ngày qua',
      '90d' => '90 ngày qua',
      '1y' => '1 năm qua',
      _ => 'Mọi lúc',
    };
  }

  static int recencyDaysFromBucket(String bucket) {
    return switch (bucket.trim().toLowerCase()) {
      '24h' => 1,
      '7d' => 7,
      '30d' => 30,
      '90d' => 90,
      '1y' => 365,
      _ => 0,
    };
  }

  static String sortLabel(String order) {
    return switch (order) {
      'click' => 'Xem nhiều',
      'pubdate' => 'Mới nhất',
      'stow' => 'Lưu nhiều nhất',
      'dm' => 'Thảo luận nhiều',
      _ => 'Liên quan nhất',
    };
  }

  static String buildSystemPrompt({
    bool compactVoiceStyle = false,
    int defaultCount = 5,
  }) {
    final partitionsText = BilibiliPartition.catalog
        .map((p) => '${p.tid}=${p.viLabel}(${p.zhName})')
        .join(', ');

    return '''Bạn là **Trợ lý AI Bilibili Toàn Năng** (tìm kiếm thông tin, video kiến thức, công nghệ, hướng dẫn, game, đời sống, âm nhạc, phim AI, hoạt hình, tài liệu, kênh UP) nói Tiếng Việt tự nhiên.

NGUYÊN TẮC BẮT BUỘC:
1. KHÔNG BAO GIỜ tự bịa tên video, BVID, tên kênh UP hay số liệu ngoài dữ liệu tool trả về. ỨNG DỤNG CHỈ HIỂN THỊ ĐƯỢC THẺ VIDEO / KÊNH KHI BẠN GỌI TOOL. Với mọi yêu cầu tìm kiếm, hỏi BXH, hỏi thông tin hay tóm tắt video, PHẢI gọi tool trước rồi mới trả lời.
2. PHÂN BIỆT RÕ "TÌM ĐÚNG PHIM / TÊN GỐC" VS "ĐỀ XUẤT HỢP GU":
   - **TÌM KIẾM ĐÚNG TÊN (`search_mode: "exact"`)**: Khi người dùng đã biết tên tiếng Việt/Anh/Trung (vd: *"tìm bản gốc tiếng Trung của phim..."*, *"tìm video hướng dẫn cài X"*, *"tìm kênh/tác phẩm cụ thể"*), dịch sát tên đó sang 1–3 biến thể từ khóa tiếng Trung chuẩn trong `queries_narrow_to_broad` và đặt `search_mode: "exact"` để trả đúng **các kết quả đầu trang tìm kiếm Bilibili** theo đúng thứ tự khớp, KHÔNG tự ý lan rộng sang các video không liên quan! Nếu là Anime/Điện ảnh/Tài liệu chính thống có thể kèm `search_bilibili_pgc`.
   - **ĐỀ XUẤT / KHÁM PHÁ HỢP GU (`search_mode: "discover"`)**: Khi người dùng xin gợi ý theo gu/thể loại (*"đề xuất vài bộ hay"*, *"tìm theo gu hay xem của mình"*), hãy gọi `get_user_taste_profile` (và `explore_bilibili_discovery(mode: "recommend")` nếu cần feed cá nhân hóa Bilibili) để nắm lịch sử/thể loại hay xem, rồi tìm Hẹp -> Rộng với `search_mode: "discover"`.
   - **QUY TẮC TÌM ĐÚNG "PHIM HOẠT HÌNH AI" (RẤT QUAN TRỌNG):** Từ khóa `"AI漫剧"` đứng một mình trên Bilibili bị lẫn rất nhiều **video kiến thức/dạy làm AI (`教程`, `ComfyUI`, `即梦`, `变现`)**, **phim người thật (`真人短剧`, `真人AI`)** và **tiểu thuyết audio (`有声小说`, `听书`, `广播剧`, `小说推文`)**. Vì vậy khi người dùng muốn **XEM** phim hoạt hình AI / AI漫剧 / anime AI (không phải hỏi cách làm):
     * BẮT BUỘC đặt `content_focus: "ai_anime"`!
     * Trong `queries_narrow_to_broad`, ưu tiên cụm tìm phim hoạt hình thực sự như `"AI动画 <chủ đề>"`, `"AI漫剧 一口气看完 <chủ đề>"`, `"AI漫剧 合集"`, `"AI动漫 <chủ đề>"`, `"动态漫 <chủ đề>"` (tránh chỉ truyền mỗi 1 từ `"AI漫剧"`).
     * Đặt `exclude_keywords: ["教程", "教学", "ComfyUI", "即梦", "变现", "有声小说", "听书", "广播剧", "真人"]` và dùng `partition_tid: 0` (hoặc `1`=Hoạt hình / `167`=Quốc sáng — không dùng `36`=Kiến thức hay `188`=Công nghệ).
   - `partition_tid`: chọn đúng mã phân khu: $partitionsText (để `0` nếu tổng hợp nhiều mảng).
3. LỌC THỜI LƯỢNG & NGÀY ĐĂNG MỚI:
   - Khi người dùng yêu cầu độ dài (vd: *"dài trên 1 tiếng"*, *"từ 20 đến 40 phút"*), PHẢI truyền `min_duration_minutes` / `max_duration_minutes` và `duration_bucket` (`0`=mọi độ dài, `1`=<10p, `2`=10-30p, `3`=30-60p, `4`=>60p). Nếu tool trả về `durationFilterSatisfied=false`, phải nói thật không có video đủ độ dài yêu cầu chứ không được mạo nhận video ngắn.
   - Khi người dùng cần thông tin/video mới đăng, truyền `recency` (`"24h"`, `"7d"`, `"30d"`, `"90d"`, `"1y"`) hoặc `max_age_days`, và đặt `order: "pubdate"` (hoặc `"click"`/`"stow"` trong khoảng ngày đó).
4. TÌM THỰC THỂ & KHÁM PHÁ:
   - Hỏi BXH / hot hôm nay / xu hướng theo mảng / trang đề xuất tài khoản -> gọi `explore_bilibili_discovery` (`popular`, `ranking`, `recommend`, `hot_keywords`, `pgc_catalog`).
   - Hỏi tìm kênh creator / UP chủ -> gọi `search_bilibili_creators`; xem thêm video của kênh từ thẻ `#k` -> gọi `inspect_uploader_videos`.
   - Hỏi phim tài liệu / điện ảnh / anime chính thống dài tập -> gọi `search_bilibili_pgc` hoặc `explore_bilibili_discovery(mode: "pgc_catalog")`.
5. SỐ LƯỢNG (`limit`): Mặc định $defaultCount kết quả trừ khi người dùng nêu rõ số lượng hoặc UI đang khóa số lượng.
6. TÁCH RÕ 2 KIỂU TÓM TẮT (`summary_style`) & BĂM NHỎ SRT:
   - Khi người dùng muốn xem nội dung / tóm tắt video `#k` (hay `bvid`): GỌI NGAY `inspect_video_overview` kèm đúng `summary_style`:
     * **`summary_style: "story"` (Tóm tắt cốt truyện — Phim hoạt hình AI, Donghua, Anime, Phim ngắn, Kể chuyện)**: Kể lại diễn biến câu chuyện mượt mà, tự nhiên từ mở đầu → biến cố → cao trào → kết cục (dùng Hán Việt chuẩn cho tên nhân vật/môn phái). **TUYỆT ĐỐI KHÔNG chèn mốc thời gian `[mm:ss]` hay đánh số phút giây vào mạch truyện** (trừ khi người dùng hỏi riêng *"đoạn này ở phút bao nhiêu"*).
     * **`summary_style: "structured"` (Tóm tắt thông tin thường — Công nghệ, Kiến thức, Hướng dẫn, Review, Đời sống, Tin tức)**: Tóm tắt súc tích theo ý chính/luận điểm rõ ràng, **kèm mốc thời gian `[mm:ss]`** để tiện tua xem.
   - **QUY TẮC BĂM NHỎ SRT VIDEO DÀI:**
     * Nếu video có SRT chia nhiều đoạn (`totalChunks >= 3`), lần đầu app chỉ đưa `chunkMap` + **Đoạn 1**. Hãy tóm tắt kỹ phần đã nhận, nêu khái quát phần sau (với `story` không ghi `[mm:ss]`) và chỉ gọi `read_srt_chunk` / `search_srt_topic` khi cần đọc tiếp hoặc tìm chi tiết cụ thể.
   - **QUY TẮC PHƯƠNG ÁN A KHI THIẾU CC:** Nếu `inspect_video_overview` báo `hasSrt=false` (`sttAvailable=true`), TUYỆT ĐỐI KHÔNG tự chạy `extract_video_srt_stt` khi chưa được xác nhận; hãy tóm tắt trước từ **Mô tả + Pages + Top Comment Hot** (ghi rõ nguồn), và hỏi người dùng xem có muốn tạo phụ đề `.srt` từ âm thanh (CapCut STT) hay bấm nút **Tạo .srt** trên thẻ để nghe lời thoại chi tiết hơn không. CHỈ gọi `extract_video_srt_stt` khi người dùng đồng ý/yêu cầu!
7. QUY TẮC DỊCH TỪ MODEL LIVE (TUYỆT ĐỐI CẤM PINYIN):
   - Tool trả dữ liệu gốc tiếng Trung. CHÍNH BẠN (Gemini Live) dịch toàn bộ Tiêu đề, tên kênh/nhân vật, mô tả, comment và nội dung SRT sang Tiếng Việt tự nhiên:
     * Phim cổ trang / tu tiên / anime / tên nhân vật Hoa ngữ -> dùng **Hán Việt** chuẩn.
     * Chủ đề công nghệ / đời sống / kiến thức / review kiểu YouTube -> dịch **thoát nghĩa Tiếng Việt dễ hiểu**, giữ tên sản phẩm/thuật ngữ quốc tế quen thuộc.
   - ${LiveReplyTitleSync.hanVietRulesPrompt}
8. ĐỊNH DẠNG ĐỒNG BỘ THẺ `#STT`:
   - Mỗi khi giới thiệu danh sách kết quả từ tool (`search_*`, `explore_*`, `inspect_uploader_videos`, `get_related_*`), BẮT BUỘC mở đầu từng mục đúng mẫu để app đồng bộ tiêu đề Việt lên thẻ ảnh bìa:
     `#1. <Tiêu đề Tiếng Việt ngắn gọn> — <Tóm tắt ngắn 1 câu / thông tin nổi bật>`
     `#2. <Tiêu đề Tiếng Việt ngắn gọn> — <...>`
   - ${compactVoiceStyle ? 'Đang bật đọc thoại: trình bày súc tích tự nhiên, giữ #STT và tên Tiếng Việt gọn rõ, tránh đọc nguyên mã BVID hay chữ Hán dài.' : 'Trình bày rõ ràng, đúng phong cách `story` (không mốc giờ) hoặc `structured` (có mốc giờ `[mm:ss]`).'}''';
  }

  static List<Map<String, dynamic>> buildFunctionDeclarations({
    bool includeNonBlockingBehavior = false,
  }) {
    final declarations = <Map<String, dynamic>>[
      {
        'name': 'get_user_taste_profile',
        'description':
            'Đọc hồ sơ gu xem & thể loại người dùng hay xem gần đây (từ lịch sử xem/dịch trong máy, Xem sau, và Lịch sử + Đề xuất cá nhân trên tài khoản Bilibili nếu đã đăng nhập) để đề xuất đúng gu hơn.',
        'parameters': {
          'type': 'OBJECT',
          'properties': {
            'force_refresh': {'type': 'BOOLEAN'},
            'include_recommend_sample': {'type': 'BOOLEAN'},
          },
        },
      },
      {
        'name': 'search_bilibili_videos',
        'description':
            'Tìm kiếm video Bilibili. Hỗ trợ search_mode="exact" (tìm đúng tên phim/chủ đề, giữ thứ tự top kết quả tìm kiếm đầu tiên) hoặc "discover" (đề xuất mở rộng Hẹp->Rộng hợp gu), cùng lọc phân khu, thời lượng phút (min/max) và ngày đăng mới.',
        'parameters': {
          'type': 'OBJECT',
          'properties': {
            'queries_narrow_to_broad': {
              'type': 'ARRAY',
              'items': {'type': 'STRING'},
              'description':
                  'Với exact: 1-3 tên gốc tiếng Trung chính xác của phim/chủ đề (cụm chuẩn nhất đứng đầu). Với discover: 2-4 cụm từ khóa tiếng Trung từ HẸP đến RỘNG.',
            },
            'search_mode': {
              'type': 'STRING',
              'enum': ['exact', 'discover'],
              'description':
                  'exact: tìm đúng tên video/phim/chủ đề và ưu tiên thứ tự top đầu Bilibili. discover: gợi ý & khám phá mở rộng hợp gu.',
            },
            'content_focus': {
              'type': 'STRING',
              'enum': ['any', 'ai_anime', 'animation'],
              'description':
                  'Dùng "ai_anime" khi user muốn XEM phim hoạt hình AI / AI漫剧 / AI动画 để tự động quét phân khu Hoạt hình(1)+Quốc sáng(167) và lọc bỏ video kiến thức/dạy làm AI, người thật & tiểu thuyết audio. Dùng "any" cho các chủ đề chung.',
            },
            'exclude_keywords': {
              'type': 'ARRAY',
              'items': {'type': 'STRING'},
              'description':
                  'Danh sách từ khóa cần loại trừ khỏi tiêu đề/tag/mô tả kết quả (vd: ["教程", "ComfyUI", "有声小说", "真人"]).',
            },
            'target_keywords': {
              'type': 'ARRAY',
              'items': {'type': 'STRING'},
              'description':
                  'Các từ khóa cốt lõi để đối chiếu và chấm điểm mức độ khớp.',
            },
            'partition_tid': {
              'type': 'INTEGER',
              'description':
                  'Mã phân khu: 0=Tất cả, 36=Kiến thức, 188=Công nghệ, 4=Game, 160=Đời sống, 3=Âm nhạc, 181=Phim ảnh, 1=Hoạt hình, 167=Quốc sáng, 13=Anime, 177=Tài liệu, 23=Điện ảnh, 211=Ẩm thực, 217=Động vật, 234=Thể thao, 202=Tin tức.',
            },
            'duration_bucket': {
              'type': 'INTEGER',
              'description':
                  '0=Mọi độ dài, 1=<10 phút, 2=10-30 phút, 3=30-60 phút, 4=>60 phút.',
            },
            'min_duration_minutes': {
              'type': 'INTEGER',
              'description':
                  'Lọc cứng thời lượng tối thiểu theo phút (vd: 60 nếu user yêu cầu dài trên 1 tiếng).',
            },
            'max_duration_minutes': {
              'type': 'INTEGER',
              'description':
                  'Lọc cứng thời lượng tối đa theo phút (vd: 15 nếu user cần video ngắn).',
            },
            'recency': {
              'type': 'STRING',
              'enum': ['any', '24h', '7d', '30d', '90d', '1y'],
              'description':
                  'Lọc theo ngày đăng gần đây: any, 24h (hôm nay), 7d (tuần qua), 30d (tháng qua), 90d (3 tháng), 1y (1 năm).',
            },
            'max_age_days': {
              'type': 'INTEGER',
              'description':
                  'Số ngày tối đa kể từ lúc đăng nếu cần lọc theo số ngày cụ thể (vd: 14).',
            },
            'order': {
              'type': 'STRING',
              'enum': ['totalrank', 'click', 'pubdate', 'stow', 'dm'],
              'description':
                  'Cách xếp: totalrank (liên quan), click (xem nhiều), pubdate (mới nhất), stow (nhiều người lưu), dm (nhiều bình luận).',
            },
            'limit': {
              'type': 'INTEGER',
              'description': 'Số video cần lấy (1-15).',
            },
          },
          'required': ['queries_narrow_to_broad'],
        },
      },
      {
        'name': 'explore_bilibili_discovery',
        'description':
            'Khám phá video thịnh hành, BXH toàn trang hoặc theo phân khu, bảng đề xuất cá nhân, từ khóa hot hoặc kho Phim tài liệu / Anime / Điện ảnh.',
        'parameters': {
          'type': 'OBJECT',
          'properties': {
            'mode': {
              'type': 'STRING',
              'enum': [
                'popular',
                'ranking',
                'recommend',
                'hot_keywords',
                'pgc_catalog',
              ],
            },
            'partition_tid': {
              'type': 'INTEGER',
              'description': 'Mã phân khu cho chế độ ranking (0=Toàn trang, 36=Kiến thức, 188=Công nghệ, 4=Game, 160=Đời sống, 3=Âm nhạc, 181=Phim ảnh, 1=Hoạt hình, 167=Quốc sáng...).',
            },
            'pgc_type': {
              'type': 'STRING',
              'enum': [
                'anime',
                'guochuang',
                'documentary',
                'movie',
                'tv',
                'variety',
              ],
              'description': 'Loại kho khi mode=pgc_catalog.',
            },
            'limit': {'type': 'INTEGER'},
          },
          'required': ['mode'],
        },
      },
      {
        'name': 'search_bilibili_creators',
        'description':
            'Tìm kiếm kênh UP chủ / Creator theo tên hoặc chuyên môn và tự động lấy vài video mới nhất của kênh nổi bật nhất.',
        'parameters': {
          'type': 'OBJECT',
          'properties': {
            'keyword': {
              'type': 'STRING',
              'description': 'Tên kênh hoặc chủ đề của creator.',
            },
            'fetch_top_uploader_videos': {'type': 'BOOLEAN'},
            'limit': {'type': 'INTEGER'},
          },
          'required': ['keyword'],
        },
      },
      {
        'name': 'inspect_uploader_videos',
        'description':
            'Xem danh sách video của một UP chủ cụ thể (qua số thứ tự thẻ #k, mid hoặc tên kênh).',
        'parameters': {
          'type': 'OBJECT',
          'properties': {
            'index': {'type': 'INTEGER'},
            'mid': {'type': 'INTEGER'},
            'author_name': {'type': 'STRING'},
            'order': {
              'type': 'STRING',
              'enum': ['pubdate', 'click'],
            },
            'limit': {'type': 'INTEGER'},
          },
        },
      },
      {
        'name': 'search_bilibili_pgc',
        'description':
            'Tìm phim tài liệu, điện ảnh, TV series hoặc Anime/Guochuang chính thống có seasonId.',
        'parameters': {
          'type': 'OBJECT',
          'properties': {
            'keyword': {'type': 'STRING'},
            'pgc_category': {
              'type': 'STRING',
              'enum': ['all', 'ft', 'bangumi'],
            },
            'limit': {'type': 'INTEGER'},
          },
          'required': ['keyword'],
        },
      },
      {
        'name': 'inspect_video_overview',
        'description':
            'Đọc sâu thông tin 1 video (#k hoặc bvid): mô tả chi tiết, danh sách tập/chương (pages), hợp tập (ugcSeason), Top Comment Hot và tự động nạp nhanh SRT (từ Lịch sử hoặc CC Bilibili nếu có). Chọn summary_style="story" cho phim/hoạt hình (không đánh mốc giờ) hoặc "structured" cho video thường.',
        'parameters': {
          'type': 'OBJECT',
          'properties': {
            'index': {
              'type': 'INTEGER',
              'description': 'Số thứ tự #1..#N trên danh sách thẻ hiện tại.',
            },
            'bvid': {
              'type': 'STRING',
              'description': 'Mã BV của video nếu có.',
            },
            'page': {
              'type': 'INTEGER',
              'description': 'Số phần/tập (mặc định 1).',
            },
            'summary_style': {
              'type': 'STRING',
              'enum': ['structured', 'story'],
              'description':
                  'structured: tóm tắt theo ý chính kèm mốc [mm:ss]. story: kể cốt truyện phim/hoạt hình mượt mà, KHÔNG chèn mốc thời gian.',
            },
          },
        },
      },
      {
        'name': 'extract_video_srt_stt',
        'description':
            'Chỉ gọi khi người dùng xác nhận/yêu cầu rõ muốn chạy tạo phụ đề .srt bằng âm thanh (CapCut STT) do video thiếu phụ đề CC hoặc CC bị khóa.',
        'parameters': {
          'type': 'OBJECT',
          'properties': {
            'index': {'type': 'INTEGER'},
            'bvid': {'type': 'STRING'},
            'page': {'type': 'INTEGER'},
          },
        },
      },
      {
        'name': 'read_srt_chunk',
        'description':
            'Đọc tiếp một đoạn cụ thể (`chunk_number`, bắt đầu từ 1) trong bộ SRT đã băm nhỏ của video đang mở.',
        'parameters': {
          'type': 'OBJECT',
          'properties': {
            'chunk_number': {
              'type': 'INTEGER',
              'description': 'Số thứ tự đoạn SRT cần đọc (1, 2, 3...).',
            },
            'summary_style': {
              'type': 'STRING',
              'enum': ['structured', 'story'],
            },
            'index': {'type': 'INTEGER'},
            'bvid': {'type': 'STRING'},
            'page': {'type': 'INTEGER'},
          },
          'required': ['chunk_number'],
        },
      },
      {
        'name': 'search_srt_topic',
        'description':
            'Tìm nhanh từ khóa hoặc thông tin cụ thể bên trong toàn bộ SRT đã tải của video dài, trả về đoạn trích kèm mốc thời gian [mm:ss].',
        'parameters': {
          'type': 'OBJECT',
          'properties': {
            'keywords': {
              'type': 'ARRAY',
              'items': {'type': 'STRING'},
              'description':
                  'Danh sách 1-5 từ khóa tiếng Trung hoặc tiếng Anh cần dò trong phụ đề SRT.',
            },
            'index': {'type': 'INTEGER'},
            'bvid': {'type': 'STRING'},
            'page': {'type': 'INTEGER'},
          },
          'required': ['keywords'],
        },
      },
      {
        'name': 'get_related_bilibili_videos',
        'description':
            'Lấy danh sách video liên quan / gợi ý tiếp theo dựa trên 1 video (#k hoặc bvid).',
        'parameters': {
          'type': 'OBJECT',
          'properties': {
            'index': {'type': 'INTEGER'},
            'bvid': {'type': 'STRING'},
            'limit': {'type': 'INTEGER'},
          },
        },
      },
    ];

    if (includeNonBlockingBehavior) {
      for (final fn in declarations) {
        fn['behavior'] = 'NON_BLOCKING';
      }
    }
    return declarations;
  }

  /// Thực thi `LiveFunctionCall` và trả về `LiveFunctionResponse`.
  Future<LiveFunctionResponse> executeToolCall(
    LiveFunctionCall call, {
    void Function(String statusText)? onProgress,
    void Function(BilibiliSearchReport report)? onSearchResultsUpdated,
  }) async {
    try {
      Map<String, dynamic> payload;
      switch (call.name) {
        case 'get_user_taste_profile':
          payload = await _handleGetUserTasteProfile(
            call.args,
            onProgress: onProgress,
          );
        case 'search_bilibili_videos':
          payload = await _handleSearchVideos(
            call.args,
            onProgress: onProgress,
            onSearchResultsUpdated: onSearchResultsUpdated,
          );
        case 'explore_bilibili_discovery':
          payload = await _handleExploreDiscovery(
            call.args,
            onProgress: onProgress,
            onSearchResultsUpdated: onSearchResultsUpdated,
          );
        case 'search_bilibili_creators':
          payload = await _handleSearchCreators(
            call.args,
            onProgress: onProgress,
            onSearchResultsUpdated: onSearchResultsUpdated,
          );
        case 'inspect_uploader_videos':
          payload = await _handleInspectUploaderVideos(
            call.args,
            onProgress: onProgress,
            onSearchResultsUpdated: onSearchResultsUpdated,
          );
        case 'search_bilibili_pgc':
          payload = await _handleSearchPgc(
            call.args,
            onProgress: onProgress,
            onSearchResultsUpdated: onSearchResultsUpdated,
          );
        case 'inspect_video_overview':
          payload = await _handleInspectVideoOverview(
            call.args,
            onProgress: onProgress,
            onSearchResultsUpdated: onSearchResultsUpdated,
          );
        case 'extract_video_srt_stt':
          payload = await _handleExtractSrtStt(
            call.args,
            onProgress: onProgress,
            onSearchResultsUpdated: onSearchResultsUpdated,
          );
        case 'read_srt_chunk':
          payload = await _handleReadSrtChunk(
            call.args,
            onProgress: onProgress,
            onSearchResultsUpdated: onSearchResultsUpdated,
          );
        case 'search_srt_topic':
          payload = await _handleSearchSrtTopic(
            call.args,
            onProgress: onProgress,
            onSearchResultsUpdated: onSearchResultsUpdated,
          );
        case 'get_related_bilibili_videos':
          payload = await _handleRelatedVideos(
            call.args,
            onProgress: onProgress,
            onSearchResultsUpdated: onSearchResultsUpdated,
          );
        default:
          payload = {'ok': false, 'error': 'Tool không xác định: ${call.name}'};
      }
      return LiveFunctionResponse(
        id: call.id,
        name: call.name,
        response: payload,
      );
    } catch (e) {
      return LiveFunctionResponse(
        id: call.id,
        name: call.name,
        response: {
          'ok': false,
          'error': 'Lỗi khi gọi công cụ Bilibili (${call.name}): $e',
        },
      );
    }
  }

  static BilibiliTarget _targetForBvid(String bvid, {int page = 1}) {
    final safePage = page < 1 ? 1 : page;
    final url = safePage > 1
        ? 'https://www.bilibili.com/video/$bvid?p=$safePage'
        : 'https://www.bilibili.com/video/$bvid';
    return BilibiliTarget(bvid: bvid, pageIndex: safePage, rawUrl: url);
  }

  /// Public helper cho Controller khi user bấm nút chạy CapCut STT thủ công trên thẻ `#k`.
  Future<BilibiliSrtLoadResult> runCapCutSttForCandidate(
    BilibiliAssistantCandidate candidate, {
    int page = 1,
    void Function(double progress, String status)? onProgress,
    void Function(BilibiliSearchReport report)? onSearchResultsUpdated,
  }) async {
    final bvid = candidate.bvid;
    if (bvid.isEmpty) {
      return const BilibiliSrtLoadResult(
        session: null,
        sttAvailable: false,
        statusNote: 'Mục này không có mã video BVID để trích xuất SRT.',
      );
    }
    final target = _targetForBvid(bvid, page: page);
    final details = await resolver.getVideoDetails(target, _cookie);
    final result = await srtService.extractSrtWithCapCutStt(
      details,
      cookie: _cookie,
      onProgress: onProgress,
    );
    if (result.session != null) {
      _activeSrtBvid = details.bvid;
      _activeSrtPage = details.selectedPageIndex;
      _markCandidateSrtLoaded(
        details.bvid,
        result.session!,
        onSearchResultsUpdated: onSearchResultsUpdated,
      );
    }
    return result;
  }

  Future<Map<String, dynamic>> _handleGetUserTasteProfile(
    Map<String, dynamic> args, {
    void Function(String)? onProgress,
  }) async {
    onProgress?.call('Đang phân tích gu xem & lịch sử Bilibili của bạn...');
    final forceRefresh = args['force_refresh'] == true;
    final includeRcmd = args['include_recommend_sample'] != false;
    final profile = await tasteService.getTasteProfile(
      cookie: _cookie,
      forceRefresh: forceRefresh,
      includeRecommendSample: includeRcmd,
    );
    return profile.toJson(includeRecommendSample: includeRcmd);
  }

  int _resolveEffectiveLimit(dynamic rawLimit) {
    if (_currentLocks.lockedCount != null) {
      return _currentLocks.lockedCount!.clamp(1, 20);
    }
    final parsed = int.tryParse((rawLimit ?? '').toString());
    if (parsed != null && parsed >= 1) return parsed.clamp(1, 15);
    return 5;
  }

  int _resolveEffectiveTid(dynamic rawTid) {
    if (_currentLocks.partitionTid > 0) return _currentLocks.partitionTid;
    return BilibiliPartition.resolve(rawTid).tid;
  }

  ({int minSec, int maxSec, int apiBucket, String label})
  _resolveDurationConstraint(Map<String, dynamic> args) {
    var bucket = _currentLocks.durationBucket;
    if (bucket <= 0) {
      bucket = (int.tryParse((args['duration_bucket'] ?? '').toString()) ?? 0)
          .clamp(0, 4);
    }

    var minSec = switch (bucket) {
      1 => 1,
      2 => 10 * 60,
      3 => 30 * 60,
      4 => 60 * 60,
      _ => 0,
    };
    var maxSec = switch (bucket) {
      1 => 10 * 60,
      2 => 30 * 60,
      3 => 60 * 60,
      _ => 0,
    };

    final minMins = int.tryParse(
      (args['min_duration_minutes'] ?? '').toString(),
    );
    final maxMins = int.tryParse(
      (args['max_duration_minutes'] ?? '').toString(),
    );
    if (minMins != null && minMins > 0) {
      final explicitMin = minMins * 60;
      if (minSec == 0 || explicitMin > minSec) minSec = explicitMin;
    }
    if (maxMins != null && maxMins > 0) {
      final explicitMax = maxMins * 60;
      if (maxSec == 0 || explicitMax < maxSec) maxSec = explicitMax;
    }

    var apiBucket = bucket;
    if (apiBucket == 0) {
      if (minSec >= 3600) {
        apiBucket = 4;
      } else if (minSec >= 1800 && (maxSec == 0 || maxSec <= 3600)) {
        apiBucket = 3;
      } else if (minSec >= 600 && (maxSec == 0 || maxSec <= 1800)) {
        apiBucket = 2;
      } else if (maxSec > 0 && maxSec <= 600) {
        apiBucket = 1;
      }
    }

    final String label;
    if (bucket > 0 && minMins == null && maxMins == null) {
      label = durationLabel(bucket);
    } else if (minSec > 0 && maxSec > 0) {
      label = '${minSec ~/ 60}–${maxSec ~/ 60} phút';
    } else if (minSec > 0) {
      label = 'Từ ${minSec ~/ 60} phút+';
    } else if (maxSec > 0) {
      label = 'Dưới ${maxSec ~/ 60} phút';
    } else {
      label = 'Mọi độ dài';
    }

    return (minSec: minSec, maxSec: maxSec, apiBucket: apiBucket, label: label);
  }

  ({int minPubdateSec, int? beginSec, int? endSec, String label})
  _resolveRecencyConstraint(Map<String, dynamic> args) {
    final uiDays = recencyDaysFromBucket(_currentLocks.recencyBucket);
    final bucketArg = (args['recency'] ?? '').toString().trim().toLowerCase();
    final bucketDays = recencyDaysFromBucket(bucketArg);
    final explicitDays = int.tryParse((args['max_age_days'] ?? '').toString()) ?? 0;

    final argDays = (bucketDays > 0 && explicitDays > 0)
        ? math.min(bucketDays, explicitDays)
        : math.max(bucketDays, explicitDays);

    final int effectiveDays;
    if (uiDays > 0 && argDays > 0) {
      effectiveDays = math.min(uiDays, argDays);
    } else {
      effectiveDays = math.max(uiDays, argDays);
    }

    if (effectiveDays <= 0) {
      return (minPubdateSec: 0, beginSec: null, endSec: null, label: 'Mọi lúc');
    }

    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final beginSec = nowSec - effectiveDays * 86400;
    final label = (uiDays > 0 && argDays == 0)
        ? recencyLabel(_currentLocks.recencyBucket)
        : (bucketDays == effectiveDays && bucketArg.isNotEmpty)
        ? recencyLabel(bucketArg)
        : '$effectiveDays ngày qua';

    return (
      minPubdateSec: beginSec,
      beginSec: beginSec,
      endSec: nowSec,
      label: label,
    );
  }

  String _resolveEffectiveOrder(
    dynamic rawOrder, {
    bool hasRecencyConstraint = false,
  }) {
    if (_currentLocks.sortOrder != 'totalrank') return _currentLocks.sortOrder;
    const valid = {'totalrank', 'click', 'pubdate', 'stow', 'dm'};
    final o = (rawOrder ?? '').toString().trim().toLowerCase();
    if (valid.contains(o)) {
      if (hasRecencyConstraint && o == 'totalrank') return 'pubdate';
      return o;
    }
    return hasRecencyConstraint ? 'pubdate' : 'totalrank';
  }

  static bool _matchesDuration(
    BilibiliAnimeItem item,
    int minSec,
    int maxSec,
  ) {
    if (minSec <= 0 && maxSec <= 0) return true;
    final d = item.durationSeconds;
    if (d <= 0) return false;
    if (minSec > 0 && d < minSec - 5) return false;
    if (maxSec > 0 && d > maxSec + 5) return false;
    return true;
  }

  static bool _matchesRecency(
    BilibiliAnimeItem item,
    int minPubdateSec,
    bool hasAnyTimestampedItems,
  ) {
    if (minPubdateSec <= 0) return true;
    if (item.pubdate <= 0) return !hasAnyTimestampedItems;
    return item.pubdate >= minPubdateSec;
  }

  String _resolveEffectiveContentFocus(
    Map<String, dynamic> args, {
    required List<String> queries,
    required Set<String> targetKeywords,
    required int tid,
  }) {
    if (_currentLocks.aiAnimeOnly) return 'ai_anime';
    final raw = (args['content_focus'] ?? '').toString().trim().toLowerCase();
    if (raw == 'ai_anime' || raw == 'animation' || raw == 'any') return raw;

    // Tự nhận diện nếu AI quên truyền `content_focus` khi đang tìm phim hoạt hình AI / AI漫剧
    if (tid == 0 || tid == 1 || tid == 167 || tid == 13) {
      final combined = '${queries.join(" ")} ${targetKeywords.join(" ")}'.toLowerCase();
      final mentionsAiAnime = RegExp(
        r'(ai漫剧|ai动画|ai动漫|动态漫)',
        caseSensitive: false,
      ).hasMatch(combined);
      final asksTutorialOrAudioOrReal = RegExp(
        r'(教程|教学|全流程|保姆级|comfyui|提示词|变现|怎么制作|怎么做|有声小说|有声书|听书|广播剧|真人短剧)',
        caseSensitive: false,
      ).hasMatch(combined);
      if (mentionsAiAnime && !asksTutorialOrAudioOrReal) {
        return 'ai_anime';
      }
    }
    return 'any';
  }

  static List<String> _expandAiAnimeQueries(List<String> inputQueries) {
    final hasWatchFocusedQuery = inputQueries.any(
      (q) => RegExp(
        r'(ai动画|ai动漫|一口气看完|动画合集|动态漫)',
        caseSensitive: false,
      ).hasMatch(q),
    );
    if (hasWatchFocusedQuery) return inputQueries;

    final joined = inputQueries.first;
    final genre = joined
        .replaceAll(
          RegExp(
            r'(ai漫剧|ai动画|ai动漫|动态漫|一口气看完|合集|全集)',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final expanded = <String>[
      if (genre.isNotEmpty) 'AI动画 $genre' else 'AI动画',
      if (genre.isNotEmpty) 'AI漫剧 一口气看完 $genre' else 'AI漫剧 一口气看完',
      if (genre.isNotEmpty) 'AI动漫 $genre' else 'AI漫剧 合集',
      for (final q in inputQueries)
        if (q.trim().isNotEmpty) q.trim(),
    ];
    final dedup = <String>[];
    for (final q in expanded) {
      if (!dedup.contains(q)) dedup.add(q);
    }
    return dedup.take(4).toList();
  }

  static bool _matchesContentAndExclusions(
    BilibiliAnimeItem item, {
    required String contentFocus,
    required List<String> excludeKeywords,
  }) {
    if (excludeKeywords.isNotEmpty) {
      final hay = '${item.title} ${item.styles.join(" ")} ${item.badge} ${item.desc}'
          .toLowerCase();
      for (final ex in excludeKeywords) {
        if (ex.isNotEmpty && hay.contains(ex)) return false;
      }
    }
    if (contentFocus == 'ai_anime') {
      return BilibiliContentClassifier.isCleanWatchableAiAnime(item);
    }
    if (contentFocus == 'animation') {
      return !BilibiliContentClassifier.isTutorialOrCourse(item) &&
          !BilibiliContentClassifier.isAudioNovelOrPodcast(item) &&
          !BilibiliContentClassifier.isLiveAction(item);
    }
    return true;
  }

  Future<Map<String, dynamic>> _handleSearchVideos(
    Map<String, dynamic> args, {
    void Function(String)? onProgress,
    void Function(BilibiliSearchReport)? onSearchResultsUpdated,
  }) async {
    final rawQueries = (args['queries_narrow_to_broad'] as List?) ?? const [];
    final queries = rawQueries
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .take(5)
        .toList();
    if (queries.isEmpty) {
      final single = (args['keyword'] ?? '').toString().trim();
      if (single.isNotEmpty) queries.add(single);
    }
    if (queries.isEmpty) {
      return {'ok': false, 'error': 'Thiếu từ khóa tìm kiếm Bilibili.'};
    }

    final rawMode = (args['search_mode'] ?? '').toString().trim().toLowerCase();
    final searchMode = rawMode == 'exact' ? 'exact' : 'discover';

    final targetKeywords = <String>{
      for (final k in ((args['target_keywords'] as List?) ?? const []))
        if (k.toString().trim().isNotEmpty) k.toString().trim(),
    };
    final excludeKeywords = <String>[
      for (final ex in ((args['exclude_keywords'] as List?) ?? const []))
        if (ex.toString().trim().isNotEmpty)
          ex.toString().trim().toLowerCase(),
    ];

    final tid = _resolveEffectiveTid(args['partition_tid']);
    final contentFocus = _resolveEffectiveContentFocus(
      args,
      queries: queries,
      targetKeywords: targetKeywords,
      tid: tid,
    );

    final baseQueries = searchMode == 'exact' ? queries.take(3).toList() : queries;
    final effectiveQueries =
        (contentFocus == 'ai_anime' && searchMode == 'discover')
        ? _expandAiAnimeQueries(baseQueries)
        : baseQueries;

    final durationSpec = _resolveDurationConstraint(args);
    final recencySpec = _resolveRecencyConstraint(args);
    final hasDurationFilter = durationSpec.minSec > 0 || durationSpec.maxSec > 0;
    final hasRecencyFilter = recencySpec.minPubdateSec > 0;
    final order = _resolveEffectiveOrder(
      args['order'],
      hasRecencyConstraint: hasRecencyFilter,
    );
    final limit = _resolveEffectiveLimit(args['limit']);

    final partLabel = contentFocus == 'ai_anime' && tid == 0
        ? 'Hoạt hình AI (Đã lọc sạch)'
        : (BilibiliPartition.byTid(tid)?.viLabel ?? 'Tất cả');
    onProgress?.call(
      searchMode == 'exact'
          ? 'Đang tìm đúng "${effectiveQueries.first}" trên Bilibili...'
          : 'Đang tìm đề xuất trên Bilibili ($partLabel · ${effectiveQueries.first})...',
    );

    final searchFutures =
        <Future<({int tier, String query, List<BilibiliAnimeItem> rawItems})>>[];
    for (var tier = 0; tier < effectiveQueries.length; tier++) {
      final q = effectiveQueries[tier];
      searchFutures.add(() async {
        final collected = <BilibiliAnimeItem>[];
        final seenBvids = <String>{};

        void addUnique(List<BilibiliAnimeItem> batch) {
          for (final item in batch) {
            final k = item.bvid?.trim().isNotEmpty == true
                ? item.bvid!.trim()
                : item.title.trim();
            if (k.isNotEmpty && seenBvids.add(k)) {
              collected.add(item);
            }
          }
        }

        int countStrictMatches() {
          final hasTs = collected.any((e) => e.pubdate > 0);
          return collected
              .where(
                (e) =>
                    _matchesDuration(e, durationSpec.minSec, durationSpec.maxSec) &&
                    _matchesRecency(e, recencySpec.minPubdateSec, hasTs) &&
                    _matchesContentAndExclusions(
                      e,
                      contentFocus: contentFocus,
                      excludeKeywords: excludeKeywords,
                    ),
              )
              .length;
        }

        try {
          if (contentFocus == 'ai_anime' && tid == 0 && searchMode == 'discover') {
            // Quét song song phân khu Hoạt hình (1) và Quốc sáng (167) để tránh rác kiến thức/người thật/audio ở tid=0
            final animFutures = Future.wait([
              resolver.searchVideos(
                q,
                page: 1,
                pageSize: 20,
                order: order,
                tid: 1,
                duration: durationSpec.apiBucket,
                pubtimeBeginSec: recencySpec.beginSec,
                pubtimeEndSec: recencySpec.endSec,
                cookie: _cookie,
              ),
              resolver.searchVideos(
                q,
                page: 1,
                pageSize: 20,
                order: order,
                tid: 167,
                duration: durationSpec.apiBucket,
                pubtimeBeginSec: recencySpec.beginSec,
                pubtimeEndSec: recencySpec.endSec,
                cookie: _cookie,
              ),
            ]);
            final both = await animFutures;
            addUnique(both[0]);
            addUnique(both[1]);
          } else {
            final p1 = await resolver.searchVideos(
              q,
              page: 1,
              pageSize: 20,
              order: order,
              tid: tid,
              duration: durationSpec.apiBucket,
              pubtimeBeginSec: recencySpec.beginSec,
              pubtimeEndSec: recencySpec.endSec,
              cookie: _cookie,
            );
            addUnique(p1);
          }

          // Nếu có lọc thời lượng / ngày đăng / AI anime mà trang 1 chưa đủ `limit` kết quả sạch -> quét thêm trang 2 (với tid animation nếu tid=0)
          if ((hasDurationFilter || hasRecencyFilter || contentFocus == 'ai_anime') &&
              collected.isNotEmpty &&
              countStrictMatches() < limit) {
            final p2 = await resolver.searchVideos(
              q,
              page: 2,
              pageSize: 20,
              order: order,
              tid: (contentFocus == 'ai_anime' && tid == 0) ? 1 : tid,
              duration: durationSpec.apiBucket,
              pubtimeBeginSec: recencySpec.beginSec,
              pubtimeEndSec: recencySpec.endSec,
              cookie: _cookie,
            );
            addUnique(p2);
          }

          // Nếu thiếu kết quả sạch ở phân khu hẹp -> thử tid=0 (vẫn đi qua bộ lọc nội dung AI anime phía sau!)
          if (countStrictMatches() == 0 && (tid > 0 || contentFocus == 'ai_anime')) {
            final noTid = await resolver.searchVideos(
              q,
              page: 1,
              pageSize: 20,
              order: order,
              tid: 0,
              duration: durationSpec.apiBucket,
              pubtimeBeginSec: recencySpec.beginSec,
              pubtimeEndSec: recencySpec.endSec,
              cookie: _cookie,
            );
            addUnique(noTid);
          }

          // Nếu Bilibili bucket index bỏ sót nhưng tìm `duration: 0` vẫn có video dài đạt ngưỡng [minSec, maxSec] -> thử với `duration: 0` nhưng VẪN giữ filter client!
          if (hasDurationFilter &&
              countStrictMatches() == 0 &&
              durationSpec.apiBucket > 0) {
            final unbucketed = await resolver.searchVideos(
              q,
              page: 1,
              pageSize: 20,
              order: order,
              tid: (contentFocus == 'ai_anime' && tid == 0) ? 1 : tid,
              duration: 0,
              pubtimeBeginSec: recencySpec.beginSec,
              pubtimeEndSec: recencySpec.endSec,
              cookie: _cookie,
            );
            addUnique(unbucketed);
          }

          // Nếu lọc ngày đăng qua API `pubtime_begin_s` rỗng -> thử lại không giới hạn pubtime để kiểm tra hoặc báo rõ
          if (hasRecencyFilter &&
              collected.isEmpty &&
              recencySpec.beginSec != null) {
            final anyDate = await resolver.searchVideos(
              q,
              page: 1,
              pageSize: 20,
              order: 'pubdate',
              tid: (contentFocus == 'ai_anime' && tid == 0) ? 1 : tid,
              duration: durationSpec.apiBucket,
              cookie: _cookie,
            );
            addUnique(anyDate);
          }

          return (tier: tier, query: q, rawItems: collected);
        } catch (_) {
          return (tier: tier, query: q, rawItems: <BilibiliAnimeItem>[]);
        }
      }());
    }

    final tierRawResults = await Future.wait(searchFutures);
    final hasAnyTimestamped = tierRawResults.any(
      (b) => b.rawItems.any((e) => e.pubdate > 0),
    );

    // Lọc sạch nội dung trước (bỏ tutorial/kiến thức, người thật, tiểu thuyết audio nếu đang tìm AI anime)
    final contentCleanTiers =
        <({int tier, String query, List<BilibiliAnimeItem> items})>[];
    var totalCleanContentHits = 0;
    for (final b in tierRawResults) {
      final cleanItems = b.rawItems
          .where(
            (e) => _matchesContentAndExclusions(
              e,
              contentFocus: contentFocus,
              excludeKeywords: excludeKeywords,
            ),
          )
          .toList();
      totalCleanContentHits += cleanItems.length;
      contentCleanTiers.add((tier: b.tier, query: b.query, items: cleanItems));
    }

    final hasContentConstraint =
        contentFocus != 'any' || excludeKeywords.isNotEmpty;
    final contentSatisfied = !hasContentConstraint || totalCleanContentHits > 0;

    // Chỉ dùng pool sạch để kiểm tra thời lượng & ngày đăng (KHÔNG bao giờ thả video rác vào lại!)
    final basePoolTiers =
        (totalCleanContentHits > 0 || hasContentConstraint)
        ? contentCleanTiers
        : [
            for (final b in tierRawResults)
              (tier: b.tier, query: b.query, items: b.rawItems),
          ];

    final strictlyFilteredTiers =
        <({int tier, String query, List<BilibiliAnimeItem> items})>[];
    var totalStrictHits = 0;
    for (final b in basePoolTiers) {
      final filtered = b.items
          .where(
            (e) =>
                _matchesDuration(e, durationSpec.minSec, durationSpec.maxSec) &&
                _matchesRecency(e, recencySpec.minPubdateSec, hasAnyTimestamped),
          )
          .toList();
      totalStrictHits += filtered.length;
      strictlyFilteredTiers.add((tier: b.tier, query: b.query, items: filtered));
    }

    var durationSatisfied = !hasDurationFilter || totalStrictHits > 0;
    var recencySatisfied = !hasRecencyFilter || totalStrictHits > 0;
    String? filterWarning;

    List<({int tier, String query, List<BilibiliAnimeItem> items})> rankingInput =
        strictlyFilteredTiers;

    if (!contentSatisfied) {
      durationSatisfied = !hasDurationFilter;
      recencySatisfied = !hasRecencyFilter;
      filterWarning =
          'Không tìm thấy phim hoạt hình AI thuần túy cho "${effectiveQueries.first}" sau khi đã loại bỏ video kiến thức/hướng dẫn, người thật và tiểu thuyết audio. Hãy thử bật "Hoạt hình AI" kèm từ khóa "AI动画" hoặc "AI漫剧 一口气看完".';
    } else if (hasDurationFilter && totalStrictHits == 0 && totalCleanContentHits > 0) {
      durationSatisfied = false;
      final recencyOnly = <({int tier, String query, List<BilibiliAnimeItem> items})>[];
      var recencyOnlyCount = 0;
      for (final b in basePoolTiers) {
        final f = b.items
            .where((e) => _matchesRecency(e, recencySpec.minPubdateSec, hasAnyTimestamped))
            .toList();
        recencyOnlyCount += f.length;
        recencyOnly.add((tier: b.tier, query: b.query, items: f));
      }
      rankingInput = recencyOnlyCount > 0 ? recencyOnly : basePoolTiers;
      recencySatisfied = !hasRecencyFilter || recencyOnlyCount > 0;
      filterWarning =
          'Không tìm thấy video nào đạt điều kiện thời lượng (${durationSpec.label}) cho "${effectiveQueries.first}"; dưới đây là các video phù hợp dài nhất tìm được.';
    } else if (hasRecencyFilter && totalStrictHits == 0 && totalCleanContentHits > 0) {
      recencySatisfied = false;
      rankingInput = [
        for (final b in basePoolTiers)
          (
            tier: b.tier,
            query: b.query,
            items: b.items
                .where((e) => _matchesDuration(e, durationSpec.minSec, durationSpec.maxSec))
                .toList(),
          ),
      ];
      final fallbackHasAny = rankingInput.any((b) => b.items.isNotEmpty);
      if (!fallbackHasAny) {
        rankingInput = basePoolTiers;
      }
      filterWarning =
          'Chưa có video mới đăng trong ${recencySpec.label} khớp "${effectiveQueries.first}"; đã sắp xếp theo video mới nhất có sẵn.';
    }

    final cachedTaste = tasteService.cachedProfile;
    var rankedPool = _rankSearchResults(
      tierResults: rankingInput,
      targetKeywords: targetKeywords.toList(),
      partitionLabel: partLabel,
      searchMode: searchMode,
      contentFocus: contentFocus,
      exactQuery: effectiveQueries.first,
      preferLongestFallback: hasDurationFilter && !durationSatisfied && durationSpec.minSec > 0,
      preferNewest: hasRecencyFilter && !recencySatisfied,
      tasteProfile: searchMode == 'discover' ? cachedTaste : null,
    );

    if (rankedPool.isEmpty && searchMode == 'exact' && contentFocus != 'ai_anime') {
      // Thử tìm trong kho chính thống (Bangumi / Điện ảnh / Tài liệu) trước khi kết luận rỗng
      try {
        final pgcs = await resolver.searchPgc(
          effectiveQueries.first,
          searchType: 'media_ft',
          pageSize: limit,
          cookie: _cookie,
        );
        final bangumis = pgcs.isNotEmpty
            ? const <BilibiliPgcSearchResult>[]
            : await resolver.searchPgc(
                effectiveQueries.first,
                searchType: 'media_bangumi',
                pageSize: limit,
                cookie: _cookie,
              );
        final allPgc = [...pgcs, ...bangumis];
        rankedPool = [
          for (var i = 0; i < allPgc.length; i++)
            BilibiliAssistantCandidate(
              displayIndex: i + 1,
              kind: BilibiliCandidateKind.pgc,
              item: allPgc[i].toAnimeItem(),
              viTitle: _cachedTitleOrOriginal(allPgc[i].title),
              matchReason: 'Phim chính thống khớp "${effectiveQueries.first}"',
              sourceBadge: allPgc[i].badge.isNotEmpty ? allPgc[i].badge : 'PGC',
              pgcResult: allPgc[i],
              score: 900.0 - i * 10,
            ),
        ];
      } catch (_) {}
    }

    if (rankedPool.isEmpty && searchMode == 'discover' && contentFocus != 'ai_anime') {
      // Fallback sang thịnh hành / bảng xếp hạng phân khu chỉ trong chế độ Đề xuất thông thường
      final fb = tid > 0
          ? await resolver.getZoneRanking(rid: tid, cookie: _cookie)
          : await resolver.getPopularVideos(pageSize: 15, cookie: _cookie);
      final fbTs = fb.any((e) => e.pubdate > 0);
      final filteredFb = fb
          .where(
            (e) =>
                _matchesDuration(e, durationSpec.minSec, durationSpec.maxSec) &&
                _matchesRecency(e, recencySpec.minPubdateSec, fbTs) &&
                _matchesContentAndExclusions(
                  e,
                  contentFocus: contentFocus,
                  excludeKeywords: excludeKeywords,
                ),
          )
          .toList();
      final sourceList = filteredFb.isNotEmpty
          ? filteredFb
          : fb
              .where(
                (e) => _matchesContentAndExclusions(
                  e,
                  contentFocus: contentFocus,
                  excludeKeywords: excludeKeywords,
                ),
              )
              .toList();
      if (hasDurationFilter && filteredFb.isEmpty) durationSatisfied = false;
      rankedPool = [
        for (var i = 0; i < sourceList.length; i++)
          _fromAnimeItem(
            sourceList[i],
            displayIndex: i + 1,
            matchReason: 'Gợi ý nổi bật phân khu $partLabel',
            sourceBadge: partLabel,
            score: 40.0 - i,
          ),
      ];
    }

    final topPool = rankedPool.take(math.max(limit * 2, 20)).toList();
    final selected = await _prepareCandidates(topPool.take(limit).toList());
    final mergedPool = [...selected, ...topPool.skip(selected.length)];

    _savePoolToCache(mergedPool, selected);

    final modePrefix = searchMode == 'exact'
        ? 'Tìm đúng tên'
        : (contentFocus == 'ai_anime' ? 'Hoạt hình AI sạch' : 'Đề xuất');
    final traceParts = <String>[
      '$modePrefix (${effectiveQueries.join(" → ")})',
      if (partLabel != 'Tất cả') partLabel,
      if (durationSpec.label != 'Mọi độ dài') durationSpec.label,
      if (recencySpec.label != 'Mọi lúc') recencySpec.label,
      sortLabel(order),
    ];
    final traceSummary =
        '${traceParts.join(" · ")} → ${selected.length}/${rankedPool.length} video';

    final report = BilibiliSearchReport(
      traceSummary: traceSummary,
      executedQueries: effectiveQueries,
      modeLabel: searchMode == 'exact'
          ? 'Tìm đúng trên Bilibili'
          : (contentFocus == 'ai_anime'
              ? 'Phim hoạt hình AI (Đã lọc sạch)'
              : 'Đề xuất Bilibili'),
      totalPoolCount: rankedPool.length,
      candidates: selected,
    );
    _lastSearchReport = report;
    onSearchResultsUpdated?.call(report);

    return {
      'ok': true,
      'searchMode': searchMode,
      'contentFocus': contentFocus,
      'traceSummary': traceSummary,
      'returnedCount': selected.length,
      'contentFilterSatisfied': contentSatisfied,
      'durationFilterSatisfied': durationSatisfied,
      'recencyFilterSatisfied': recencySatisfied,
      'filterWarning': ?filterWarning,
      'candidates': selected.map(_serializeCompactCandidate).toList(),
      'instruction': _liveTranslationInstruction,
    };
  }

  List<BilibiliAssistantCandidate> _rankSearchResults({
    required List<({int tier, String query, List<BilibiliAnimeItem> items})>
        tierResults,
    required List<String> targetKeywords,
    required String partitionLabel,
    String searchMode = 'discover',
    String contentFocus = 'any',
    String exactQuery = '',
    bool preferLongestFallback = false,
    bool preferNewest = false,
    BilibiliTasteProfile? tasteProfile,
  }) {
    final map = <String, _RawBiliAccumulator>{};
    for (final batch in tierResults) {
      for (var pos = 0; pos < batch.items.length; pos++) {
        final item = batch.items[pos];
        final key = (item.bvid?.trim().isNotEmpty == true)
            ? item.bvid!.trim()
            : item.title.trim();
        if (key.isEmpty) continue;
        final acc = map.putIfAbsent(key, () => _RawBiliAccumulator(item));
        if (batch.tier < acc.bestTier) {
          acc.bestTier = batch.tier;
          acc.bestPos = pos;
        } else if (batch.tier == acc.bestTier && pos < acc.bestPos) {
          acc.bestPos = pos;
        }
        acc.hitQueries.add(batch.query);

        final haystack = '${item.title} ${item.desc} ${item.author}'.toLowerCase();
        for (final kw in targetKeywords) {
          final k = kw.trim().toLowerCase();
          if (k.isNotEmpty && haystack.contains(k)) {
            acc.matchedConcepts.add(kw.trim());
          }
        }
        if (acc.item.desc.isEmpty && item.desc.isNotEmpty) {
          acc.item = item;
        }
      }
    }

    final cleanExact = exactQuery.trim().toLowerCase();
    final scored = map.values.map((acc) {
      double score = 0;
      if (searchMode == 'exact') {
        // Giữ nguyên thứ tự top kết quả tìm kiếm đầu tiên của Bilibili
        score = 1000.0 - acc.bestTier * 180.0 - acc.bestPos * 12.0;
        if (cleanExact.isNotEmpty &&
            acc.item.title.toLowerCase().contains(cleanExact)) {
          score += 55.0;
        }
      } else {
        score += math.max(0, 50 - acc.bestTier * 14);
        score += acc.hitQueries.length * 10;
        score += acc.matchedConcepts.length * 15;
        score += math.max(0, 12 - acc.bestPos) * 0.5;
        if (acc.item.durationSeconds >= 120) score += 4;
        if (contentFocus == 'ai_anime') {
          score += BilibiliContentClassifier.scoreWatchableAiAnime(acc.item);
        }
        if (tasteProfile != null && !tasteProfile.isEmpty) {
          if (tasteProfile.topAuthors.contains(acc.item.author.trim())) {
            score += 12.0;
          }
          final hay = '${acc.item.title} ${acc.item.badge} ${acc.item.desc}'
              .toLowerCase();
          final tasteHits = tasteProfile.affinityTerms
              .where((t) => hay.contains(t))
              .length;
          if (tasteHits > 0) score += math.min(12.0, tasteHits * 4.0);
        }
      }
      if (preferLongestFallback) {
        score = acc.item.durationSeconds.toDouble() +
            (acc.item.title.toLowerCase().contains(cleanExact) ? 120.0 : 0.0);
      } else if (preferNewest && acc.item.pubdate > 0) {
        score += (acc.item.pubdate / 1000000.0);
      }

      final cachedSrt = srtService.getCachedSession(acc.item.bvid ?? '');

      final reasonParts = <String>[
        if (searchMode == 'exact')
          'Top ${acc.bestPos + 1} tìm kiếm'
        else
          'Lớp ${acc.bestTier + 1}',
        if (acc.matchedConcepts.isNotEmpty)
          'Khớp: ${acc.matchedConcepts.take(3).join(", ")}'
        else if (acc.hitQueries.isNotEmpty)
          'Từ khóa: ${acc.hitQueries.first}',
      ];

      final zoneBadge = acc.item.badge.isNotEmpty
          ? acc.item.badge
          : partitionLabel;

      return BilibiliAssistantCandidate(
        displayIndex: 0,
        kind: BilibiliCandidateKind.video,
        item: acc.item,
        viTitle: _cachedTitleOrOriginal(acc.item.title),
        matchReason: reasonParts.join(' · '),
        sourceBadge: zoneBadge,
        score: score,
        matchedTier: acc.bestTier,
        hasSrtInMemory: cachedSrt != null,
        srtChunkCount: cachedSrt?.totalChunks ?? 0,
        srtSourceLabel: cachedSrt?.sourceLabel ?? '',
      );
    }).toList();

    scored.sort((a, b) => b.score.compareTo(a.score));
    return [
      for (var i = 0; i < scored.length; i++)
        scored[i].copyWith(displayIndex: i + 1),
    ];
  }

  Future<Map<String, dynamic>> _handleExploreDiscovery(
    Map<String, dynamic> args, {
    void Function(String)? onProgress,
    void Function(BilibiliSearchReport)? onSearchResultsUpdated,
  }) async {
    final mode = (args['mode'] ?? 'popular').toString().trim().toLowerCase();
    final tid = _resolveEffectiveTid(args['partition_tid']);
    final pgcType = (args['pgc_type'] ?? 'documentary').toString().trim().toLowerCase();
    final limit = _resolveEffectiveLimit(args['limit']);

    if (mode == 'hot_keywords') {
      onProgress?.call('Đang lấy từ khóa tìm kiếm đang hot trên Bilibili...');
      final kws = await resolver.getHotSearchKeywords();
      return {
        'ok': true,
        'mode': 'hot_keywords',
        'hotKeywords': kws,
        'instruction':
            'Dịch danh sách từ khóa hot này sang Tiếng Việt ngắn gọn và hỏi xem người dùng muốn AI tìm sâu từ khóa nào.',
      };
    }

    List<BilibiliAnimeItem> rawItems = const [];
    String modeLabel = 'Khám phá Bilibili';
    String badge = 'Bilibili';

    if (mode == 'recommend') {
      onProgress?.call('Đang tải danh sách Đề xuất Bilibili...');
      rawItems = await resolver.getRecommendFeed(
        pageSize: math.max(limit * 2, 16),
        cookie: _cookie,
      );
      modeLabel = 'Đề xuất cá nhân';
      badge = '✨ Đề xuất';
    } else if (mode == 'ranking') {
      final part = BilibiliPartition.byTid(tid);
      onProgress?.call(
        'Đang lấy BXH ${part?.viLabel ?? "Toàn trang"} Bilibili...',
      );
      rawItems = await resolver.getZoneRanking(rid: tid, cookie: _cookie);
      modeLabel = 'BXH ${part?.viLabel ?? "Toàn trang"}';
      badge = part != null && part.tid > 0 ? '🏆 ${part.viLabel}' : '🏆 BXH Hot';
    } else if (mode == 'pgc_catalog') {
      final seasonType = switch (pgcType) {
        'anime' => 1,
        'movie' => 2,
        'documentary' => 3,
        'guochuang' => 4,
        'tv' => 5,
        'variety' => 7,
        _ => 3,
      };
      modeLabel = switch (seasonType) {
        1 => 'Kho Anime Nhật',
        2 => 'Kho Phim Điện Ảnh',
        3 => 'Kho Phim Tài Liệu',
        4 => 'Kho Hoạt Hình Trung Quốc',
        5 => 'Kho Phim Bộ',
        7 => 'Kho Show Giải Trí',
        _ => 'Kho PGC Bilibili',
      };
      badge = modeLabel.replaceFirst('Kho ', '');
      onProgress?.call('Đang tải $modeLabel...');
      rawItems = await resolver.getPgcCatalog(
        seasonType: seasonType,
        pageSize: math.max(limit * 2, 16),
        cookie: _cookie,
      );
    } else {
      onProgress?.call('Đang tải danh sách Thịnh hành (Popular)...');
      rawItems = await resolver.getPopularVideos(
        pageSize: math.max(limit * 2, 16),
        cookie: _cookie,
      );
      modeLabel = 'Thịnh hành toàn trang';
      badge = '🔥 Thịnh hành';
    }

    final pool = [
      for (var i = 0; i < rawItems.length; i++)
        _fromAnimeItem(
          rawItems[i],
          displayIndex: i + 1,
          matchReason: '#${i + 1} · $modeLabel',
          sourceBadge: rawItems[i].badge.isNotEmpty ? rawItems[i].badge : badge,
          score: 100.0 - i,
        ),
    ];

    final selected = await _prepareCandidates(pool.take(limit).toList());
    final merged = [...selected, ...pool.skip(selected.length)];
    _savePoolToCache(merged, selected);

    final traceSummary = '$modeLabel · Hiển thị ${selected.length} mục nổi bật';
    final report = BilibiliSearchReport(
      traceSummary: traceSummary,
      executedQueries: [mode],
      modeLabel: modeLabel,
      totalPoolCount: pool.length,
      candidates: selected,
    );
    _lastSearchReport = report;
    onSearchResultsUpdated?.call(report);

    return {
      'ok': true,
      'traceSummary': traceSummary,
      'candidates': selected.map(_serializeCompactCandidate).toList(),
      'instruction': _liveTranslationInstruction,
    };
  }

  Future<Map<String, dynamic>> _handleSearchCreators(
    Map<String, dynamic> args, {
    void Function(String)? onProgress,
    void Function(BilibiliSearchReport)? onSearchResultsUpdated,
  }) async {
    final keyword = (args['keyword'] ?? '').toString().trim();
    if (keyword.isEmpty) {
      return {'ok': false, 'error': 'Thiếu tên kênh hoặc chủ đề UP chủ.'};
    }
    final fetchTopVideos = args['fetch_top_uploader_videos'] != false;
    final limit = _resolveEffectiveLimit(args['limit']);

    onProgress?.call('Đang tìm kênh UP "$keyword"...');
    final users = await resolver.searchUsers(
      keyword,
      pageSize: math.max(limit, 8),
      cookie: _cookie,
    );
    if (users.isEmpty) {
      return {
        'ok': false,
        'message': 'Không tìm thấy kênh UP chủ khớp "$keyword".',
      };
    }

    final pool = [
      for (var i = 0; i < users.length; i++)
        BilibiliAssistantCandidate(
          displayIndex: i + 1,
          kind: BilibiliCandidateKind.upChannel,
          item: BilibiliAnimeItem(
            title: users[i].uname,
            cover: users[i].upic,
            author: users[i].uname,
            upFace: users[i].upic,
            desc: users[i].usign,
            viewCountText: '${users[i].fansText} fan · ${users[i].videos} video',
          ),
          viTitle: _cachedTitleOrOriginal(users[i].uname),
          matchReason:
              'Kênh UP · ${users[i].fansText} fan · ${users[i].videos} video',
          sourceBadge: users[i].isOfficial ? '✓ Kênh chính thức' : '👤 Kênh UP',
          userResult: users[i],
          score: 100.0 - i,
        ),
    ];

    final selected = await _prepareCandidates(pool.take(limit).toList());
    _savePoolToCache(pool, selected);

    List<BilibiliAnimeItem> topCreatorVideos = const [];
    if (fetchTopVideos && users.isNotEmpty) {
      onProgress?.call('Đang xem video mới của kênh ${users.first.uname}...');
      topCreatorVideos = await resolver.getUploaderVideos(
        users.first.mid,
        authorName: users.first.uname,
        pageSize: 4,
        cookie: _cookie,
      );
    }

    final traceSummary =
        'Tìm UP chủ "$keyword" → ${selected.length} kênh phù hợp nhất';
    final report = BilibiliSearchReport(
      traceSummary: traceSummary,
      executedQueries: [keyword],
      modeLabel: 'Tìm kênh UP Bilibili',
      totalPoolCount: pool.length,
      candidates: selected,
    );
    _lastSearchReport = report;
    onSearchResultsUpdated?.call(report);

    return {
      'ok': true,
      'traceSummary': traceSummary,
      'candidates': selected.map(_serializeCompactCandidate).toList(),
      if (topCreatorVideos.isNotEmpty)
        'topChannelRecentVideos': topCreatorVideos
            .take(4)
            .map((v) => {
                  'bvid': v.bvid,
                  'title': v.title,
                  'duration': v.durationText,
                  'views': v.viewCountText,
                })
            .toList(),
      'instruction': _liveTranslationInstruction,
    };
  }

  Future<Map<String, dynamic>> _handleInspectUploaderVideos(
    Map<String, dynamic> args, {
    void Function(String)? onProgress,
    void Function(BilibiliSearchReport)? onSearchResultsUpdated,
  }) async {
    int mid = int.tryParse((args['mid'] ?? '').toString()) ?? 0;
    String authorName = (args['author_name'] ?? '').toString().trim();

    final idx = int.tryParse((args['index'] ?? '').toString());
    if (idx != null) {
      final cand = getByDisplayIndex(idx);
      if (cand != null) {
        if (cand.userResult != null) {
          mid = cand.userResult!.mid;
          authorName = cand.userResult!.uname;
        } else {
          if (authorName.isEmpty) authorName = cand.item.author;
          if (mid <= 0 && cand.bvid.isNotEmpty) {
            final d = await resolver.getVideoDetails(
              _targetForBvid(cand.bvid),
              _cookie,
            );
            mid = d.ownerMid;
            if (authorName.isEmpty) authorName = d.author;
          }
        }
      }
    }

    if (mid <= 0 && authorName.isEmpty) {
      return {'ok': false, 'error': 'Không xác định được kênh UP chủ để tải video.'};
    }

    final order = (args['order'] ?? 'pubdate').toString() == 'click'
        ? 'click'
        : 'pubdate';
    final limit = _resolveEffectiveLimit(args['limit']);

    onProgress?.call('Đang lấy video của kênh ${authorName.isEmpty ? "mid=$mid" : authorName}...');

    final profileFuture = mid > 0
        ? resolver.getUploaderProfile(mid, cookie: _cookie)
        : Future.value(null);
    final videosFuture = resolver.getUploaderVideos(
      mid,
      authorName: authorName,
      pageSize: math.max(limit * 2, 12),
      order: order,
      cookie: _cookie,
    );

    final profile = await profileFuture;
    final videos = await videosFuture;
    final effectiveAuthor = profile?.name.isNotEmpty == true
        ? profile!.name
        : authorName;

    final pool = [
      for (var i = 0; i < videos.length; i++)
        _fromAnimeItem(
          videos[i],
          displayIndex: i + 1,
          matchReason:
              '${sortLabel(order)} · Kênh ${effectiveAuthor.isEmpty ? "UP" : effectiveAuthor}',
          sourceBadge: '👤 $effectiveAuthor',
          score: 100.0 - i,
        ),
    ];

    final selected = await _prepareCandidates(pool.take(limit).toList());
    _savePoolToCache(pool, selected);

    final traceSummary =
        'Video của kênh "$effectiveAuthor" (${sortLabel(order)}) → ${selected.length} video';
    final report = BilibiliSearchReport(
      traceSummary: traceSummary,
      executedQueries: [effectiveAuthor],
      modeLabel: 'Kênh UP $effectiveAuthor',
      totalPoolCount: pool.length,
      candidates: selected,
    );
    _lastSearchReport = report;
    onSearchResultsUpdated?.call(report);

    return {
      'ok': true,
      if (profile != null)
        'uploaderProfile': {
          'mid': profile.mid,
          'name': profile.name,
          'fans': profile.fansText,
          'videoCount': profile.videoCount,
          'sign': profile.sign,
        },
      'candidates': selected.map(_serializeCompactCandidate).toList(),
      'instruction': _liveTranslationInstruction,
    };
  }

  Future<Map<String, dynamic>> _handleSearchPgc(
    Map<String, dynamic> args, {
    void Function(String)? onProgress,
    void Function(BilibiliSearchReport)? onSearchResultsUpdated,
  }) async {
    final keyword = (args['keyword'] ?? '').toString().trim();
    if (keyword.isEmpty) {
      return {'ok': false, 'error': 'Thiếu tên phim/anime/tài liệu để tìm.'};
    }
    final cat = (args['pgc_category'] ?? 'all').toString().trim().toLowerCase();
    final limit = _resolveEffectiveLimit(args['limit']);

    onProgress?.call('Đang tìm phim/tài liệu/anime "$keyword"...');

    final ftFuture = (cat == 'all' || cat == 'ft')
        ? resolver.searchPgc(
            keyword,
            searchType: 'media_ft',
            pageSize: 10,
            cookie: _cookie,
          )
        : Future.value(const <BilibiliPgcSearchResult>[]);
    final bgFuture = (cat == 'all' || cat == 'bangumi')
        ? resolver.searchPgc(
            keyword,
            searchType: 'media_bangumi',
            pageSize: 10,
            cookie: _cookie,
          )
        : Future.value(const <BilibiliPgcSearchResult>[]);

    final results = <BilibiliPgcSearchResult>[
      ...await ftFuture,
      ...await bgFuture,
    ];

    if (results.isEmpty) {
      return {
        'ok': false,
        'message':
            'Không có PGC chính thống khớp "$keyword". Hãy thử tìm bằng `search_bilibili_videos`.',
      };
    }

    final pool = [
      for (var i = 0; i < results.length; i++)
        BilibiliAssistantCandidate(
          displayIndex: i + 1,
          kind: BilibiliCandidateKind.pgc,
          item: results[i].toAnimeItem(),
          viTitle: _cachedTitleOrOriginal(results[i].title),
          matchReason: [
            if (results[i].score.isNotEmpty) '★ ${results[i].score}',
            if (results[i].indexShow.isNotEmpty) results[i].indexShow,
            if (results[i].areas.isNotEmpty) results[i].areas,
          ].join(' · '),
          sourceBadge: results[i].badge.isNotEmpty
              ? results[i].badge
              : '🎞️ PGC',
          pgcResult: results[i],
          score: 100.0 - i,
        ),
    ];

    final selected = await _prepareCandidates(pool.take(limit).toList());
    _savePoolToCache(pool, selected);

    final traceSummary = 'Tìm Phim/Anime/Tài liệu "$keyword" → ${selected.length} mục';
    final report = BilibiliSearchReport(
      traceSummary: traceSummary,
      executedQueries: [keyword],
      modeLabel: 'PGC Bilibili',
      totalPoolCount: pool.length,
      candidates: selected,
    );
    _lastSearchReport = report;
    onSearchResultsUpdated?.call(report);

    return {
      'ok': true,
      'candidates': selected.map(_serializeCompactCandidate).toList(),
      'instruction': _liveTranslationInstruction,
    };
  }

  ({String? bvid, BilibiliAssistantCandidate? candidate}) _resolveVideoTarget(
    Map<String, dynamic> args,
  ) {
    final rawBvid = (args['bvid'] ?? '').toString().trim();
    final idx = int.tryParse((args['index'] ?? '').toString());
    BilibiliAssistantCandidate? cand;
    if (idx != null) {
      cand = getByDisplayIndex(idx);
    }
    if (cand == null && rawBvid.isNotEmpty) {
      cand = getByKey(rawBvid);
    }
    if (cand == null && _currentLocks.pinnedKeys.isNotEmpty) {
      cand = getByKey(_currentLocks.pinnedKeys.last);
    }
    final bvid = rawBvid.isNotEmpty
        ? rawBvid
        : (cand?.bvid.isNotEmpty == true ? cand!.bvid : (_activeSrtBvid ?? ''));
    return (bvid: bvid.isEmpty ? null : bvid, candidate: cand);
  }

  static final RegExp _storyStyleHintRegex = RegExp(
    r'(漫剧|ai漫|动漫|番剧|动画|剧情|解说|小说|重生|修仙|逆袭|穿书|系统|都市|玄幻|仙侠|霸总|甜宠|悬疑剧|有声|全集|完整版|hoạt hình|cốt truyện|phim ai|trọng sinh|tu tiên|anime|donghua|story)',
    caseSensitive: false,
  );

  static String _resolveSummaryStyle(
    Map<String, dynamic> args, {
    String title = '',
    String desc = '',
  }) {
    final raw = (args['summary_style'] ?? '').toString().trim().toLowerCase();
    if (raw == 'story' ||
        raw == 'narrative' ||
        raw == 'cot_truyen' ||
        raw == 'cốt truyện' ||
        raw == 'plot') {
      return 'story';
    }
    if (raw == 'structured' ||
        raw == 'bullets' ||
        raw == 'info' ||
        raw == 'timeline' ||
        raw == 'timestamps') {
      return 'structured';
    }
    if (_storyStyleHintRegex.hasMatch('$title $desc')) {
      return 'story';
    }
    return 'structured';
  }

  static String _summaryInstructionForStyle(String style) {
    if (style == 'story') {
      return 'QUY TẮC TÓM TẮT CỐT TRUYỆN (STORY): Kể lại mạch truyện trôi chảy, hấp dẫn bằng tiếng Việt (tên nhân vật/chiêu thức/tông môn dịch Hán Việt chuẩn). TUYỆT ĐỐI KHÔNG chèn mốc thời gian [mm:ss], KHÔNG gạch đầu dòng theo phút. Tập trung bối cảnh mở đầu -> xung đột/bàn tay vàng -> diễn biến chính -> cao trào/kết thúc hiện tại.';
    }
    return 'QUY TẮC TÓM TẮT Ý CHÍNH (STRUCTURED): Tóm tắt rõ ràng bằng tiếng Việt theo các ý chính/thông tin quan trọng, KÈM mốc thời gian [mm:ss] để người xem dễ tua tới đúng đoạn.';
  }

  Future<Map<String, dynamic>> _handleInspectVideoOverview(
    Map<String, dynamic> args, {
    void Function(String)? onProgress,
    void Function(BilibiliSearchReport)? onSearchResultsUpdated,
  }) async {
    final resolved = _resolveVideoTarget(args);
    final bvid = resolved.bvid;
    if (bvid == null) {
      return {
        'ok': false,
        'error':
            'Chưa xác định được mã BVID của video (có thể thẻ này là Kênh UP hoặc Phim dài tập chưa chọn tập).',
      };
    }
    final page = (int.tryParse((args['page'] ?? '').toString()) ?? 1).clamp(1, 500);
    onProgress?.call('Đang tải thông tin, bình luận top & phụ đề nhanh ($bvid)...');

    final details = await resolver.getVideoDetails(
      _targetForBvid(bvid, page: page),
      _cookie,
    );

    final commentsFuture = resolver.getComments(
      aid: details.aid,
      page: 1,
      pageSize: 12,
      sort: 0, // Comment Hot
      cookie: _cookie,
    );
    final srtFuture = srtService.loadFastSrt(details, cookie: _cookie);

    final commentsRes = await commentsFuture;
    final srtRes = await srtFuture;

    if (srtRes.session != null) {
      _activeSrtBvid = details.bvid;
      _activeSrtPage = details.selectedPageIndex;
      _markCandidateSrtLoaded(
        details.bvid,
        srtRes.session!,
        onSearchResultsUpdated: onSearchResultsUpdated,
      );
    }

    final rawDesc = (details.desc ?? '').trim();
    final compactDesc =
        rawDesc.length > 800 ? '${rawDesc.substring(0, 800)}...' : rawDesc;
    final summaryStyle = _resolveSummaryStyle(
      args,
      title: '${details.title} ${resolved.candidate?.viTitle ?? ""}',
      desc: compactDesc,
    );
    final summaryInstruction = _summaryInstructionForStyle(summaryStyle);

    return {
      'ok': true,
      'summaryStyle': summaryStyle,
      'summaryInstruction': summaryInstruction,
      'video': {
        'bvid': details.bvid,
        'page': details.selectedPageIndex,
        'titleZh': details.title,
        'author': details.author,
        'ownerMid': details.ownerMid,
        'duration': BilibiliAnimeItem.formatDuration(details.durationSeconds),
        'views': details.viewCountText,
        'danmaku': details.danmakuText,
        'desc': compactDesc,
        if (details.pages.length > 1)
          'pagesCount': details.pages.length,
        if (details.pages.length > 1)
          'pages': details.pages
              .take(15)
              .map((p) => {'page': p.page, 'title': p.part})
              .toList(),
        if (details.ugcSeason != null)
          'ugcSeason': {
            'title': details.ugcSeason!.title,
            'epCount': details.ugcSeason!.epCount,
          },
      },
      'hotCommentsCount': commentsRes.comments.length,
      'hotComments': commentsRes.comments.take(10).map((c) {
        final msg = c.message.trim();
        return {
          'user': c.uname,
          'likes': c.likeCount,
          'text': msg.length > 260 ? '${msg.substring(0, 260)}...' : msg,
        };
      }).toList(),
      if (srtRes.session != null)
        'srt': {
          ...srtRes.session!.buildOverviewPayload(),
          'summaryStyle': summaryStyle,
          'summaryInstruction': summaryInstruction,
        }
      else
        'srt': {
          'hasSrt': false,
          'loginRequiredForCc': srtRes.loginRequiredForCc,
          'sttAvailable': srtRes.sttAvailable,
          'statusNote': srtRes.statusNote,
          'summaryStyle': summaryStyle,
          'summaryInstruction': summaryInstruction,
          'actionRule':
              'CHƯA có sẵn phụ đề CC. Theo Phương án A: hãy tóm tắt trước bằng Mô tả + Danh sách tập + Bình luận Hot ở trên (tuân theo summaryInstruction); nói rõ video chưa có sẵn phụ đề CC và hỏi người dùng xem có muốn chạy tạo phụ đề .srt bằng âm thanh (CapCut STT) hay không (chỉ gọi extract_video_srt_stt sau khi họ đồng ý).',
        },
    };
  }

  Future<Map<String, dynamic>> _handleExtractSrtStt(
    Map<String, dynamic> args, {
    void Function(String)? onProgress,
    void Function(BilibiliSearchReport)? onSearchResultsUpdated,
  }) async {
    final resolved = _resolveVideoTarget(args);
    final bvid = resolved.bvid;
    if (bvid == null) {
      return {'ok': false, 'error': 'Thiếu mã BVID để trích xuất SRT.'};
    }
    final page = (int.tryParse((args['page'] ?? '').toString()) ?? 1).clamp(1, 500);
    onProgress?.call('Đang kết nối tải audio nhẹ & tạo SRT bằng CapCut STT...');

    final details = await resolver.getVideoDetails(
      _targetForBvid(bvid, page: page),
      _cookie,
    );

    final res = await srtService.extractSrtWithCapCutStt(
      details,
      cookie: _cookie,
      onProgress: (_, msg) => onProgress?.call(msg),
    );
    if (res.session == null) {
      return {
        'ok': false,
        'error': res.statusNote,
      };
    }

    _activeSrtBvid = details.bvid;
    _activeSrtPage = details.selectedPageIndex;
    _markCandidateSrtLoaded(
      details.bvid,
      res.session!,
      onSearchResultsUpdated: onSearchResultsUpdated,
    );

    return {
      'ok': true,
      'statusNote': res.statusNote,
      'srt': res.session!.buildOverviewPayload(),
    };
  }

  Future<Map<String, dynamic>> _handleReadSrtChunk(
    Map<String, dynamic> args, {
    void Function(String)? onProgress,
    void Function(BilibiliSearchReport)? onSearchResultsUpdated,
  }) async {
    final resolved = _resolveVideoTarget(args);
    final bvid = resolved.bvid;
    if (bvid == null) {
      return {
        'ok': false,
        'error': 'Chưa có video nào đang mở SRT. Hãy gọi `inspect_video_overview` trước.',
      };
    }
    final page = (int.tryParse((args['page'] ?? '').toString()) ?? _activeSrtPage)
        .clamp(1, 500);
    final chunkNum = int.tryParse((args['chunk_number'] ?? '').toString()) ?? 1;

    var session = srtService.getCachedSession(bvid, pageIndex: page);
    if (session == null) {
      onProgress?.call('Đang nạp SRT ($bvid)...');
      final details = await resolver.getVideoDetails(
        _targetForBvid(bvid, page: page),
        _cookie,
      );
      final fast = await srtService.loadFastSrt(details, cookie: _cookie);
      session = fast.session;
      if (session != null) {
        _activeSrtBvid = details.bvid;
        _activeSrtPage = details.selectedPageIndex;
        _markCandidateSrtLoaded(
          details.bvid,
          session,
          onSearchResultsUpdated: onSearchResultsUpdated,
        );
      }
    }

    if (session == null) {
      return {
        'ok': false,
        'sttAvailable': true,
        'error':
            'Video $bvid chưa có SRT trong bộ nhớ hoặc CC sẵn có. Nếu user muốn đọc sâu từng đoạn từ giọng nói, hãy hỏi ý kiến chạy `extract_video_srt_stt`.',
      };
    }

    final summaryStyle = _resolveSummaryStyle(
      args,
      title:
          '${resolved.candidate?.item.title ?? ""} ${resolved.candidate?.viTitle ?? ""}',
      desc: resolved.candidate?.item.desc ?? '',
    );

    return {
      ...session.readChunkPayload(chunkNum),
      'summaryStyle': summaryStyle,
      'summaryInstruction': _summaryInstructionForStyle(summaryStyle),
    };
  }

  Future<Map<String, dynamic>> _handleSearchSrtTopic(
    Map<String, dynamic> args, {
    void Function(String)? onProgress,
    void Function(BilibiliSearchReport)? onSearchResultsUpdated,
  }) async {
    final resolved = _resolveVideoTarget(args);
    final bvid = resolved.bvid;
    if (bvid == null) {
      return {
        'ok': false,
        'error': 'Chưa xác định được video BVID để tìm trong SRT.',
      };
    }
    final page = (int.tryParse((args['page'] ?? '').toString()) ?? _activeSrtPage)
        .clamp(1, 500);
    final keywords = ((args['keywords'] as List?) ?? const [])
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();

    var session = srtService.getCachedSession(bvid, pageIndex: page);
    if (session == null) {
      onProgress?.call('Đang kiểm tra phụ đề CC nhanh ($bvid)...');
      final details = await resolver.getVideoDetails(
        _targetForBvid(bvid, page: page),
        _cookie,
      );
      final fast = await srtService.loadFastSrt(details, cookie: _cookie);
      session = fast.session;
      if (session != null) {
        _activeSrtBvid = details.bvid;
        _activeSrtPage = details.selectedPageIndex;
        _markCandidateSrtLoaded(
          details.bvid,
          session,
          onSearchResultsUpdated: onSearchResultsUpdated,
        );
      }
    }

    if (session == null) {
      return {
        'ok': false,
        'sttAvailable': true,
        'error': 'Video chưa có SRT sẵn để tìm từ khóa. Có thể hỏi user chạy `extract_video_srt_stt`.',
      };
    }

    return session.searchTopicPayload(keywords);
  }

  Future<Map<String, dynamic>> _handleRelatedVideos(
    Map<String, dynamic> args, {
    void Function(String)? onProgress,
    void Function(BilibiliSearchReport)? onSearchResultsUpdated,
  }) async {
    final resolved = _resolveVideoTarget(args);
    final bvid = resolved.bvid;
    if (bvid == null) {
      return {'ok': false, 'error': 'Thiếu BVID để tìm video liên quan.'};
    }
    final limit = _resolveEffectiveLimit(args['limit']);
    onProgress?.call('Đang lấy video liên quan tới $bvid...');
    final related = await resolver.getRelatedVideos(bvid, cookie: _cookie);
    if (related.isEmpty) {
      return {'ok': false, 'message': 'Không lấy được video liên quan cho $bvid.'};
    }

    final pool = [
      for (var i = 0; i < related.length; i++)
        _fromAnimeItem(
          related[i],
          displayIndex: i + 1,
          matchReason: 'Liên quan tới $bvid',
          sourceBadge: '🔗 Liên quan',
          score: 90.0 - i,
        ),
    ];
    final selected = await _prepareCandidates(pool.take(limit).toList());
    _savePoolToCache(pool, selected);

    final traceSummary = 'Video liên quan tới $bvid → ${selected.length} gợi ý';
    final report = BilibiliSearchReport(
      traceSummary: traceSummary,
      executedQueries: [bvid],
      modeLabel: 'Video liên quan',
      totalPoolCount: pool.length,
      candidates: selected,
    );
    _lastSearchReport = report;
    onSearchResultsUpdated?.call(report);

    return {
      'ok': true,
      'candidates': selected.map(_serializeCompactCandidate).toList(),
      'instruction': _liveTranslationInstruction,
    };
  }

  void _markCandidateSrtLoaded(
    String bvid,
    BilibiliSrtSession session, {
    void Function(BilibiliSearchReport report)? onSearchResultsUpdated,
  }) {
    final cleanBvid = bvid.trim();
    if (cleanBvid.isEmpty) return;

    for (var i = 0; i < _lastDisplayed.length; i++) {
      if (_lastDisplayed[i].bvid == cleanBvid) {
        final updated = _lastDisplayed[i].copyWith(
          hasSrtInMemory: true,
          srtChunkCount: session.totalChunks,
          srtSourceLabel: session.sourceLabel,
        );
        _lastDisplayed[i] = updated;
        _candidateCache[updated.candidateKey] = updated;
      }
    }

    if (_lastSearchReport != null) {
      var changed = false;
      final list = _lastSearchReport!.candidates.map((c) {
        if (c.bvid == cleanBvid) {
          changed = true;
          return c.copyWith(
            hasSrtInMemory: true,
            srtChunkCount: session.totalChunks,
            srtSourceLabel: session.sourceLabel,
          );
        }
        return c;
      }).toList();
      if (changed) {
        _lastSearchReport = _lastSearchReport!.copyWith(candidates: list);
        onSearchResultsUpdated?.call(_lastSearchReport!);
      }
    }
  }

  BilibiliAssistantCandidate _fromAnimeItem(
    BilibiliAnimeItem item, {
    required int displayIndex,
    required String matchReason,
    required String sourceBadge,
    required double score,
  }) {
    final bvid = (item.bvid ?? '').trim();
    final cachedSrt =
        bvid.isNotEmpty ? srtService.getCachedSession(bvid) : null;
    return BilibiliAssistantCandidate(
      displayIndex: displayIndex,
      kind: item.seasonId != null && item.seasonId! > 0 && bvid.isEmpty
          ? BilibiliCandidateKind.pgc
          : BilibiliCandidateKind.video,
      item: item,
      viTitle: _cachedTitleOrOriginal(item.title),
      matchReason: matchReason,
      sourceBadge: sourceBadge,
      score: score,
      hasSrtInMemory: cachedSrt != null,
      srtChunkCount: cachedSrt?.totalChunks ?? 0,
      srtSourceLabel: cachedSrt?.sourceLabel ?? '',
    );
  }

  String _cachedTitleOrOriginal(String rawTitle) {
    final cached = _aiViTitleCache[rawTitle.trim()];
    if (cached != null && cached.isNotEmpty) return cached;
    return rawTitle;
  }

  Future<List<BilibiliAssistantCandidate>> _prepareCandidates(
    List<BilibiliAssistantCandidate> items,
  ) async {
    return Future.wait(
      items.map((cand) async {
        final clean = cand.item.title.trim();
        final cached = _aiViTitleCache[clean];
        if (cached != null && cached.isNotEmpty) {
          return cand.copyWith(viTitle: cached);
        }
        final translator = translateTitle;
        if (translator != null) {
          try {
            final res = await translator(
              cand.item.title,
            ).timeout(const Duration(milliseconds: 1800), onTimeout: () => '');
            if (res.trim().isNotEmpty) {
              return cand.copyWith(viTitle: res.trim());
            }
          } catch (_) {}
        }
        return cand;
      }),
    );
  }

  void _savePoolToCache(
    List<BilibiliAssistantCandidate> pool,
    List<BilibiliAssistantCandidate> displayed,
  ) {
    _lastDisplayed
      ..clear()
      ..addAll(displayed);
    for (final c in pool) {
      _candidateCache[c.candidateKey] = c;
    }
  }

  static const String _liveTranslationInstruction =
      'TỰ DỊCH bằng Gemini Live sang Tiếng Việt (Hán Việt chuẩn cho phim/nhân vật, tự nhiên cho công nghệ/đời sống, TUYỆT ĐỐI CẤM Pinyin). '
      'Mở đầu mỗi mục đúng mẫu "#1. <Tiêu đề Tiếng Việt> — <Mô tả 1 câu ngắn>" để app đồng bộ tên lên thẻ.';

  static Map<String, dynamic> _serializeCompactCandidate(
    BilibiliAssistantCandidate c,
  ) {
    final desc = c.item.desc.trim();
    final snippet = desc.length > 160 ? '${desc.substring(0, 160)}...' : desc;
    final hasVi =
        c.viTitle.trim().isNotEmpty && c.viTitle.trim() != c.item.title.trim();
    return {
      'index': c.displayIndex,
      'kind': c.kind.name,
      if (c.bvid.isNotEmpty) 'bvid': c.bvid,
      if (c.userResult != null) 'mid': c.userResult!.mid,
      if (c.pgcResult != null) 'seasonId': c.pgcResult!.seasonId,
      if (hasVi) 'viTitle': c.viTitle,
      'zhTitle': c.item.title,
      if (c.item.author.isNotEmpty) 'author': c.item.author,
      if (c.item.durationText.isNotEmpty) 'duration': c.item.durationText,
      if (c.item.durationSeconds > 0) 'durationSeconds': c.item.durationSeconds,
      if (c.item.publishedAtText.isNotEmpty) 'published': c.item.publishedAtText,
      if (c.item.viewCountText.isNotEmpty) 'views': c.item.viewCountText,
      if (c.item.danmakuText.isNotEmpty) 'danmaku': c.item.danmakuText,
      if (c.sourceBadge.isNotEmpty) 'badge': c.sourceBadge,
      if (c.item.styles.isNotEmpty) 'tags': c.item.styles.take(6).toList(),
      if (c.matchReason.isNotEmpty) 'fit': c.matchReason,
      if (snippet.isNotEmpty) 'descSnippet': snippet,
    };
  }

  BilibiliSearchReport? applyAiTranslatedTitlesToReport(
    BilibiliSearchReport report,
    Map<int, String> indexToViTitle,
  ) {
    if (indexToViTitle.isEmpty || report.candidates.isEmpty) return null;
    var changed = false;
    final updatedCandidates = <BilibiliAssistantCandidate>[];
    for (final cand in report.candidates) {
      final nextVi = indexToViTitle[cand.displayIndex]?.trim();
      if (nextVi != null &&
          nextVi.isNotEmpty &&
          nextVi != cand.viTitle &&
          !RegExp(r'[\u4e00-\u9fff]{2,}').hasMatch(nextVi)) {
        changed = true;
        _aiViTitleCache[cand.item.title.trim()] = nextVi;
        final updated = cand.copyWith(viTitle: nextVi);
        _candidateCache[updated.candidateKey] = updated;
        updatedCandidates.add(updated);
      } else {
        updatedCandidates.add(cand);
      }
    }
    if (!changed) return null;

    final updatedReport = report.copyWith(candidates: updatedCandidates);
    if (_lastSearchReport?.traceSummary == report.traceSummary &&
        _lastSearchReport?.candidates.length == report.candidates.length) {
      _lastSearchReport = updatedReport;
      for (var i = 0; i < _lastDisplayed.length; i++) {
        final m = updatedCandidates
            .where((c) => c.candidateKey == _lastDisplayed[i].candidateKey)
            .firstOrNull;
        if (m != null) _lastDisplayed[i] = m;
      }
    }
    return updatedReport;
  }

  static bool isUntranslatedTitle(BilibiliAssistantCandidate c) =>
      LiveReplyTitleSync.isUntranslatedTitle(c.viTitle, c.item.title);

  static String buildLiveTitleTranslationPrompt(
    List<BilibiliAssistantCandidate> targets, {
    bool includeShortSummary = false,
  }) {
    final buf = StringBuffer();
    buf.writeln(
      includeShortSummary
          ? 'Dịch TIÊU ĐỀ và TÓM TẮT NGẮN (1 câu) các mục Bilibili sau sang Tiếng Việt mượt mà (dùng Hán Việt cho phim/nhân vật, tự nhiên cho công nghệ/đời sống).'
          : 'Dịch TIÊU ĐỀ các mục Bilibili sau sang Tiếng Việt tự nhiên (dùng Hán Việt cho phim/nhân vật, dễ hiểu cho công nghệ/đời sống).',
    );
    buf.writeln('QUY TẮC CỨNG: TUYỆT ĐỐI CẤM Pinyin.');
    buf.writeln(
      includeShortSummary
          ? 'Định dạng trả về duy nhất từng dòng:\n#STT. <Tiêu đề Tiếng Việt> — <Tóm tắt 1 câu Tiếng Việt>'
          : 'Định dạng trả về duy nhất từng dòng:\n#STT. <Tiêu đề Tiếng Việt>',
    );
    for (final c in targets) {
      buf.write('#${c.displayIndex} | Gốc: ${c.item.title}');
      if (c.item.author.isNotEmpty) buf.write(' | UP: ${c.item.author}');
      if (includeShortSummary && c.item.desc.trim().isNotEmpty) {
        final d = c.item.desc.trim();
        buf.write(' | Mô tả: ${d.length > 130 ? "${d.substring(0, 130)}..." : d}');
      }
      buf.writeln();
    }
    return buf.toString();
  }

  String buildUiContextHeader() {
    final notes = <String>[];
    if (_currentLocks.aiAnimeOnly) {
      notes.add(
        'CHẾ ĐỘ LỌC: Chỉ Phim Hoạt Hình AI (content_focus="ai_anime", loại bỏ kiến thức/người thật/tiểu thuyết audio)',
      );
    }
    if (_currentLocks.partitionTid > 0) {
      final p = BilibiliPartition.byTid(_currentLocks.partitionTid);
      notes.add('PHÂN KHU ĐÃ CHỌN: tid=${_currentLocks.partitionTid} (${p?.viLabel ?? ""})');
    }
    if (_currentLocks.durationBucket > 0) {
      notes.add('THỜI LƯỢNG: ${durationLabel(_currentLocks.durationBucket)}');
    }
    if (_currentLocks.recencyBucket != 'any') {
      notes.add('NGÀY ĐĂNG: ${recencyLabel(_currentLocks.recencyBucket)}');
    }
    if (_currentLocks.sortOrder != 'totalrank') {
      notes.add('SẮP XẾP: ${_currentLocks.sortOrder}');
    }
    if (_currentLocks.lockedCount != null) {
      notes.add('SỐ LƯỢNG: ${_currentLocks.lockedCount} kết quả');
    }
    final taste = tasteService.cachedProfile;
    if (taste != null && taste.promptSummary.isNotEmpty) {
      notes.add('GU XEM CÁ NHÂN: ${taste.promptSummary}');
    }
    if (_currentLocks.pinnedKeys.isNotEmpty) {
      final pinned = _currentLocks.pinnedKeys.map((k) {
        final c = _candidateCache[k];
        if (c != null) {
          return '#${c.displayIndex} (key=$k, "${c.viTitle}" / ${c.item.title})';
        }
        return k;
      }).join('; ');
      notes.add('MỤC ĐANG GHIM: $pinned');
    }
    final activeSrt = activeSrtSession;
    if (activeSrt != null) {
      notes.add(
        'SRT ĐANG MỞ: bvid=${activeSrt.bvid} (${activeSrt.totalChunks} đoạn, ${activeSrt.sourceLabel})',
      );
    }
    if (notes.isEmpty) return '';
    return '[NGỮ CẢNH UI BILIBILI: ${notes.join(" | ")}]';
  }

  String decorateUserInput(String rawInput) {
    final clean = rawInput.trim();
    if (clean.isEmpty) return '';
    final header = buildUiContextHeader();
    if (header.isEmpty) return clean;
    return '$header\n$clean';
  }

  static bool looksLikeDiscoveryQuery(String rawInput) {
    final q = rawInput.trim().toLowerCase();
    if (q.isEmpty) return false;
    final asksExisting = RegExp(
      r'(?:#\d+|video\s*(?:số|thứ)\s*\d+|đoạn\s*(?:tiếp|sau|\d+)|tóm tắt|cốt truyện|nói gì|ở trên|đã tìm|tạo stt|xuất srt|stt|srt)',
    ).hasMatch(q);
    final hasSearchVerb = RegExp(
      r'(tìm|kiếm|gợi ý|đề xuất|muốn xem|cho\s+(?:mình|tôi|em)|bxh|bảng xếp hạng|xếp hạng|thịnh hành|trending|hot|top\s*\d*|kênh|up\s*chủ|hướng dẫn|review|so sánh|cách\s+làm|hợp gu|theo gu)',
    ).hasMatch(q);
    if (asksExisting && !hasSearchVerb) return false;
    return hasSearchVerb ||
        RegExp(r'[\u4e00-\u9fff]{2,}').hasMatch(rawInput);
  }

  static int? _detectMinDurationMinutesFromPrompt(String lower) {
    final hourMatch = RegExp(
      r'(?:trên|dài hơn|ít nhất|hơn|từ|>=)\s*(\d+)\s*(?:tiếng|giờ|h)\b',
    ).firstMatch(lower);
    if (hourMatch != null) {
      final h = int.tryParse(hourMatch.group(1) ?? '');
      if (h != null && h > 0) return h * 60;
    }
    final minMatch = RegExp(
      r'(?:trên|dài hơn|ít nhất|hơn|từ|>=)\s*(\d+)\s*(?:phút|p|min)\b',
    ).firstMatch(lower);
    if (minMatch != null) {
      final m = int.tryParse(minMatch.group(1) ?? '');
      if (m != null && m > 0) return m;
    }
    return null;
  }

  static String? _detectRecencyFromPrompt(String lower) {
    if (RegExp(r'(hôm nay|24\s*h|24\s*giờ|trong ngày)').hasMatch(lower)) {
      return '24h';
    }
    if (RegExp(r'(7\s*ngày|tuần này|tuần qua|1\s*tuần)').hasMatch(lower)) {
      return '7d';
    }
    if (RegExp(r'(30\s*ngày|tháng này|tháng qua|1\s*tháng|mới đăng|mới ra|gần đây)').hasMatch(lower)) {
      return '30d';
    }
    if (RegExp(r'(90\s*ngày|3\s*tháng)').hasMatch(lower)) {
      return '90d';
    }
    if (RegExp(r'(1\s*năm|năm nay)').hasMatch(lower)) {
      return '1y';
    }
    return null;
  }

  Future<BilibiliSearchReport?> autoSearchFallbackFromPrompt(
    String rawPrompt, {
    void Function(BilibiliSearchReport)? onSearchResultsUpdated,
  }) async {
    final clean = rawPrompt.trim();
    if (clean.isEmpty) return null;
    final lower = clean.toLowerCase();
    final limit = _resolveEffectiveLimit(null);

    if (RegExp(r'(bxh|xếp hạng|thịnh hành|hot|nổi bật|trending)').hasMatch(lower)) {
      await _handleExploreDiscovery(
        {
          'mode': lower.contains('xếp hạng') || lower.contains('bxh')
              ? 'ranking'
              : 'popular',
          'limit': limit,
        },
        onSearchResultsUpdated: onSearchResultsUpdated,
      );
      return _lastSearchReport;
    }

    if (RegExp(
      r'(hợp gu|theo gu|sở thích|hay xem|đã xem|đề xuất cho (?:mình|tôi|em)|gợi ý cho (?:mình|tôi|em))',
    ).hasMatch(lower) &&
        !RegExp(r'[\u4e00-\u9fff]{2,}').hasMatch(clean)) {
      await tasteService.getTasteProfile(cookie: _cookie);
      await _handleExploreDiscovery(
        {'mode': 'recommend', 'limit': limit},
        onSearchResultsUpdated: onSearchResultsUpdated,
      );
      return _lastSearchReport;
    }

    // Trích từ khóa tiếng Anh hoặc chữ Hán hoặc phrase tiếng Việt phổ biến
    final queries = <String>[];
    for (final m in RegExp(r'[\u4e00-\u9fff]{2,}').allMatches(clean)) {
      final token = m.group(0)!;
      if (!queries.contains(token)) queries.add(token);
    }

    const viMap = <(String, String, int)>[
      ('hoạt hình ai', 'AI动画', 0),
      ('phim ai', 'AI漫剧 一口气看完', 0),
      ('trọng sinh', '重生', 0),
      ('tu tiên', '修仙', 0),
      ('hướng dẫn', '教程', 36),
      ('review', '评测', 188),
      ('so sánh', '对比评测', 188),
      ('tài liệu', '纪录片', 177),
      ('công nghệ', '科技数码', 188),
      ('lập trình', '编程教程', 36),
      ('âm nhạc', '音乐', 3),
      ('game', '游戏', 4),
      ('nấu ăn', '美食教程', 211),
    ];

    int guessedTid = _currentLocks.partitionTid;
    for (final (vi, zh, tid) in viMap) {
      if (lower.contains(vi)) {
        if (!queries.contains(zh)) queries.add(zh);
        if (guessedTid == 0 && tid > 0) guessedTid = tid;
      }
    }

    if (queries.isEmpty) {
      final quotedMatch = RegExp(r'["“「『]([^"”」』]{2,40})["”」』]').firstMatch(clean);
      if (quotedMatch != null) {
        final phrase = quotedMatch.group(1)?.trim() ?? '';
        if (phrase.isNotEmpty) queries.add(phrase);
      }
    }

    if (queries.isEmpty) {
      await _handleExploreDiscovery(
        {'mode': 'popular', 'limit': limit},
        onSearchResultsUpdated: onSearchResultsUpdated,
      );
      return _lastSearchReport;
    }

    final minDurationMinutes = _detectMinDurationMinutesFromPrompt(lower);
    final recency = _detectRecencyFromPrompt(lower);
    final asksAiTutorial = RegExp(
      r'(hướng dẫn|cách làm|tự làm|tạo video|comfyui|prompt|công cụ|phần mềm)',
    ).hasMatch(lower);
    final wantsWatchAiAnime =
        _currentLocks.aiAnimeOnly ||
        (RegExp(
              r'(hoạt hình ai|phim ai|anime ai|ai漫剧|ai动画|ai动漫|truyện tranh động)',
            ).hasMatch(lower) &&
            !asksAiTutorial);
    final isExact = RegExp(
      r'(tìm\s*phim|tên\s*gốc|bản\s*trung|bản\s*gốc|phim\s*tên|đúng\s*phim|tìm\s*đúng)',
    ).hasMatch(lower) ||
        clean.contains('"') ||
        clean.contains('“');
    final wantsNewestOrder =
        RegExp(r'(mới đăng|mới nhất|mới ra)').hasMatch(lower);

    await _handleSearchVideos(
      {
        'search_mode': isExact ? 'exact' : 'discover',
        if (wantsWatchAiAnime) 'content_focus': 'ai_anime',
        if (wantsWatchAiAnime)
          'exclude_keywords': const [
            '教程',
            '教学',
            'ComfyUI',
            '即梦',
            '变现',
            '有声小说',
            '听书',
            '广播剧',
            '真人',
          ],
        'queries_narrow_to_broad': queries.take(4).toList(),
        'target_keywords': queries.take(4).toList(),
        if (guessedTid > 0) 'partition_tid': guessedTid,
        'min_duration_minutes': ?minDurationMinutes,
        'recency': ?recency,
        if (wantsNewestOrder && _currentLocks.sortOrder == 'totalrank')
          'order': 'pubdate',
        'limit': limit,
      },
      onSearchResultsUpdated: onSearchResultsUpdated,
    );
    return _lastSearchReport;
  }

  List<Map<String, dynamic>> buildCompressedSnapshotTurns(
    List<({bool isUser, String text})> recentDialogue,
  ) {
    final turns = <Map<String, dynamic>>[];
    final lines = <String>[
      'Ngữ cảnh Bilibili đang giữ từ phiên trước (dùng tiếp, không cần chào lại từ đầu):',
    ];
    if (_currentLocks.aiAnimeOnly) {
      lines.add('- Chế độ lọc: Chỉ Phim Hoạt Hình AI (bỏ kiến thức/người thật/audio)');
    }
    if (_currentLocks.partitionTid > 0) {
      lines.add('- Phân khu khóa: tid=${_currentLocks.partitionTid}');
    }
    if (_currentLocks.durationBucket > 0) {
      lines.add('- Thời lượng: ${durationLabel(_currentLocks.durationBucket)}');
    }
    if (_currentLocks.recencyBucket != 'any') {
      lines.add('- Ngày đăng: ${recencyLabel(_currentLocks.recencyBucket)}');
    }
    if (_currentLocks.sortOrder != 'totalrank') {
      lines.add('- Sắp xếp: ${_currentLocks.sortOrder}');
    }
    final taste = tasteService.cachedProfile;
    if (taste != null && taste.promptSummary.isNotEmpty) {
      lines.add('- Gu xem cá nhân: ${taste.promptSummary}');
    }
    if (_lastDisplayed.isNotEmpty) {
      lines.add('- Thẻ đang hiển thị:');
      for (final c in _lastDisplayed) {
        lines.add(
          '  #${c.displayIndex} | ${c.candidateKey} | "${c.viTitle}" (${c.item.title}) | ${c.item.author}',
        );
      }
    }
    if (activeSrtSession != null) {
      final s = activeSrtSession!;
      lines.add(
        '- SRT đang mở: ${s.bvid} p${s.pageIndex} (${s.totalChunks} đoạn, ${s.sourceLabel})',
      );
    }

    turns.add({
      'role': 'user',
      'parts': [
        {'text': lines.join('\n')},
      ],
    });
    turns.add({
      'role': 'model',
      'parts': [
        {'text': 'Đã nắm rõ ngữ cảnh Bilibili hiện tại, sẵn sàng hỗ trợ tiếp.'},
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
