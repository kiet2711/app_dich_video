import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'multi_thread_downloader.dart';

import '../../data/model/subtitle_document.dart';
import '../../data/model/subtitle_item.dart';

class BilibiliTarget {
  final String? bvid;
  final String? aid;
  final int pageIndex;
  final String rawUrl;

  const BilibiliTarget({
    this.bvid,
    this.aid,
    this.pageIndex = 1,
    required this.rawUrl,
  });
}

class BilibiliPageInfo {
  final int page;
  final int cid;
  final String part;
  final int durationSeconds;

  const BilibiliPageInfo({
    required this.page,
    required this.cid,
    required this.part,
    required this.durationSeconds,
  });
}

class BilibiliUgcEpisode {
  final int id;
  final int aid;
  final int cid;
  final String title;
  final String bvid;
  final String cover;
  final int durationSeconds;

  const BilibiliUgcEpisode({
    required this.id,
    required this.aid,
    required this.cid,
    required this.title,
    required this.bvid,
    this.cover = '',
    this.durationSeconds = 0,
  });

  String get targetPlayUrl => 'https://www.bilibili.com/video/$bvid';
}

class BilibiliUgcSeason {
  final int id;
  final String title;
  final String cover;
  final int epCount;
  final List<BilibiliUgcEpisode> episodes;

  const BilibiliUgcSeason({
    required this.id,
    required this.title,
    this.cover = '',
    this.epCount = 0,
    this.episodes = const [],
  });
}

class BilibiliVideoDetails {
  final String bvid;
  final int aid;
  final int cid;
  final String title;
  final String? rawTitle;
  final String? coverUrl;
  final int durationSeconds;
  final List<BilibiliPageInfo> pages;
  final int selectedPageIndex;

  final String author;
  final int ownerMid;
  final String? upFace;
  final String viewCountText;
  final String danmakuText;
  final int? pubdate;
  final String? desc;
  final BilibiliUgcSeason? ugcSeason;

  const BilibiliVideoDetails({
    required this.bvid,
    required this.aid,
    required this.cid,
    required this.title,
    this.rawTitle,
    this.coverUrl,
    required this.durationSeconds,
    this.pages = const [],
    this.selectedPageIndex = 1,
    this.author = '',
    this.ownerMid = 0,
    this.upFace,
    this.viewCountText = '',
    this.danmakuText = '',
    this.pubdate,
    this.desc,
    this.ugcSeason,
  });
}

class BilibiliSubtitleInfo {
  final String language;
  final String languageName;
  final bool isAi;
  final String url;

  const BilibiliSubtitleInfo({
    required this.language,
    required this.languageName,
    required this.isAi,
    required this.url,
  });
}

class BilibiliDashStream {
  final String videoUrl;
  final String audioUrl;
  final Map<String, String> headers;
  final int quality;

  const BilibiliDashStream({
    required this.videoUrl,
    required this.audioUrl,
    required this.headers,
    this.quality = 64,
  });
}

class BilibiliSubtitleLoginRequiredException implements Exception {
  const BilibiliSubtitleLoginRequiredException();

  @override
  String toString() =>
      'P này có phụ đề nhưng Bilibili yêu cầu đăng nhập. Hãy nhập SESSDATA trong Cài đặt.';
}

class BilibiliAnimeItem {
  final String title;
  final String cover;
  final String? bvid;
  final int? seasonId;
  final int? epId;
  final String badge;
  final String desc;
  final String viewCountText;
  final String followCountText;
  final String ratingText;
  final String indexShow;
  final String author;
  final List<String> styles;
  final int durationSeconds;
  final String durationText;
  final String upFace;
  final String danmakuText;
  final String likeCountText;
  final int pubdate;
  final int typeId;

  const BilibiliAnimeItem({
    required this.title,
    required this.cover,
    this.bvid,
    this.seasonId,
    this.epId,
    this.badge = '',
    this.desc = '',
    this.viewCountText = '',
    this.followCountText = '',
    this.ratingText = '',
    this.indexShow = '',
    this.author = '',
    this.styles = const [],
    this.durationSeconds = 0,
    this.durationText = '',
    this.upFace = '',
    this.danmakuText = '',
    this.likeCountText = '',
    this.pubdate = 0,
    this.typeId = 0,
  });

  String get publishedAtText => formatPubdate(pubdate);

  static String formatPubdate(int pubdateSec) {
    if (pubdateSec <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(pubdateSec * 1000);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.isNegative || diff.inMinutes < 60) {
      final mins = diff.inMinutes <= 0 ? 1 : diff.inMinutes;
      return '$mins phút trước';
    }
    if (diff.inHours < 24) {
      return '${diff.inHours} giờ trước';
    }
    if (diff.inDays < 30) {
      return '${diff.inDays} ngày trước';
    }
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
  }

  static String formatDuration(int seconds) {
    if (seconds <= 0) return '';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    final sStr = s.toString().padLeft(2, '0');
    final mStr = m.toString().padLeft(2, '0');
    if (h > 0) {
      return '$h:$mStr:$sStr';
    } else {
      return '$mStr:$sStr';
    }
  }

  String get targetPlayUrl {
    if (bvid != null && bvid!.isNotEmpty) {
      return 'https://www.bilibili.com/video/$bvid';
    }
    if (epId != null && epId! > 0) {
      return 'https://www.bilibili.com/bangumi/play/ep$epId';
    }
    if (seasonId != null && seasonId! > 0) {
      return 'https://www.bilibili.com/bangumi/play/ss$seasonId';
    }
    return '';
  }
}

class BilibiliTimelineDay {
  final int dayOfWeek; // 1 = Thứ Hai, 7 = Chủ Nhật
  final String dayName;
  final String dateText;
  final bool isToday;
  final List<BilibiliAnimeItem> episodes;

  const BilibiliTimelineDay({
    required this.dayOfWeek,
    required this.dayName,
    required this.dateText,
    this.isToday = false,
    required this.episodes,
  });
}

class BilibiliCommentItem {
  final int rpid;
  final int oid;
  final int mid;
  final String uname;
  final String avatar;
  final int level;
  final String message;
  final int ctime;
  final String timeText;
  final int likeCount;
  final int replyCount;
  final List<BilibiliCommentItem> subReplies;

  const BilibiliCommentItem({
    required this.rpid,
    required this.oid,
    required this.mid,
    required this.uname,
    required this.avatar,
    this.level = 0,
    required this.message,
    required this.ctime,
    this.timeText = '',
    this.likeCount = 0,
    this.replyCount = 0,
    this.subReplies = const [],
  });
}

class BilibiliCommentResult {
  final int totalCount;
  final List<BilibiliCommentItem> comments;

  const BilibiliCommentResult({
    required this.totalCount,
    required this.comments,
  });
}

class BilibiliUploaderProfile {
  final int mid;
  final String name;
  final String face;
  final String sign;
  final int fans;
  final String fansText;
  final int videoCount;
  final bool isFollowing;
  final int level;

  const BilibiliUploaderProfile({
    required this.mid,
    required this.name,
    this.face = '',
    this.sign = '',
    this.fans = 0,
    this.fansText = '',
    this.videoCount = 0,
    this.isFollowing = false,
    this.level = 0,
  });
}

class BilibiliUserProfile {
  final int mid;
  final String uname;
  final String avatar;
  final bool isLogin;
  final bool isVip;
  final String vipLabel;
  final int level;

  const BilibiliUserProfile({
    this.mid = 0,
    this.uname = '',
    this.avatar = '',
    this.isLogin = false,
    this.isVip = false,
    this.vipLabel = '',
    this.level = 0,
  });
}

class BilibiliQrCodeInfo {
  final String url;
  final String qrcodeKey;

  const BilibiliQrCodeInfo({
    required this.url,
    required this.qrcodeKey,
  });
}

class BilibiliQrPollResult {
  final int code; // 0 = Thành công, 86101 = Chưa quét, 86090 = Đã quét chờ xác nhận, 86038 = Hết hạn
  final String message;
  final String? sessData;
  final String? biliJct;
  final String? dedeUserId;

  const BilibiliQrPollResult({
    required this.code,
    required this.message,
    this.sessData,
    this.biliJct,
    this.dedeUserId,
  });

  bool get isSuccess => code == 0 && sessData != null && sessData!.isNotEmpty;
  bool get isPending => code == 86101 || code == 86090;
  bool get isExpired => code == 86038;
}

class BilibiliPartition {
  final int tid;
  final String zhName;
  final String viLabel;
  final List<String> aliases;

  const BilibiliPartition({
    required this.tid,
    required this.zhName,
    required this.viLabel,
    this.aliases = const [],
  });

  static const List<BilibiliPartition> catalog = [
    BilibiliPartition(tid: 0, zhName: '全区', viLabel: 'Tất cả', aliases: ['all', 'tat ca']),
    BilibiliPartition(tid: 36, zhName: '知识', viLabel: 'Kiến thức / Học tập', aliases: ['knowledge', 'kien thuc', 'hoc tap', 'giao duc', 'khoa hoc']),
    BilibiliPartition(tid: 188, zhName: '科技', viLabel: 'Công nghệ / Đồ số', aliases: ['tech', 'cong nghe', 'so', 'ai', 'pc', 'dien thoai', 'digital']),
    BilibiliPartition(tid: 4, zhName: '游戏', viLabel: 'Game', aliases: ['game', 'gaming', 'tro choi']),
    BilibiliPartition(tid: 160, zhName: '生活', viLabel: 'Đời sống / Vlog / Mẹo hay', aliases: ['life', 'doi song', 'vlog']),
    BilibiliPartition(tid: 3, zhName: '音乐', viLabel: 'Âm nhạc', aliases: ['music', 'am nhac', 'nhac']),
    BilibiliPartition(tid: 181, zhName: '影视', viLabel: 'Phim ảnh / Review phim', aliases: ['film', 'phim anh', 'review phim']),
    BilibiliPartition(tid: 1, zhName: '动画', viLabel: 'Hoạt hình / AMV', aliases: ['animation', 'hoat hinh', 'amv', 'mad']),
    BilibiliPartition(tid: 167, zhName: '国创', viLabel: 'Quốc sáng / Donghua', aliases: ['guochuang', 'donghua', 'hoat hinh trung']),
    BilibiliPartition(tid: 13, zhName: '番剧', viLabel: 'Anime / Phiên kịch', aliases: ['anime', 'bangumi', 'nhat']),
    BilibiliPartition(tid: 177, zhName: '纪录片', viLabel: 'Phim tài liệu', aliases: ['documentary', 'tai lieu']),
    BilibiliPartition(tid: 23, zhName: '电影', viLabel: 'Phim điện ảnh', aliases: ['movie', 'dien anh', 'chieu rap']),
    BilibiliPartition(tid: 11, zhName: '电视剧', viLabel: 'Phim truyền hình', aliases: ['tv', 'truyen hinh', 'phim bo']),
    BilibiliPartition(tid: 211, zhName: '美食', viLabel: 'Ẩm thực / Nấu ăn', aliases: ['food', 'am thuc', 'nau an']),
    BilibiliPartition(tid: 217, zhName: '动物圈', viLabel: 'Động vật / Thú cưng', aliases: ['animal', 'dong vat', 'thu cung']),
    BilibiliPartition(tid: 234, zhName: '运动', viLabel: 'Thể thao', aliases: ['sport', 'the thao', 'gym']),
    BilibiliPartition(tid: 119, zhName: '鬼畜', viLabel: 'Quỷ súc / Chế hài', aliases: ['kichiku', 'quy suc']),
    BilibiliPartition(tid: 129, zhName: '舞蹈', viLabel: 'Vũ đạo / Nhảy', aliases: ['dance', 'vu dao', 'nhay']),
    BilibiliPartition(tid: 155, zhName: '时尚', viLabel: 'Thời trang / Làm đẹp', aliases: ['fashion', 'thoi trang', 'lam dep']),
    BilibiliPartition(tid: 5, zhName: '娱乐', viLabel: 'Giải trí / Showbiz', aliases: ['entertainment', 'giai tri']),
    BilibiliPartition(tid: 202, zhName: '资讯', viLabel: 'Tin tức / Thời sự', aliases: ['news', 'tin tuc', 'thoi su']),
  ];

  static BilibiliPartition? byTid(int tid) {
    for (final p in catalog) {
      if (p.tid == tid) return p;
    }
    return null;
  }

  static BilibiliPartition resolve(dynamic rawTidOrName) {
    if (rawTidOrName is int) {
      return byTid(rawTidOrName) ?? catalog.first;
    }
    final text = (rawTidOrName ?? '').toString().trim().toLowerCase();
    final asInt = int.tryParse(text);
    if (asInt != null) {
      return byTid(asInt) ?? catalog.first;
    }
    if (text.isEmpty) return catalog.first;
    // Pass 1: exact match trước để tránh từ ngắn ('ai', 'so', 'tv') khớp nhầm chuỗi dài ('tai lieu')
    for (final p in catalog) {
      if (p.zhName == text ||
          p.viLabel.toLowerCase() == text ||
          p.aliases.contains(text)) {
        return p;
      }
    }
    // Pass 2: khớp nhãn tiếng Việt hoặc khớp theo ranh giới từ đối với alias
    for (final p in catalog) {
      if (text.length >= 2 && p.viLabel.toLowerCase().contains(text)) {
        return p;
      }
      if (p.aliases.any(
        (a) => RegExp(
          '(?:^|[^a-z0-9])${RegExp.escape(a)}(?:\$|[^a-z0-9])',
        ).hasMatch(text),
      )) {
        return p;
      }
    }
    return catalog.first;
  }
}

/// Bộ phân loại nội dung giúp tách **Phim hoạt hình AI / AI漫剧 xem trực tiếp**
/// khỏi các kết quả nhiễu thường gặp trên Bilibili:
/// - Video kiến thức / dạy làm AI / bán khóa học / công cụ (`教程`, `全流程`, `ComfyUI`, ...)
/// - Tiểu thuyết audio / nghe truyện / kịch truyền thanh (`有声小说`, `听书`, `广播剧`, `小说推文`)
/// - Phim người thật đóng / AI người thật (`真人`, `实拍`, `真人短剧`, ...)
class BilibiliContentClassifier {
  const BilibiliContentClassifier._();

  static const Set<int> animationTypeIds = {
    1,
    24,
    25,
    27,
    47,
    167,
    153,
    168,
    195,
    13,
    32,
    33,
  };

  static const Set<String> animationTypenames = {
    '动画',
    '短片·手书',
    '短片·手书·配音',
    'MAD·AMV',
    'MMD·3D',
    '同人·手书',
    '综合',
    '国创',
    '国产动画',
    '国产原创相关',
    '番剧',
    '完结动画',
    '连载动画',
    '动态漫·广播剧',
  };

  static const Set<String> nonAnimationTypenames = {
    '科技',
    '数码',
    '人工智能',
    '电脑技术',
    '软件应用',
    '计算机技术',
    '机械',
    '电子',
    '知识',
    '科学科普',
    '社科·法律·心理',
    '人文历史',
    '财经商业',
    '校园学习',
    '职业职场',
    '野生技术协会',
    '生活',
    '日常',
    '搞笑',
    '家居房产',
    '手工',
    '绘画',
    '出行',
    '娱乐',
    '明星',
    '综艺',
    '短剧',
    '小剧场',
    '影视杂谈',
    '影视剪辑',
    '预告·资讯',
    '资讯',
    '热点',
    '环球',
    '社会',
    '美食',
    '时尚',
    '运动',
    '汽车',
    '三农',
    '音乐',
    '有声书',
  };

  static const Set<String> knowledgeTechTypenames = {
    '科技',
    '数码',
    '人工智能',
    '电脑技术',
    '软件应用',
    '计算机技术',
    '知识',
    '科学科普',
    '校园学习',
    '职业职场',
    '野生技术协会',
    '财经商业',
    '人文历史',
  };

  static final RegExp _tutorialRegex = RegExp(
    r'(教程|教学|全流程|保姆级|喂饭|手把手|零基础|从零开始|从零|变现|月入|副业|起号|接单|提示词|prompt|comfyui|工作流|workflow|怎么制作|怎么做|如何制作|如何用ai|实操|参数|源码|赚钱|带货|拆解|教程向|教学向|评测|对比评测|软件|工具推荐|模型部署|本地部署|开源模型)',
    caseSensitive: false,
  );

  static final RegExp _aiToolOnlyRegex = RegExp(
    r'(即梦|可灵|runway|midjourney|stable\s*diffusion|seedance|liblib|libtv|vidu|pika)',
    caseSensitive: false,
  );

  static final RegExp _audioNovelRegex = RegExp(
    r'(有声小说|有声书|听书|广播剧|小说推文|推文|纯音频|睡前听|有声读物|有声剧|全本有声|有声播讲|多人有声|评书|相声|电台|助眠|播客|配音秀|有声漫)',
    caseSensitive: false,
  );

  static final RegExp _liveActionCompoundRegex = RegExp(
    r'(真人短剧|真人版|真人ai|ai真人|实拍|微电影|写实真人|实景拍摄|探店|采访|日常vlog|演员演技)',
    caseSensitive: false,
  );

  static final RegExp _pureAnimeTitleRegex = RegExp(
    r'(ai动画|ai动漫|动态漫|动态漫画|沙雕动画|国产动画|国漫)',
    caseSensitive: false,
  );

  static final RegExp _watchableEpisodeRegex = RegExp(
    r'(一口气看完|漫剧合集|动画合集|全集|合集|完整版|第[0-9一二三四五六七八九十]+集|番外|连载)',
    caseSensitive: false,
  );

  static String _textBlob(BilibiliAnimeItem item, {bool includeDesc = true}) {
    final tags = item.styles.join(' ');
    if (!includeDesc) return '${item.title} $tags ${item.badge}'.toLowerCase();
    return '${item.title} $tags ${item.badge} ${item.desc}'.toLowerCase();
  }

  static bool isTutorialOrCourse(BilibiliAnimeItem item) {
    final titleTags = _textBlob(item, includeDesc: false);
    if (_tutorialRegex.hasMatch(titleTags)) return true;

    final b = item.badge.trim();
    if (knowledgeTechTypenames.contains(b)) {
      // Video nằm thẳng trong phân khu Kiến thức/Công nghệ/AI Tool nhưng lại thiếu dấu hiệu phim hoạt hình thuần -> coi là kiến thức/hướng dẫn
      if (!_pureAnimeTitleRegex.hasMatch(titleTags) ||
          _aiToolOnlyRegex.hasMatch(titleTags)) {
        return true;
      }
    }
    if (_aiToolOnlyRegex.hasMatch(item.title) &&
        !_pureAnimeTitleRegex.hasMatch(item.title) &&
        !_watchableEpisodeRegex.hasMatch(item.title)) {
      return true;
    }
    return false;
  }

  static bool isAudioNovelOrPodcast(BilibiliAnimeItem item) {
    final blob = _textBlob(item);
    final b = item.badge.trim();
    if (b == '有声书') return true;
    // Phân khu '动态漫·广播剧' có cả Động thái mạn lẫn Kịch truyền thanh -> chỉ loại nếu tiêu đề/tag/mô tả nhắc audio/radio/thính thư
    if (b == '动态漫·广播剧') {
      final nonBadge = '${item.title} ${item.styles.join(" ")} ${item.desc}'.toLowerCase();
      return _audioNovelRegex.hasMatch(nonBadge);
    }
    return _audioNovelRegex.hasMatch(blob);
  }

  static bool isLiveAction(BilibiliAnimeItem item) {
    final b = item.badge.trim();
    if (const {'短剧', '小剧场', '明星', '综艺', '生活', '日常', '美食', '时尚', '汽车', '三农', '运动'}.contains(b)) {
      return true;
    }
    final titleTags = _textBlob(item, includeDesc: false);
    if (_liveActionCompoundRegex.hasMatch(titleTags)) return true;
    for (final m in RegExp('真人').allMatches(titleTags)) {
      final before = m.start >= 2
          ? titleTags.substring(m.start - 2, m.start)
          : titleTags.substring(0, m.start);
      if (!before.endsWith('非') && !before.endsWith('不是')) {
        return true;
      }
    }
    return false;
  }

  /// Trả về `true` nếu [item] là **phim hoạt hình / AI漫剧 / AI动画** để XEM,
  /// không phải kiến thức/dạy làm AI, không phải người thật và không phải tiểu thuyết audio.
  static bool isCleanWatchableAiAnime(BilibiliAnimeItem item) {
    if (isTutorialOrCourse(item)) return false;
    if (isAudioNovelOrPodcast(item)) return false;
    if (isLiveAction(item)) return false;

    final b = item.badge.trim();
    if (b.isNotEmpty && nonAnimationTypenames.contains(b)) {
      // Cho qua rất chặt chỉ khi tiêu đề đích thị ghi AI动画/AI动漫/动态漫 (không kèm nhiễu đã lọc ở trên)
      return _pureAnimeTitleRegex.hasMatch(item.title);
    }
    return true;
  }

  /// Chấm điểm ưu tiên cho kết quả thuộc thể loại phim hoạt hình AI xem trực tiếp.
  static double scoreWatchableAiAnime(BilibiliAnimeItem item) {
    if (!isCleanWatchableAiAnime(item)) return -500.0;
    double score = 0;
    final b = item.badge.trim();
    if (animationTypenames.contains(b) ||
        animationTypeIds.contains(item.typeId)) {
      score += 32.0;
    }
    final titleTags = _textBlob(item, includeDesc: false);
    if (RegExp(r'(ai动画|ai动漫)').hasMatch(titleTags)) score += 26.0;
    if (RegExp(r'(动态漫|动态漫画|ai漫剧|ai短片|沙雕动画)').hasMatch(titleTags)) {
      score += 18.0;
    }
    if (_watchableEpisodeRegex.hasMatch(titleTags)) score += 14.0;
    return score;
  }
}

class BilibiliUserSearchResult {
  final int mid;
  final String uname;
  final String upic;
  final String usign;
  final int fans;
  final String fansText;
  final int videos;
  final bool isOfficial;
  final String officialDesc;

  const BilibiliUserSearchResult({
    required this.mid,
    required this.uname,
    this.upic = '',
    this.usign = '',
    this.fans = 0,
    this.fansText = '',
    this.videos = 0,
    this.isOfficial = false,
    this.officialDesc = '',
  });
}

class BilibiliPgcSearchResult {
  final int seasonId;
  final int mediaId;
  final int? firstEpId;
  final String title;
  final String cover;
  final String badge;
  final String areas;
  final String styles;
  final String indexShow;
  final String score;
  final String desc;
  final int seasonType;

  const BilibiliPgcSearchResult({
    required this.seasonId,
    this.mediaId = 0,
    this.firstEpId,
    required this.title,
    this.cover = '',
    this.badge = '',
    this.areas = '',
    this.styles = '',
    this.indexShow = '',
    this.score = '',
    this.desc = '',
    this.seasonType = 0,
  });

  BilibiliAnimeItem toAnimeItem() {
    return BilibiliAnimeItem(
      title: title,
      cover: cover,
      seasonId: seasonId > 0 ? seasonId : null,
      epId: (firstEpId != null && firstEpId! > 0) ? firstEpId : null,
      badge: badge,
      desc: desc,
      ratingText: score,
      indexShow: indexShow,
      styles: styles
          .split(RegExp(r'[/,\s·]+'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
    );
  }
}

class BilibiliResolver {
  static const _userAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1';
  static const _referer = 'https://www.bilibili.com/';
  static const _mixinKeyEncTab = <int>[
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
    37,
    48,
    7,
    16,
    24,
    55,
    40,
    61,
    26,
    17,
    0,
    1,
    60,
    51,
    30,
    4,
    22,
    25,
    54,
    21,
    56,
    59,
    6,
    63,
    57,
    62,
    11,
    36,
    20,
    34,
    44,
    52,
  ];

  final Dio dio;
  static String? _cachedImgKey;
  static String? _cachedSubKey;
  static DateTime? _wbiFetchedAt;
  static final Map<String, BilibiliVideoDetails> _videoDetailsCache = {};
  static final Map<String, List<String>> _muxedUrlsCache = {};

  BilibiliResolver({Dio? dio})
    : dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 45),
              followRedirects: true,
            ),
          );

  static bool isBilibiliUrl(String input) {
    final value = input.trim();
    final lower = value.toLowerCase();
    return lower.contains('bilibili.com') ||
        lower.contains('b23.tv') ||
        lower.contains('bilivideo.com') ||
        RegExp(r'(?:^|[\/\?&=#])BV1[0-9a-zA-Z]{9}(?:[\/\?&=#]|$)', caseSensitive: false).hasMatch(value) ||
        RegExp(r'(?:^|[\/\?&=#])av\d+(?:[\/\?&=#]|$)', caseSensitive: false).hasMatch(value);
  }

  static bool isBilibiliPageUrl(String input) {
    final lower = input.trim().toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return false;
    }
    // Không nhận nhầm các link CDN stream là link trang video Bilibili
    if (lower.contains('bilivideo.com') ||
        lower.contains('biliapi') ||
        lower.contains('akamaized.net') ||
        lower.contains('.m4s') ||
        lower.contains('.mp4')) {
      return false;
    }
    return isBilibiliUrl(input);
  }

  static const _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  static Map<String, String> requestHeaders([String cookie = '']) {
    final trimmed = cookie.trim();
    final sessData = trimmed.isEmpty
        ? ''
        : trimmed.contains('SESSDATA=')
        ? trimmed
        : 'SESSDATA=$trimmed';
    final defaultCookie =
        'CURRENT_FNVAL=4048; b_nut=${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final finalCookie =
        sessData.isEmpty ? defaultCookie : '$sessData; $defaultCookie';
    return {
      'User-Agent': _desktopUserAgent,
      'Referer': _referer,
      'Origin': 'https://www.bilibili.com',
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Cookie': finalCookie,
    };
  }

  static Map<String, String> streamHeaders([String cookie = '']) {
    final trimmed = cookie.trim();
    final sessData = trimmed.isEmpty
        ? ''
        : trimmed.contains('SESSDATA=')
        ? trimmed
        : 'SESSDATA=$trimmed';
    final buvid = 'buvid3_infoc_${DateTime.now().millisecondsSinceEpoch}';
    final defaultCookie =
        'buvid3=$buvid; b_nut=${DateTime.now().millisecondsSinceEpoch ~/ 1000}; CURRENT_FNVAL=4048';
    final finalCookie =
        sessData.isEmpty ? defaultCookie : '$sessData; $defaultCookie';
    return {
      'User-Agent': _userAgent,
      'Referer': _referer,
      'Origin': 'https://www.bilibili.com',
      'Cookie': finalCookie,
    };
  }

  Future<BilibiliTarget> resolveUrl(String input) async {
    var target =
        RegExp(r'https?://[^\s]+').firstMatch(input.trim())?.group(0) ??
        input.trim();

    // Lưu lại số trang nếu đã được chỉ định trong input URL ban đầu (vd: b23.tv/xxx?p=2 hoặc input_p=2)
    final inputPage = int.tryParse(
      RegExp(r'[?&]p=(\d+)', caseSensitive: false).firstMatch(input)?.group(1) ??
      RegExp(r'(?:index_|/p)(\d+)', caseSensitive: false).firstMatch(input)?.group(1) ??
      '',
    );

    if (target.toLowerCase().contains('b23.tv')) {
      final response = await dio.get<dynamic>(
        target,
        options: Options(
          headers: {'User-Agent': _userAgent},
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      target = response.realUri.toString();
    }

    final bvid = RegExp(
      r'(?:^|[\/\?&=#])(BV1[0-9a-zA-Z]{9})(?:[\/\?&=#]|$)',
      caseSensitive: false,
    ).firstMatch(target)?.group(1);
    final aid = RegExp(
      r'(?:^|[\/\?&=#])av(\d+)(?:[\/\?&=#]|$)',
      caseSensitive: false,
    ).firstMatch(target)?.group(1);
    final page = inputPage ??
        int.tryParse(
          RegExp(
            r'[?&]p=(\d+)',
            caseSensitive: false,
          ).firstMatch(target)?.group(1) ??
          RegExp(
            r'(?:index_|/p)(\d+)',
            caseSensitive: false,
          ).firstMatch(target)?.group(1) ??
          '1',
        ) ??
        1;
    var resolvedBvid = bvid;
    var resolvedAid = aid;

    if (resolvedBvid == null && resolvedAid == null) {
      final epMatch = RegExp(r'(?:^|[\/\?&=#])ep(\d+)(?:[\/\?&=#]|$)', caseSensitive: false).firstMatch(target);
      final ssMatch = RegExp(r'(?:^|[\/\?&=#])ss(\d+)(?:[\/\?&=#]|$)', caseSensitive: false).firstMatch(target);
      if (epMatch != null || ssMatch != null) {
        final epId = epMatch?.group(1);
        final ssId = ssMatch?.group(1);
        try {
          final queryParam = epId != null ? 'ep_id=$epId' : 'season_id=$ssId';
          final response = await dio.get<Map<String, dynamic>>(
            'https://api.bilibili.com/pgc/view/web/season?$queryParam',
            options: Options(headers: requestHeaders()),
          );
          final result = response.data?['result'];
          if (result is Map<String, dynamic>) {
            final episodes = (result['episodes'] as List<dynamic>? ?? const []);
            Map<String, dynamic>? matchedEp;
            if (epId != null) {
              matchedEp = episodes.firstWhere(
                (e) => e is Map<String, dynamic> && e['id']?.toString() == epId,
                orElse: () => episodes.isNotEmpty ? episodes.first as Map<String, dynamic> : <String, dynamic>{},
              ) as Map<String, dynamic>?;
            } else {
              matchedEp = episodes.isNotEmpty ? episodes.first as Map<String, dynamic> : null;
            }
            resolvedBvid = matchedEp?['bvid']?.toString();
            resolvedAid = matchedEp?['aid']?.toString();
          }
        } catch (_) {}
      }
    }

    if (resolvedBvid == null && resolvedAid == null) {
      throw FormatException('Không tìm thấy mã BV/av/ep/ss trong link Bilibili.');
    }

    final canonicalTarget = resolvedBvid != null
        ? 'https://www.bilibili.com/video/$resolvedBvid?p=$page'
        : (resolvedAid != null ? 'https://www.bilibili.com/video/av$resolvedAid?p=$page' : target);

    return BilibiliTarget(
      bvid: resolvedBvid,
      aid: resolvedAid,
      pageIndex: page,
      rawUrl: canonicalTarget,
    );
  }

  Future<BilibiliVideoDetails> getVideoDetails(
    BilibiliTarget target, [
    String cookie = '',
  ]) async {
    final cacheKey = target.bvid != null ? '${target.bvid}_p${target.pageIndex}' : target.rawUrl;
    if (_videoDetailsCache.containsKey(cacheKey)) {
      return _videoDetailsCache[cacheKey]!;
    }
    final params = <String, String>{};
    if (target.bvid != null) {
      params['bvid'] = target.bvid!;
    } else if (target.aid != null) {
      params['aid'] = target.aid!;
    }
    final data = await _getWbiJson(
      'https://api.bilibili.com/x/web-interface/wbi/view',
      params,
      cookie,
    );
    final rawPages = (data['pages'] as List<dynamic>? ?? const []);
    final pages = <BilibiliPageInfo>[];
    var cid = (data['cid'] as num?)?.toInt() ?? 0;
    var pageDuration = 0;
    var partTitle = '';

    for (final raw in rawPages) {
      if (raw is! Map<String, dynamic>) continue;
      final pNum = (raw['page'] as num?)?.toInt() ?? 1;
      final pCid = (raw['cid'] as num?)?.toInt() ?? 0;
      final pPart = raw['part']?.toString() ?? '';
      final pDuration = (raw['duration'] as num?)?.toInt() ?? 0;

      pages.add(
        BilibiliPageInfo(
          page: pNum,
          cid: pCid,
          part: pPart,
          durationSeconds: pDuration,
        ),
      );

      if (pNum == target.pageIndex) {
        cid = pCid > 0 ? pCid : cid;
        pageDuration = pDuration;
        partTitle = pPart;
      }
    }

    if (cid == 0 && pages.isNotEmpty) {
      cid = pages.first.cid;
      pageDuration = pages.first.durationSeconds;
      partTitle = pages.first.part;
    }
    if (cid == 0) throw StateError('Bilibili không trả CID của video.');

    final mainTitle = data['title']?.toString() ?? 'Video Bilibili';
    final fullTitle =
        (pages.length > 1 && partTitle.isNotEmpty && !mainTitle.contains(partTitle))
            ? '$mainTitle - P${target.pageIndex} ($partTitle)'
            : mainTitle;

    var coverUrl = data['pic']?.toString().trim();
    if (coverUrl != null && coverUrl.isNotEmpty) {
      if (coverUrl.startsWith('//')) {
        coverUrl = 'https:$coverUrl';
      } else if (coverUrl.startsWith('http://')) {
        coverUrl = coverUrl.replaceFirst('http://', 'https://');
      }
    }

    final owner = data['owner'] as Map<String, dynamic>?;
    final author = owner?['name']?.toString() ?? '';
    final ownerMid = (owner?['mid'] as num?)?.toInt() ?? 0;
    var upFace = owner?['face']?.toString() ?? '';
    if (upFace.startsWith('http://')) {
      upFace = upFace.replaceFirst('http://', 'https://');
    }
    final stat = data['stat'] as Map<String, dynamic>?;
    final view = stat?['view'];
    final danmaku = stat?['danmaku'];
    final pubdate = (data['pubdate'] as num?)?.toInt();
    final desc = data['desc']?.toString();

    BilibiliUgcSeason? ugcSeason;
    final rawSeason = data['ugc_season'] as Map<String, dynamic>?;
    if (rawSeason != null) {
      final sId = (rawSeason['id'] as num?)?.toInt() ?? 0;
      final sTitle = rawSeason['title']?.toString() ?? '';
      final sCover = _normalizeCoverUrl(rawSeason['cover']?.toString() ?? '');
      final sEpCount = (rawSeason['ep_count'] as num?)?.toInt() ?? 0;
      final sections = rawSeason['sections'] as List<dynamic>? ?? const [];
      final ugcEpisodes = <BilibiliUgcEpisode>[];
      for (final sec in sections) {
        if (sec is! Map<String, dynamic>) continue;
        final rawEps = sec['episodes'] as List<dynamic>? ?? const [];
        for (final ep in rawEps) {
          if (ep is! Map<String, dynamic>) continue;
          final epId = (ep['id'] as num?)?.toInt() ?? 0;
          final epAid = (ep['aid'] as num?)?.toInt() ?? 0;
          final epCid = (ep['cid'] as num?)?.toInt() ?? 0;
          final epTitle = ep['title']?.toString() ?? '';
          final epBvid = ep['bvid']?.toString() ?? '';
          final arc = ep['arc'] as Map<String, dynamic>?;
          final epCover = _normalizeCoverUrl(arc?['pic']?.toString() ?? '');
          final epDuration = (arc?['duration'] as num?)?.toInt() ?? 0;
          ugcEpisodes.add(BilibiliUgcEpisode(
            id: epId,
            aid: epAid,
            cid: epCid,
            title: epTitle,
            bvid: epBvid,
            cover: epCover,
            durationSeconds: epDuration,
          ));
        }
      }
      ugcSeason = BilibiliUgcSeason(
        id: sId,
        title: sTitle,
        cover: sCover,
        epCount: sEpCount > 0 ? sEpCount : ugcEpisodes.length,
        episodes: ugcEpisodes,
      );
    }

    final result = BilibiliVideoDetails(
      bvid: data['bvid']?.toString() ?? target.bvid ?? '',
      aid: (data['aid'] as num?)?.toInt() ?? 0,
      cid: cid,
      title: fullTitle,
      rawTitle: mainTitle,
      coverUrl: coverUrl,
      durationSeconds: pageDuration > 0
          ? pageDuration
          : ((data['duration'] as num?)?.toInt() ?? 0),
      pages: pages,
      selectedPageIndex: target.pageIndex,
      author: author,
      ownerMid: ownerMid,
      upFace: upFace.isNotEmpty ? upFace : null,
      viewCountText: view != null ? _formatCount(view) : '',
      danmakuText: danmaku != null ? _formatCount(danmaku) : '',
      pubdate: pubdate,
      desc: desc,
      ugcSeason: ugcSeason,
    );
    _videoDetailsCache[cacheKey] = result;
    if (target.bvid != null && target.pageIndex == 1) {
      _videoDetailsCache[target.bvid!] = result;
    }
    return result;
  }

  Future<String> getAudioUrl(
    BilibiliVideoDetails details, [
    String cookie = '',
  ]) async {
    final data = await _getPlayData(details, cookie, fnval: '4048');
    final dash = data['dash'] as Map<String, dynamic>?;
    final audio = dash?['audio'] as List<dynamic>? ?? const [];
    if (audio.isEmpty) throw StateError('Bilibili không trả track audio DASH.');
    // Tối ưu mạng yếu: Chọn luồng âm thanh nhẹ nhất (~64kbps, chỉ 2-4MB) để tải siêu tốc cho CapCut STT
    audio.sort(
      (a, b) => ((a as Map<String, dynamic>)['bandwidth'] as num? ?? 0)
          .compareTo((b as Map<String, dynamic>)['bandwidth'] as num? ?? 0),
    );
    final best = audio.first as Map<String, dynamic>;
    final url =
        best['baseUrl']?.toString() ?? best['base_url']?.toString() ?? '';
    if (url.isEmpty) throw StateError('Track audio Bilibili không có URL.');
    return url;
  }

  /// Lấy luồng phát DASH phân đoạn (video và audio riêng biệt) cho media_kit
  Future<BilibiliDashStream> getDashStream(
    BilibiliVideoDetails details, [
    String cookie = '',
    String quality = '64',
  ]) async {
    final data = await _getPlayData(details, cookie, fnval: '4048', quality: quality);
    final dash = data['dash'] as Map<String, dynamic>?;
    if (dash == null) {
      throw StateError('Bilibili không trả luồng DASH.');
    }
    final videoList = (dash['video'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final audioList = (dash['audio'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();

    if (videoList.isEmpty || audioList.isEmpty) {
      throw StateError('DASH stream không có đủ video hoặc audio.');
    }

    final targetQn = int.tryParse(quality) ?? 64;

    videoList.sort((a, b) {
      final qnA = (a['id'] as num?)?.toInt() ?? 0;
      final qnB = (b['id'] as num?)?.toInt() ?? 0;
      final diffA = (qnA - targetQn).abs();
      final diffB = (qnB - targetQn).abs();
      if (diffA != diffB) return diffA.compareTo(diffB);
      final codecA = a['codecs']?.toString().toLowerCase() ?? '';
      final codecB = b['codecs']?.toString().toLowerCase() ?? '';
      final isAvcA = codecA.contains('avc');
      final isAvcB = codecB.contains('avc');
      if (isAvcA && !isAvcB) return -1;
      if (!isAvcA && isAvcB) return 1;
      return 0;
    });

    audioList.sort((a, b) {
      final bwA = (a['bandwidth'] as num?)?.toInt() ?? 0;
      final bwB = (b['bandwidth'] as num?)?.toInt() ?? 0;
      return bwB.compareTo(bwA);
    });

    final bestVideo = videoList.first;
    final bestAudio = audioList.first;

    final videoUrl = bestVideo['baseUrl']?.toString() ?? bestVideo['base_url']?.toString() ?? '';
    final audioUrl = bestAudio['baseUrl']?.toString() ?? bestAudio['base_url']?.toString() ?? '';

    if (videoUrl.isEmpty || audioUrl.isEmpty) {
      throw StateError('Không tìm thấy link video hoặc audio DASH hợp lệ.');
    }

    return BilibiliDashStream(
      videoUrl: videoUrl,
      audioUrl: audioUrl,
      headers: streamHeaders(cookie),
      quality: (bestVideo['id'] as num?)?.toInt() ?? targetQn,
    );
  }

  Future<String> getMuxedVideoUrl(
    BilibiliVideoDetails details, [
    String cookie = '',
    String quality = '64',
  ]) async {
    final urls = await getMuxedVideoUrls(details, cookie, quality);
    return urls.first;
  }

  Future<List<String>> getMuxedVideoUrls(
    BilibiliVideoDetails details, [
    String cookie = '',
    String quality = '64',
  ]) async {
    final cacheKey = '${details.bvid}_${details.selectedPageIndex}_$quality';
    if (_muxedUrlsCache.containsKey(cacheKey)) {
      return _muxedUrlsCache[cacheKey]!;
    }
    var data = await _getPlayData(details, cookie, fnval: '0', quality: quality);
    var urls = extractMuxedVideoUrls(data);
    if (urls.isEmpty && quality != '32') {
      try {
        final fallbackData = await _getPlayData(details, cookie, fnval: '0', quality: '32');
        urls = extractMuxedVideoUrls(fallbackData);
      } catch (_) {}
    }
    if (urls.isEmpty && quality != '16') {
      try {
        final fallbackData = await _getPlayData(details, cookie, fnval: '0', quality: '16');
        urls = extractMuxedVideoUrls(fallbackData);
      } catch (_) {}
    }
    if (urls.isEmpty) {
      throw StateError('Bilibili không trả luồng video MP4 tương thích iOS.');
    }
    _muxedUrlsCache[cacheKey] = urls;
    return urls;
  }

  static List<String> extractMuxedVideoUrls(Map<String, dynamic> data) {
    final durl = data['durl'] as List<dynamic>? ?? const [];
    if (durl.isEmpty || durl.first is! Map<String, dynamic>) return const [];
    final first = durl.first as Map<String, dynamic>;
    final rawUrls = <String>[
      first['url']?.toString() ?? '',
      ...(first['backup_url'] as List<dynamic>? ?? const []).map(
        (url) => url.toString(),
      ),
      ...(first['backupUrl'] as List<dynamic>? ?? const []).map(
        (url) => url.toString(),
      ),
    ];
    return rawUrls
        .map((url) => url.trim())
        .where((url) => url.startsWith('http://') || url.startsWith('https://'))
        .toSet()
        .toList();
  }

  Future<List<BilibiliSubtitleInfo>> getSubtitles(
    BilibiliVideoDetails details, [
    String cookie = '',
  ]) async {
    var loginRequired = false;

    // 1. ƯU TIÊN SỐ 1: Endpoint chuẩn WBI v2 (Giống 100% bản PC tool - chính xác nhất theo từng bvid & cid)
    if (details.cid > 0) {
      try {
        final params = <String, String>{
          'cid': details.cid.toString(),
        };
        if (details.bvid.isNotEmpty) {
          params['bvid'] = details.bvid;
        }
        if (details.aid > 0) {
          params['aid'] = details.aid.toString();
        }
        final data = await _getWbiJson(
          'https://api.bilibili.com/x/player/wbi/v2',
          params,
          cookie,
        );
        if (data['need_login_subtitle'] == true) {
          loginRequired = true;
        }
        final list = parseSubtitles(data, throwOnLoginRequired: false);
        if (list.isNotEmpty) return list;
      } catch (_) {
        // Tiếp tục thử fallback
      }
    }

    // 2. DỰ PHÒNG 1: Thử endpoint Danmaku & Subtitle (x/v2/dm/view)
    if (details.cid > 0) {
      try {
        final query = <String, String>{
          'type': '1',
          'oid': details.cid.toString(),
        };
        if (details.aid > 0) {
          query['pid'] = details.aid.toString();
        }
        final response = await dio.get<Map<String, dynamic>>(
          'https://api.bilibili.com/x/v2/dm/view',
          queryParameters: query,
          options: Options(headers: requestHeaders(cookie)),
        );
        final json = response.data ?? const <String, dynamic>{};
        if ((json['code'] as num?)?.toInt() == 0 &&
            json['data'] is Map<String, dynamic>) {
          final data = json['data'] as Map<String, dynamic>;
          final list = parseSubtitles(data, throwOnLoginRequired: false);
          if (list.isNotEmpty) return list;
        }
      } catch (_) {
        // Tiếp tục thử fallback
      }
    }

    // 3. DỰ PHÒNG 2: Thử endpoint x/player/v2
    if (details.cid > 0) {
      try {
        final query = <String, String>{
          'cid': details.cid.toString(),
        };
        if (details.bvid.isNotEmpty) {
          query['bvid'] = details.bvid;
        }
        if (details.aid > 0) {
          query['aid'] = details.aid.toString();
        }
        final response = await dio.get<Map<String, dynamic>>(
          'https://api.bilibili.com/x/player/v2',
          queryParameters: query,
          options: Options(headers: requestHeaders(cookie)),
        );
        final json = response.data ?? const <String, dynamic>{};
        if ((json['code'] as num?)?.toInt() == 0 &&
            json['data'] is Map<String, dynamic>) {
          final data = json['data'] as Map<String, dynamic>;
          if (data['need_login_subtitle'] == true) {
            loginRequired = true;
          }
          final list = parseSubtitles(data, throwOnLoginRequired: false);
          if (list.isNotEmpty) return list;
        }
      } catch (_) {
        // Bỏ qua
      }
    }

    if (loginRequired) {
      throw const BilibiliSubtitleLoginRequiredException();
    }
    return const [];
  }

  static List<BilibiliSubtitleInfo> parseSubtitles(
    Map<String, dynamic> data, {
    bool throwOnLoginRequired = true,
  }) {
    final subtitle = data['subtitle'] as Map<String, dynamic>?;
    final list = (subtitle?['subtitles'] as List<dynamic>?) ??
        (subtitle?['list'] as List<dynamic>?) ??
        const [];
    if (list.isEmpty &&
        data['need_login_subtitle'] == true &&
        throwOnLoginRequired) {
      throw const BilibiliSubtitleLoginRequiredException();
    }
    return list
        .whereType<Map<String, dynamic>>()
        .map((item) {
          var url = item['subtitle_url']?.toString() ?? '';
          if (url.startsWith('//')) url = 'https:$url';
          final language = item['lan']?.toString() ?? '';
          final aiType = (item['ai_type'] as num?)?.toInt() ?? 0;
          final type = (item['type'] as num?)?.toInt() ?? 0;
          return BilibiliSubtitleInfo(
            language: language,
            languageName: item['lan_doc']?.toString() ?? language,
            isAi:
                language.startsWith('ai-') ||
                aiType == 1 ||
                type == 1,
            url: url,
          );
        })
        .where((item) => item.url.isNotEmpty)
        .toList();
  }

  Future<SubtitleDocument?> downloadSubtitle(
    BilibiliSubtitleInfo subtitle,
  ) async {
    final response = await dio.get<dynamic>(
      subtitle.url,
      options: Options(headers: requestHeaders()),
    );
    dynamic data = response.data;
    if (data is String) {
      try {
        data = jsonDecode(data);
      } catch (_) {}
    }
    final body = (data as Map<String, dynamic>?)?['body'] as List<dynamic>? ?? const [];
    final items = <SubtitleItem>[];
    for (final raw in body) {
      final item = raw as Map<String, dynamic>;
      final text = item['content']?.toString().trim() ?? '';
      if (text.isEmpty) continue;
      items.add(
        SubtitleItem(
          id: items.length + 1,
          startMs: (((item['from'] as num?)?.toDouble() ?? 0) * 1000).round(),
          endMs: (((item['to'] as num?)?.toDouble() ?? 0) * 1000).round(),
          originalText: text,
          translatedText: text,
        ),
      );
    }
    return items.isEmpty ? null : SubtitleDocument(items);
  }

  Future<File> downloadAudio(
    String audioUrl,
    File destination,
    String cookie, {
    int concurrency = 16,
    void Function(double progress, String message)? onProgress,
  }) async {
    await destination.parent.create(recursive: true);
    final headers = requestHeaders(cookie);
    await MultiThreadDownloader.downloadFile(
      url: audioUrl,
      outputFile: destination,
      headers: headers,
      concurrency: concurrency,
      progressCallback: onProgress,
    );
    if (!await destination.exists() || await destination.length() < 1024) {
      throw StateError('Audio tải từ Bilibili không hợp lệ.');
    }
    return destination;
  }

  Future<File> downloadVideo(
    BilibiliVideoDetails details,
    File destination,
    String cookie, {
    int concurrency = 16,
    String quality = '64',
    void Function(double progress, String message)? onProgress,
  }) async {
    await destination.parent.create(recursive: true);
    final videoUrls = await getMuxedVideoUrls(details, cookie, quality);
    if (videoUrls.isEmpty) {
      throw StateError('Không tìm thấy luồng video MP4 phù hợp từ Bilibili.');
    }
    final headers = requestHeaders(cookie);
    await MultiThreadDownloader.downloadFile(
      url: videoUrls.first,
      backupUrls: videoUrls.skip(1).toList(),
      outputFile: destination,
      headers: headers,
      concurrency: concurrency,
      progressCallback: onProgress,
    );
    if (!await destination.exists() || await destination.length() < 1024 * 100) {
      throw StateError('Video tải từ Bilibili không hoàn chỉnh hoặc bị lỗi.');
    }
    return destination;
  }

  Future<Map<String, dynamic>> _getPlayData(
    BilibiliVideoDetails details,
    String cookie, {
    required String fnval,
    String quality = '127',
  }) {
    return _getWbiJson('https://api.bilibili.com/x/player/wbi/playurl', {
      'bvid': details.bvid,
      'cid': details.cid.toString(),
      'qn': quality,
      'fnval': fnval,
      'fnver': '0',
      'fourk': '1',
      'high_quality': '1',
    }, cookie);
  }

  Future<Map<String, dynamic>> _getWbiJson(
    String endpoint,
    Map<String, String> params,
    String cookie,
  ) async {
    final keys = await _getWbiKeys(cookie);
    final signed = _signWbi(params, keys.$1, keys.$2);
    final response = await dio.get<Map<String, dynamic>>(
      endpoint,
      queryParameters: signed,
      options: Options(headers: requestHeaders(cookie)),
    );
    final json = response.data ?? const <String, dynamic>{};
    if ((json['code'] as num?)?.toInt() != 0) {
      throw StateError(
        json['message']?.toString() ?? 'Bilibili API từ chối yêu cầu.',
      );
    }
    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw StateError('Phản hồi Bilibili thiếu data.');
    }
    return data;
  }

  Future<(String, String)> _getWbiKeys(String cookie) async {
    final now = DateTime.now();
    if (_cachedImgKey != null &&
        _cachedSubKey != null &&
        _wbiFetchedAt != null &&
        now.difference(_wbiFetchedAt!) < const Duration(hours: 12)) {
      return (_cachedImgKey!, _cachedSubKey!);
    }
    final response = await dio.get<Map<String, dynamic>>(
      'https://api.bilibili.com/x/web-interface/nav',
      options: Options(headers: requestHeaders(cookie)),
    );
    final wbi = response.data?['data']?['wbi_img'] as Map<String, dynamic>?;
    final imgUrl = wbi?['img_url']?.toString() ?? '';
    final subUrl = wbi?['sub_url']?.toString() ?? '';
    if (imgUrl.isEmpty || subUrl.isEmpty) {
      throw StateError('Không lấy được WBI key từ Bilibili.');
    }
    _cachedImgKey = Uri.parse(imgUrl).pathSegments.last.split('.').first;
    _cachedSubKey = Uri.parse(subUrl).pathSegments.last.split('.').first;
    _wbiFetchedAt = now;
    return (_cachedImgKey!, _cachedSubKey!);
  }

  static Future<void> warmUpWbi([String cookie = '']) async {
    try {
      final now = DateTime.now();
      if (_cachedImgKey != null &&
          _cachedSubKey != null &&
          _wbiFetchedAt != null &&
          now.difference(_wbiFetchedAt!) < const Duration(hours: 12)) {
        return;
      }
      final resolver = BilibiliResolver();
      await resolver._getWbiKeys(cookie);
    } catch (_) {}
  }

  Map<String, String> _signWbi(
    Map<String, String> params,
    String imgKey,
    String subKey,
  ) {
    final source = '$imgKey$subKey';
    final mixin = _mixinKeyEncTab
        .where((index) => index < source.length)
        .map((index) => source[index])
        .join()
        .substring(0, 32);
    final values = <String, String>{
      ...params,
      'wts': (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
    };
    final keys = values.keys.toList()..sort();
    final query = keys
        .map((key) {
          final clean = values[key]!.replaceAll(RegExp(r"[!'()*]"), '');
          return '${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent(clean)}';
        })
        .join('&');
    values['w_rid'] = md5.convert(utf8.encode('$query$mixin')).toString();
    return values;
  }

  static String _stripHtml(String html) {
    return html.replaceAll(RegExp(r'<[^>]*>'), '').trim();
  }

  static String _normalizeCoverUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('//')) {
      return 'https:$trimmed';
    }
    return trimmed;
  }

  static String _formatCount(dynamic count) {
    if (count == null) return '';
    final raw = count.toString().trim();
    final numVal = num.tryParse(raw);
    if (numVal == null) {
      return raw.replaceAll('万', ' vạn').replaceAll('亿', ' trăm triệu');
    }
    if (numVal >= 100000000) {
      return '${(numVal / 100000000).toStringAsFixed(1)} trăm triệu';
    }
    if (numVal >= 10000) {
      return '${(numVal / 10000).toStringAsFixed(1)} vạn';
    }
    return numVal.toString();
  }

  /// Lấy thông tin tài khoản người dùng Bilibili từ cookie
  Future<BilibiliUserProfile> getUserProfile([String cookie = '']) async {
    try {
      final response = await dio.get<Map<String, dynamic>>(
        'https://api.bilibili.com/x/web-interface/nav',
        options: Options(headers: requestHeaders(cookie)),
      );
      final json = response.data ?? const <String, dynamic>{};
      final data = json['data'] as Map<String, dynamic>?;
      if (data == null) return const BilibiliUserProfile();

      final isLogin = data['isLogin'] == true;
      final mid = (data['mid'] as num?)?.toInt() ?? 0;
      final uname = data['uname']?.toString() ?? '';
      final avatar = _normalizeCoverUrl(data['face']?.toString() ?? '');
      final vipType = (data['vipType'] as num?)?.toInt() ?? 0;
      final vipStatus = (data['vipStatus'] as num?)?.toInt() ?? 0;
      final isVip = vipType > 0 || vipStatus == 1;

      String vipLabel = '';
      if (data['vip_label'] is Map) {
        vipLabel = data['vip_label']['text']?.toString() ?? '';
      } else if (data['vip'] is Map && data['vip']['label'] is Map) {
        vipLabel = data['vip']['label']['text']?.toString() ?? '';
      }
      if (vipLabel.isEmpty && isVip) {
        vipLabel = vipType == 2 ? 'Đại Hội Viên Năm' : 'Đại Hội Viên';
      }

      final levelInfo = data['level_info'] as Map<String, dynamic>?;
      final level = (levelInfo?['current_level'] as num?)?.toInt() ?? 0;

      return BilibiliUserProfile(
        mid: mid,
        uname: uname,
        avatar: avatar,
        isLogin: isLogin,
        isVip: isVip,
        vipLabel: vipLabel,
        level: level,
      );
    } catch (_) {
      return const BilibiliUserProfile();
    }
  }

  /// Tạo mã QR đăng nhập Bilibili
  Future<BilibiliQrCodeInfo> generateLoginQrCode() async {
    final response = await dio.get<Map<String, dynamic>>(
      'https://passport.bilibili.com/x/passport-login/web/qrcode/generate',
      options: Options(headers: requestHeaders()),
    );
    final json = response.data ?? const <String, dynamic>{};
    final data = json['data'] as Map<String, dynamic>?;
    if (data == null || data['url'] == null || data['qrcode_key'] == null) {
      throw StateError('Không thể tạo mã QR đăng nhập Bilibili.');
    }
    return BilibiliQrCodeInfo(
      url: data['url'].toString(),
      qrcodeKey: data['qrcode_key'].toString(),
    );
  }

  /// Kiểm tra trạng thái quét mã QR Bilibili
  Future<BilibiliQrPollResult> pollLoginQrCode(String qrcodeKey) async {
    final response = await dio.get<Map<String, dynamic>>(
      'https://passport.bilibili.com/x/passport-login/web/qrcode/poll',
      queryParameters: {'qrcode_key': qrcodeKey},
      options: Options(headers: requestHeaders()),
    );
    final json = response.data ?? const <String, dynamic>{};
    final data = json['data'] as Map<String, dynamic>?;
    if (data == null) {
      return const BilibiliQrPollResult(
        code: -1,
        message: 'Lỗi phản hồi máy chủ Bilibili',
      );
    }

    final code = (data['code'] as num?)?.toInt() ?? -1;
    final message = data['message']?.toString() ?? '';
    final urlStr = data['url']?.toString() ?? '';

    String? sessData;
    String? biliJct;
    String? dedeUserId;

    if (code == 0) {
      if (urlStr.isNotEmpty) {
        final uri = Uri.tryParse(urlStr);
        sessData = uri?.queryParameters['SESSDATA'];
        biliJct = uri?.queryParameters['bili_jct'];
        dedeUserId = uri?.queryParameters['DedeUserID'];
      }
      if (sessData == null || sessData.isEmpty) {
        final rawSetCookies = response.headers['set-cookie'] ?? const [];
        for (final cookieHeader in rawSetCookies) {
          final parts = cookieHeader.split(';');
          for (final part in parts) {
            final kv = part.trim().split('=');
            if (kv.length >= 2) {
              final key = kv[0].trim();
              final val = kv.sublist(1).join('=').trim();
              if (key == 'SESSDATA') sessData = val;
              if (key == 'bili_jct') biliJct = val;
              if (key == 'DedeUserID') dedeUserId = val;
            }
          }
        }
      }
    }

    return BilibiliQrPollResult(
      code: code,
      message: message,
      sessData: sessData,
      biliJct: biliJct,
      dedeUserId: dedeUserId,
    );
  }

  /// Danh sách hoạt hình Trung Quốc (Quốc Mạn - Guochuang)
  /// [order]: 2 = Xem nhiều nhất, 0 = Cập nhật mới, 3 = Điểm cao nhất, 1 = Theo dõi nhiều
  Future<List<BilibiliAnimeItem>> getGuochuangList({
    int page = 1,
    int pageSize = 20,
    int order = 2,
    String cookie = '',
  }) async {
    return _getPgcSeasonList(
      seasonType: 4,
      page: page,
      pageSize: pageSize,
      order: order,
      cookie: cookie,
    );
  }

  /// Danh sách hoạt hình Nhật Bản (Anime)
  Future<List<BilibiliAnimeItem>> getAnimeList({
    int page = 1,
    int pageSize = 20,
    int order = 2,
    String cookie = '',
  }) async {
    return _getPgcSeasonList(
      seasonType: 1,
      page: page,
      pageSize: pageSize,
      order: order,
      cookie: cookie,
    );
  }

  /// Lấy danh sách PGC theo `seasonType`:
  /// `1` = Anime Nhật, `2` = Điện ảnh, `3` = Phim tài liệu, `4` = Quốc sáng, `5` = Phim truyền hình, `7` = Giải trí
  Future<List<BilibiliAnimeItem>> getPgcCatalog({
    required int seasonType,
    int page = 1,
    int pageSize = 20,
    int order = 2,
    String cookie = '',
  }) => _getPgcSeasonList(
    seasonType: seasonType,
    page: page,
    pageSize: pageSize,
    order: order,
    cookie: cookie,
  );

  Future<List<BilibiliAnimeItem>> _getPgcSeasonList({
    required int seasonType,
    int page = 1,
    int pageSize = 20,
    int order = 2,
    String cookie = '',
  }) async {
    final response = await dio.get<Map<String, dynamic>>(
      'https://api.bilibili.com/pgc/season/index/result',
      queryParameters: {
        'season_version': '-1',
        'spoken_language_type': '-1',
        'area': '-1',
        'is_finish': '-1',
        'copyright': '-1',
        'season_status': '-1',
        'season_month': '-1',
        'year': '-1',
        'style_id': '-1',
        'order': '$order',
        'st': '$seasonType',
        'sort': '0',
        'page': '$page',
        'season_type': '$seasonType',
        'pagesize': '$pageSize',
        'type': '1',
      },
      options: Options(headers: requestHeaders(cookie)),
    );
    final json = response.data ?? const <String, dynamic>{};
    final data = json['data'] as Map<String, dynamic>?;
    final list = data?['list'] as List<dynamic>? ?? const [];

    return list.map((raw) {
      final item = raw as Map<String, dynamic>;
      final stylesList = <String>[];
      if (item['styles'] is List) {
        for (final s in item['styles'] as List) {
          stylesList.add(s.toString());
        }
      }
      return BilibiliAnimeItem(
        title: item['title']?.toString() ?? '',
        cover: _normalizeCoverUrl(item['cover']?.toString() ?? ''),
        seasonId: (item['season_id'] as num?)?.toInt(),
        badge: item['badge']?.toString() ?? '',
        desc: item['sub_title']?.toString() ?? item['desc']?.toString() ?? '',
        viewCountText: item['order']?.toString() ?? '',
        indexShow: item['index_show']?.toString() ?? '',
        styles: stylesList,
      );
    }).toList();
  }

  /// Lịch phát sóng Anime / Quốc mạn theo tuần (Thứ Hai - Chủ Nhật)
  Future<List<BilibiliTimelineDay>> getAnimeTimeline({
    int seasonType = 4,
    String cookie = '',
  }) async {
    final response = await dio.get<Map<String, dynamic>>(
      'https://api.bilibili.com/pgc/web/timeline/v2',
      queryParameters: {'season_type': '$seasonType'},
      options: Options(headers: requestHeaders(cookie)),
    );
    final json = response.data ?? const <String, dynamic>{};
    final data = json['data'] as Map<String, dynamic>?;
    final latest = data?['latest'] as List<dynamic>? ?? const [];

    const dayNames = [
      '',
      'Thứ Hai',
      'Thứ Ba',
      'Thứ Tư',
      'Thứ Năm',
      'Thứ Sáu',
      'Thứ Bảy',
      'Chủ Nhật',
    ];

    return latest.map((rawDay) {
      final dayMap = rawDay as Map<String, dynamic>;
      final dayOfWeek = (dayMap['day_of_week'] as num?)?.toInt() ?? 1;
      final dateText = dayMap['date']?.toString() ?? '';
      final isToday = dayMap['is_today'] == 1 || dayMap['is_today'] == true;
      final episodesRaw = dayMap['episodes'] as List<dynamic>? ?? const [];

      final episodes = episodesRaw.map((rawEp) {
        final ep = rawEp as Map<String, dynamic>;
        final styles = <String>[];
        if (ep['styles'] is List) {
          for (final s in ep['styles'] as List) {
            styles.add(s.toString());
          }
        }
        return BilibiliAnimeItem(
          title: ep['title']?.toString() ?? '',
          cover: _normalizeCoverUrl(ep['cover']?.toString() ?? ''),
          seasonId: (ep['season_id'] as num?)?.toInt(),
          epId: (ep['episode_id'] as num?)?.toInt() ?? (ep['ep_id'] as num?)?.toInt(),
          badge: ep['badge']?.toString() ?? '',
          indexShow: ep['pub_index']?.toString() ?? ep['pub_time']?.toString() ?? '',
          desc: ep['sub_title']?.toString() ?? '',
          styles: styles,
        );
      }).toList();

      final dayName = (dayOfWeek >= 1 && dayOfWeek <= 7) ? dayNames[dayOfWeek] : 'T$dayOfWeek';

      return BilibiliTimelineDay(
        dayOfWeek: dayOfWeek,
        dayName: dayName,
        dateText: dateText,
        isToday: isToday,
        episodes: episodes,
      );
    }).toList();
  }

  /// Bảng xếp hạng Anime / Quốc Mạn
  Future<List<BilibiliAnimeItem>> getRankingAnime({
    int seasonType = 4,
    String cookie = '',
  }) async {
    final response = await dio.get<Map<String, dynamic>>(
      'https://api.bilibili.com/pgc/season/rank/web/list',
      queryParameters: {'day': '3', 'season_type': '$seasonType'},
      options: Options(headers: requestHeaders(cookie)),
    );
    final json = response.data ?? const <String, dynamic>{};
    final data = json['data'] as Map<String, dynamic>?;
    final list = data?['list'] as List<dynamic>? ?? const [];

    return list.map((raw) {
      final item = raw as Map<String, dynamic>;
      final stat = item['stat'] as Map<String, dynamic>?;
      final playCount = stat?['view'];
      final followCount = stat?['follow'];

      return BilibiliAnimeItem(
        title: item['title']?.toString() ?? '',
        cover: _normalizeCoverUrl(item['cover']?.toString() ?? ''),
        seasonId: (item['season_id'] as num?)?.toInt(),
        bvid: item['bvid']?.toString(),
        badge: item['badge']?.toString() ?? '',
        desc: item['desc']?.toString() ?? '',
        ratingText: item['rating']?.toString() ?? '',
        viewCountText: playCount != null ? '${_formatCount(playCount)} xem' : '',
        followCountText: followCount != null ? '${_formatCount(followCount)} theo dõi' : '',
        indexShow: item['index_show']?.toString() ?? '',
      );
    }).toList();
  }

  /// Lấy danh sách video Đề xuất (Recommend Feed - 推荐)
  /// Tự động lấy danh sách cá nhân hóa theo tài khoản (phim AI, AI漫剧...) nếu có SESSDATA
  Future<List<BilibiliAnimeItem>> getRecommendFeed({
    int pageSize = 20,
    int freshIdx = 1,
    String cookie = '',
  }) async {
    try {
      final response = await dio.get<Map<String, dynamic>>(
        'https://api.bilibili.com/x/web-interface/wbi/index/top/feed/rcmd',
        queryParameters: {
          'ps': '$pageSize',
          'fresh_idx': '$freshIdx',
          'feed_version': 'V8',
        },
        options: Options(headers: requestHeaders(cookie)),
      );
      final json = response.data ?? const <String, dynamic>{};
      final data = json['data'] as Map<String, dynamic>?;
      final items = data?['item'] as List<dynamic>? ?? const [];

      return items.map((raw) {
        final item = raw as Map<String, dynamic>;
        final bvid = item['bvid']?.toString() ?? '';
        final title = _stripHtml(item['title']?.toString() ?? '');
        final cover = _normalizeCoverUrl(item['pic']?.toString() ?? '');
        final durationSec = (item['duration'] as num?)?.toInt() ?? 0;
        final owner = item['owner'] as Map<String, dynamic>?;
        final author = owner?['name']?.toString() ?? '';
        final upFace = _normalizeCoverUrl(owner?['face']?.toString() ?? '');
        final stat = item['stat'] as Map<String, dynamic>?;
        final views = stat?['view'];
        final danmaku = stat?['danmaku'];
        final likes = stat?['like'];
        final pubdate = _parseUnixSec(item['pubdate']);

        return BilibiliAnimeItem(
          title: title,
          cover: cover,
          bvid: bvid,
          author: author,
          upFace: upFace,
          durationSeconds: durationSec,
          durationText: durationSec > 0 ? BilibiliAnimeItem.formatDuration(durationSec) : '',
          viewCountText: views != null ? _formatCount(views) : '',
          danmakuText: danmaku != null ? _formatCount(danmaku) : '',
          likeCountText: likes != null ? _formatCount(likes) : '',
          pubdate: pubdate,
        );
      }).where((it) => it.bvid != null && it.bvid!.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Lấy danh sách video Thịnh hành (Popular - 热门)
  Future<List<BilibiliAnimeItem>> getPopularVideos({
    int page = 1,
    int pageSize = 20,
    String cookie = '',
  }) async {
    try {
      final response = await dio.get<Map<String, dynamic>>(
        'https://api.bilibili.com/x/web-interface/popular',
        queryParameters: {
          'pn': '$page',
          'ps': '$pageSize',
        },
        options: Options(headers: requestHeaders(cookie)),
      );
      final json = response.data ?? const <String, dynamic>{};
      final data = json['data'] as Map<String, dynamic>?;
      final list = data?['list'] as List<dynamic>? ?? const [];

      return list.map((raw) {
        final item = raw as Map<String, dynamic>;
        final bvid = item['bvid']?.toString() ?? '';
        final title = _stripHtml(item['title']?.toString() ?? '');
        final cover = _normalizeCoverUrl(item['pic']?.toString() ?? '');
        final durationSec = (item['duration'] as num?)?.toInt() ?? 0;
        final owner = item['owner'] as Map<String, dynamic>?;
        final author = owner?['name']?.toString() ?? '';
        final upFace = _normalizeCoverUrl(owner?['face']?.toString() ?? '');
        final stat = item['stat'] as Map<String, dynamic>?;
        final views = stat?['view'];
        final danmaku = stat?['danmaku'];
        final likes = stat?['like'];
        final pubdate = _parseUnixSec(item['pubdate']);

        return BilibiliAnimeItem(
          title: title,
          cover: cover,
          bvid: bvid,
          author: author,
          upFace: upFace,
          durationSeconds: durationSec,
          durationText: durationSec > 0 ? BilibiliAnimeItem.formatDuration(durationSec) : '',
          viewCountText: views != null ? _formatCount(views) : '',
          danmakuText: danmaku != null ? _formatCount(danmaku) : '',
          likeCountText: likes != null ? _formatCount(likes) : '',
          pubdate: pubdate,
        );
      }).where((it) => it.bvid != null && it.bvid!.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  static int _parseUnixSec(dynamic raw) {
    if (raw is num) return raw.toInt();
    return int.tryParse((raw ?? '').toString()) ?? 0;
  }

  /// Lấy lịch sử xem tài khoản Bilibili (yêu cầu đã đăng nhập `SESSDATA`, nếu chưa trả rỗng).
  Future<List<BilibiliAnimeItem>> getWatchHistory({
    int pageSize = 20,
    String cookie = '',
  }) async {
    if (cookie.trim().isEmpty) return const [];
    try {
      final response = await dio.get<Map<String, dynamic>>(
        'https://api.bilibili.com/x/web-interface/history/cursor',
        queryParameters: {
          'ps': '$pageSize',
          'type': 'archive',
        },
        options: Options(headers: requestHeaders(cookie)),
      );
      final json = response.data ?? const <String, dynamic>{};
      if ((json['code'] as num?)?.toInt() != 0) return const [];
      final list = json['data']?['list'] as List<dynamic>? ?? const [];
      final results = <BilibiliAnimeItem>[];
      for (final raw in list) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final history = item['history'] as Map?;
        final bvid = (history?['bvid'] ?? item['bvid'])?.toString() ?? '';
        final title = _stripHtml(item['title']?.toString() ?? '');
        if (title.isEmpty) continue;
        final durationSec = _parseUnixSec(item['duration']);
        results.add(
          BilibiliAnimeItem(
            title: title,
            cover: _normalizeCoverUrl(item['cover']?.toString() ?? ''),
            bvid: bvid.isNotEmpty ? bvid : null,
            author: item['author_name']?.toString() ?? '',
            upFace: _normalizeCoverUrl(item['author_face']?.toString() ?? ''),
            badge: item['tag_name']?.toString() ?? '',
            durationSeconds: durationSec,
            durationText: durationSec > 0 ? BilibiliAnimeItem.formatDuration(durationSec) : '',
            pubdate: _parseUnixSec(item['view_at']),
          ),
        );
      }
      return results;
    } catch (_) {
      return const [];
    }
  }

  /// Lấy danh sách phim hoạt hình AI / AI漫剧 / AI动画 (tự lọc bỏ video hướng dẫn làm AI, người thật & tiểu thuyết audio).
  Future<List<BilibiliAnimeItem>> getAiManhuaVideos({
    String keyword = 'AI漫剧',
    int page = 1,
    int pageSize = 20,
    String order = 'totalrank', // totalrank, click (xem nhiều), pubdate (mới nhất)
    int tid = 0,
    bool cleanAiAnimeOnly = true,
    String cookie = '',
  }) async {
    final cleanKw = keyword.trim();
    final isPureAnimeTab =
        cleanKw == 'AI漫剧' ||
        cleanKw == 'AI动画' ||
        cleanKw == 'AI动漫' ||
        cleanKw == '动态漫';

    if (!cleanAiAnimeOnly) {
      return searchVideos(
        cleanKw,
        page: page,
        pageSize: pageSize,
        order: order,
        tid: tid,
        cookie: cookie,
      );
    }

    final effectiveTid = tid > 0 ? tid : (isPureAnimeTab ? 1 : 0);
    final rawPrimary = await searchVideos(
      cleanKw == 'AI漫剧' ? 'AI动画' : cleanKw,
      page: page,
      pageSize: pageSize,
      order: order,
      tid: effectiveTid,
      cookie: cookie,
    );

    bool allowItem(BilibiliAnimeItem item) {
      if (isPureAnimeTab) {
        return BilibiliContentClassifier.isCleanWatchableAiAnime(item);
      }
      return !BilibiliContentClassifier.isTutorialOrCourse(item) &&
          !BilibiliContentClassifier.isAudioNovelOrPodcast(item);
    }

    final out = <BilibiliAnimeItem>[];
    final seen = <String>{};
    void appendClean(List<BilibiliAnimeItem> batch) {
      for (final item in batch) {
        if (!allowItem(item)) continue;
        final key = item.bvid?.isNotEmpty == true ? item.bvid! : item.title;
        if (seen.add(key)) out.add(item);
      }
    }

    appendClean(rawPrimary);

    if (out.length < pageSize) {
      final secondary = await searchVideos(
        cleanKw == 'AI漫剧' ? 'AI漫剧 一口气看完' : cleanKw,
        page: page,
        pageSize: pageSize,
        order: order,
        tid: isPureAnimeTab ? 167 : tid,
        cookie: cookie,
      );
      appendClean(secondary);
    }

    out.sort(
      (a, b) => BilibiliContentClassifier.scoreWatchableAiAnime(b).compareTo(
        BilibiliContentClassifier.scoreWatchableAiAnime(a),
      ),
    );
    return out.take(pageSize).toList();
  }

  /// Tìm kiếm video trên Bilibili (hỗ trợ lọc Phân khu `tid`, Thời lượng `duration`, và khoảng thời gian đăng `pubtimeBeginSec..pubtimeEndSec`).
  Future<List<BilibiliAnimeItem>> searchVideos(
    String keyword, {
    int page = 1,
    int pageSize = 20,
    String order = 'totalrank',
    int tid = 0,
    int duration = 0,
    int? pubtimeBeginSec,
    int? pubtimeEndSec,
    String cookie = '',
  }) async {
    final cleanKeyword = keyword.trim();
    if (cleanKeyword.isEmpty) return const [];

    final queryParams = <String, String>{
      'search_type': 'video',
      'keyword': cleanKeyword,
      'page': '$page',
      'page_size': '$pageSize',
      'order': order,
      if (tid > 0) 'tids': '$tid',
      if (duration > 0) 'duration': '$duration',
      if (pubtimeBeginSec != null && pubtimeBeginSec > 0)
        'pubtime_begin_s': '$pubtimeBeginSec',
      if (pubtimeEndSec != null && pubtimeEndSec > 0)
        'pubtime_end_s': '$pubtimeEndSec',
    };

    Map<String, dynamic>? data;
    try {
      data = await _getWbiJson(
        'https://api.bilibili.com/x/web-interface/wbi/search/type',
        queryParams,
        cookie,
      );
    } catch (_) {
      // Fallback sang search thông thường nếu WBI fail
      final response = await dio.get<Map<String, dynamic>>(
        'https://api.bilibili.com/x/web-interface/search/type',
        queryParameters: queryParams,
        options: Options(headers: requestHeaders(cookie)),
      );
      data = response.data?['data'] as Map<String, dynamic>?;
    }

    final resultList = data?['result'] as List<dynamic>? ?? const [];

    return resultList.map((raw) {
      final item = raw as Map<String, dynamic>;
      final bvid = item['bvid']?.toString() ?? '';
      final title = _stripHtml(item['title']?.toString() ?? '');
      final cover = _normalizeCoverUrl(item['pic']?.toString() ?? '');
      final author = item['author']?.toString() ?? '';
      final upFace = _normalizeCoverUrl(item['upic']?.toString() ?? '');
      final rawDuration = item['duration']?.toString() ?? '';
      final play = item['play'];
      final danmaku = item['danmaku'];
      final desc = _stripHtml(item['description']?.toString() ?? '');
      final rawTags = item['tag'];
      final parsedTags = switch (rawTags) {
        List list => list
            .map((e) => _stripHtml(e.toString()).trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        String s => s
            .split(RegExp(r'[,，]'))
            .map((e) => _stripHtml(e).trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        _ => const <String>[],
      };
      final typeId = int.tryParse(item['typeid']?.toString() ?? '') ??
          (item['typeid'] as num?)?.toInt() ??
          0;

      String durationText = rawDuration;
      int durationSeconds = 0;
      if (rawDuration.isNotEmpty) {
        final parts = rawDuration.split(':');
        if (parts.length == 3) {
          final h = int.tryParse(parts[0]) ?? 0;
          final m = int.tryParse(parts[1]) ?? 0;
          final s = int.tryParse(parts[2]) ?? 0;
          durationSeconds = h * 3600 + m * 60 + s;
          durationText = '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
        } else if (parts.length == 2) {
          final m = int.tryParse(parts[0]) ?? 0;
          final s = int.tryParse(parts[1]) ?? 0;
          durationSeconds = m * 60 + s;
          if (m >= 60) {
            final h = m ~/ 60;
            final remM = m % 60;
            durationText = '$h:${remM.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
          } else {
            durationText = '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
          }
        }
      }

      return BilibiliAnimeItem(
        title: title,
        cover: cover,
        bvid: bvid,
        author: author,
        upFace: upFace,
        desc: desc,
        badge: item['typename']?.toString() ?? '',
        styles: parsedTags,
        typeId: typeId,
        durationSeconds: durationSeconds,
        durationText: durationText,
        viewCountText: play != null ? _formatCount(play) : '',
        danmakuText: danmaku != null ? _formatCount(danmaku) : '',
        pubdate: _parseUnixSec(item['pubdate']),
      );
    }).toList();
  }

  /// Tìm kiếm kênh UP chủ / Creator trên Bilibili (`search_type: bili_user`)
  Future<List<BilibiliUserSearchResult>> searchUsers(
    String keyword, {
    int page = 1,
    int pageSize = 15,
    String order = 'fans', // 'fans' hoặc '' mặc định
    String cookie = '',
  }) async {
    final cleanKeyword = keyword.trim();
    if (cleanKeyword.isEmpty) return const [];

    final params = <String, String>{
      'search_type': 'bili_user',
      'keyword': cleanKeyword,
      'page': '$page',
      'page_size': '$pageSize',
      if (order.isNotEmpty) 'order': order,
    };

    Map<String, dynamic>? data;
    try {
      data = await _getWbiJson(
        'https://api.bilibili.com/x/web-interface/wbi/search/type',
        params,
        cookie,
      );
    } catch (_) {
      final response = await dio.get<Map<String, dynamic>>(
        'https://api.bilibili.com/x/web-interface/search/type',
        queryParameters: params,
        options: Options(headers: requestHeaders(cookie)),
      );
      data = response.data?['data'] as Map<String, dynamic>?;
    }

    final resultList = data?['result'] as List<dynamic>? ?? const [];
    final results = <BilibiliUserSearchResult>[];
    for (final raw in resultList) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final mid = (item['mid'] as num?)?.toInt() ?? 0;
      if (mid <= 0) continue;
      final fans = (item['fans'] as num?)?.toInt() ?? 0;
      final official = item['official_verify'] as Map?;
      final officialType = (official?['type'] as num?)?.toInt() ?? -1;
      results.add(
        BilibiliUserSearchResult(
          mid: mid,
          uname: _stripHtml(item['uname']?.toString() ?? ''),
          upic: _normalizeCoverUrl(item['upic']?.toString() ?? ''),
          usign: _stripHtml(item['usign']?.toString() ?? ''),
          fans: fans,
          fansText: _formatCount(fans),
          videos: (item['videos'] as num?)?.toInt() ?? 0,
          isOfficial: officialType >= 0,
          officialDesc: official?['desc']?.toString() ?? '',
        ),
      );
    }
    return results;
  }

  /// Tìm kiếm Phim tài liệu, Điện ảnh, Anime chính thống (`media_ft` hoặc `media_bangumi`)
  Future<List<BilibiliPgcSearchResult>> searchPgc(
    String keyword, {
    String searchType = 'media_ft',
    int page = 1,
    int pageSize = 15,
    String cookie = '',
  }) async {
    final cleanKeyword = keyword.trim();
    if (cleanKeyword.isEmpty) return const [];

    final effectiveType =
        searchType == 'media_bangumi' ? 'media_bangumi' : 'media_ft';
    final params = <String, String>{
      'search_type': effectiveType,
      'keyword': cleanKeyword,
      'page': '$page',
      'page_size': '$pageSize',
    };

    Map<String, dynamic>? data;
    try {
      data = await _getWbiJson(
        'https://api.bilibili.com/x/web-interface/wbi/search/type',
        params,
        cookie,
      );
    } catch (_) {
      final response = await dio.get<Map<String, dynamic>>(
        'https://api.bilibili.com/x/web-interface/search/type',
        queryParameters: params,
        options: Options(headers: requestHeaders(cookie)),
      );
      data = response.data?['data'] as Map<String, dynamic>?;
    }

    final resultList = data?['result'] as List<dynamic>? ?? const [];
    final results = <BilibiliPgcSearchResult>[];
    for (final raw in resultList) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final seasonId = (item['season_id'] as num?)?.toInt() ?? 0;
      if (seasonId <= 0) continue;
      final eps = item['eps'] as List<dynamic>? ?? const [];
      int? firstEp;
      if (eps.isNotEmpty && eps.first is Map) {
        firstEp = ((eps.first as Map)['id'] as num?)?.toInt();
      }
      final mediaScore = item['media_score'] as Map?;
      final scoreVal = mediaScore?['score']?.toString() ?? '';
      String badge = '';
      if (item['display_info'] is List && (item['display_info'] as List).isNotEmpty) {
        final firstBadge = (item['display_info'] as List).first;
        if (firstBadge is Map) {
          badge = firstBadge['text']?.toString() ?? '';
        }
      } else {
        badge = item['season_type_name']?.toString() ?? '';
      }

      results.add(
        BilibiliPgcSearchResult(
          seasonId: seasonId,
          mediaId: (item['media_id'] as num?)?.toInt() ?? 0,
          firstEpId: firstEp,
          title: _stripHtml(item['title']?.toString() ?? ''),
          cover: _normalizeCoverUrl(item['cover']?.toString() ?? ''),
          badge: badge,
          areas: item['areas']?.toString() ?? '',
          styles: item['styles']?.toString() ?? '',
          indexShow: item['index_show']?.toString() ?? '',
          score: scoreVal,
          desc: _stripHtml(item['desc']?.toString() ?? ''),
          seasonType: (item['season_type'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    return results;
  }

  /// Lấy Bảng xếp hạng tổng hợp hoặc theo từng phân khu (`/x/web-interface/ranking/v2`)
  Future<List<BilibiliAnimeItem>> getZoneRanking({
    int rid = 0,
    String type = 'all',
    String cookie = '',
  }) async {
    Future<List<BilibiliAnimeItem>> fetchRid(int targetRid) async {
      final response = await dio.get<Map<String, dynamic>>(
        'https://api.bilibili.com/x/web-interface/ranking/v2',
        queryParameters: {'rid': '$targetRid', 'type': type},
        options: Options(headers: requestHeaders(cookie)),
      );
      final json = response.data ?? const <String, dynamic>{};
      if ((json['code'] as num?)?.toInt() != 0) return const [];
      final data = json['data'] as Map<String, dynamic>?;
      final list = data?['list'] as List<dynamic>? ?? const [];
      return list
          .whereType<Map>()
          .map((raw) {
            final item = Map<String, dynamic>.from(raw);
            final bvid = item['bvid']?.toString() ?? '';
            final title = _stripHtml(item['title']?.toString() ?? '');
            final cover = _normalizeCoverUrl(item['pic']?.toString() ?? '');
            final durationSec = (item['duration'] as num?)?.toInt() ?? 0;
            final owner = item['owner'] as Map?;
            final author = owner?['name']?.toString() ?? '';
            final upFace = _normalizeCoverUrl(owner?['face']?.toString() ?? '');
            final stat = item['stat'] as Map?;
            final views = stat?['view'];
            final danmaku = stat?['danmaku'];
            final likes = stat?['like'];
            return BilibiliAnimeItem(
              title: title,
              cover: cover,
              bvid: bvid,
              author: author,
              upFace: upFace,
              badge: item['tname']?.toString() ?? '',
              desc: _stripHtml(item['desc']?.toString() ?? ''),
              durationSeconds: durationSec,
              durationText: durationSec > 0 ? BilibiliAnimeItem.formatDuration(durationSec) : '',
              viewCountText: views != null ? _formatCount(views) : '',
              danmakuText: danmaku != null ? _formatCount(danmaku) : '',
              likeCountText: likes != null ? _formatCount(likes) : '',
              pubdate: _parseUnixSec(item['pubdate']),
            );
          })
          .where((it) => it.bvid != null && it.bvid!.isNotEmpty)
          .toList();
    }

    try {
      final list = await fetchRid(rid);
      if (list.isNotEmpty || rid == 0) return list;
      return await fetchRid(0);
    } catch (_) {
      return const [];
    }
  }

  /// Lấy danh sách từ khóa tìm kiếm thịnh hành
  Future<List<String>> getHotSearchKeywords() async {
    try {
      final response = await dio.get<Map<String, dynamic>>(
        'https://api.bilibili.com/x/web-interface/search/square',
        queryParameters: {'limit': '12'},
        options: Options(headers: requestHeaders()),
      );
      final json = response.data ?? const <String, dynamic>{};
      final list = json['data']?['trending']?['list'] as List<dynamic>? ?? const [];
      return list
          .map((item) => (item['show_name'] ?? item['keyword'])?.toString().trim() ?? '')
          .where((k) => k.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Lấy danh sách video đề xuất / liên quan theo bvid
  Future<List<BilibiliAnimeItem>> getRelatedVideos(
    String bvid, {
    String cookie = '',
  }) async {
    if (bvid.isEmpty) return const [];
    try {
      final response = await dio.get<Map<String, dynamic>>(
        'https://api.bilibili.com/x/web-interface/archive/related',
        queryParameters: {'bvid': bvid},
        options: Options(
          headers: requestHeaders(cookie),
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      final json = response.data;
      if (json == null || json['code'] != 0) return const [];
      final data = json['data'] as List<dynamic>? ?? const [];
      final list = <BilibiliAnimeItem>[];
      for (final item in data) {
        if (item is! Map<String, dynamic>) continue;
        final itemBvid = item['bvid']?.toString() ?? '';
        final title = item['title']?.toString() ?? '';
        final pic = item['pic']?.toString() ?? '';
        final duration = (item['duration'] as num?)?.toInt() ?? 0;
        final owner = item['owner'] as Map<String, dynamic>?;
        final author = owner?['name']?.toString() ?? '';
        final upFace = owner?['face']?.toString() ?? '';
        final stat = item['stat'] as Map<String, dynamic>?;
        final view = stat?['view'];
        final danmaku = stat?['danmaku'];

        list.add(
          BilibiliAnimeItem(
            title: title.replaceAll(RegExp(r'<[^>]*>'), ''),
            cover: pic.startsWith('http://') ? pic.replaceFirst('http://', 'https://') : pic,
            bvid: itemBvid,
            author: author,
            upFace: upFace.startsWith('http://') ? upFace.replaceFirst('http://', 'https://') : upFace,
            durationSeconds: duration,
            durationText: BilibiliAnimeItem.formatDuration(duration),
            viewCountText: view != null ? _formatCount(view) : '',
            danmakuText: danmaku != null ? _formatCount(danmaku) : '',
            pubdate: _parseUnixSec(item['pubdate']),
          ),
        );
      }
      return list;
    } catch (_) {
      return const [];
    }
  }

  /// Lấy danh sách bình luận video Bilibili
  /// [sort]: 2 = Mới nhất, 0 = Nổi bật nhất (Hot)
  Future<BilibiliCommentResult> getComments({
    required int aid,
    int page = 1,
    int pageSize = 20,
    int sort = 2,
    String cookie = '',
  }) async {
    if (aid <= 0) {
      return const BilibiliCommentResult(totalCount: 0, comments: []);
    }
    try {
      final response = await dio.get<Map<String, dynamic>>(
        'https://api.bilibili.com/x/v2/reply',
        queryParameters: {
          'type': '1',
          'oid': aid.toString(),
          'sort': sort.toString(),
          'pn': page.toString(),
          'ps': pageSize.toString(),
        },
        options: Options(headers: requestHeaders(cookie)),
      );
      final json = response.data ?? const <String, dynamic>{};
      final data = json['data'] as Map<String, dynamic>?;
      if (data == null) {
        return const BilibiliCommentResult(totalCount: 0, comments: []);
      }

      final pageInfo = data['page'] as Map<String, dynamic>?;
      final totalCount = (pageInfo?['count'] as num?)?.toInt() ?? 0;
      final rawReplies = data['replies'] as List<dynamic>? ?? const [];

      final comments = <BilibiliCommentItem>[];
      for (final raw in rawReplies) {
        if (raw is! Map<String, dynamic>) continue;
        final c = _parseCommentItem(raw, aid);
        comments.add(c);
      }

      return BilibiliCommentResult(
        totalCount: totalCount,
        comments: comments,
      );
    } catch (_) {
      return const BilibiliCommentResult(totalCount: 0, comments: []);
    }
  }

  BilibiliCommentItem _parseCommentItem(Map<String, dynamic> raw, int defaultOid) {
    final rpid = (raw['rpid'] as num?)?.toInt() ?? 0;
    final oid = (raw['oid'] as num?)?.toInt() ?? defaultOid;
    final mid = (raw['mid'] as num?)?.toInt() ?? 0;
    final member = raw['member'] as Map<String, dynamic>?;
    final uname = member?['uname']?.toString() ?? 'Người dùng';
    final avatar = _normalizeCoverUrl(member?['avatar']?.toString() ?? '');
    final level = (member?['level_info']?['current_level'] as num?)?.toInt() ?? 0;
    final content = raw['content'] as Map<String, dynamic>?;
    final message = content?['message']?.toString() ?? '';
    final ctime = (raw['ctime'] as num?)?.toInt() ?? 0;
    final likeCount = (raw['like'] as num?)?.toInt() ?? 0;
    final rcount = (raw['rcount'] as num?)?.toInt() ?? 0;

    final subList = <BilibiliCommentItem>[];
    final subRepliesRaw = raw['replies'] as List<dynamic>? ?? const [];
    for (final s in subRepliesRaw) {
      if (s is! Map<String, dynamic>) continue;
      subList.add(_parseCommentItem(s, oid));
    }

    return BilibiliCommentItem(
      rpid: rpid,
      oid: oid,
      mid: mid,
      uname: uname,
      avatar: avatar,
      level: level,
      message: message,
      ctime: ctime,
      timeText: _formatTimestamp(ctime),
      likeCount: likeCount,
      replyCount: rcount,
      subReplies: subList,
    );
  }

  static String _formatTimestamp(int timestampSec) {
    if (timestampSec <= 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(timestampSec * 1000);
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inSeconds < 60) return 'Vừa xong';
    if (diff.inMinutes < 60) return '${diff.inMinutes} phút trước';
    if (diff.inHours < 24) return '${diff.inHours} giờ trước';
    if (diff.inDays < 7) return '${diff.inDays} ngày trước';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  /// Lấy thông tin cá nhân của UP (Creator Card)
  Future<BilibiliUploaderProfile?> getUploaderProfile(
    int mid, {
    String cookie = '',
  }) async {
    if (mid <= 0) return null;
    try {
      final response = await dio.get<Map<String, dynamic>>(
        'https://api.bilibili.com/x/web-interface/card',
        queryParameters: {
          'mid': mid.toString(),
          'photo': 'true',
        },
        options: Options(headers: requestHeaders(cookie)),
      );
      final json = response.data ?? const <String, dynamic>{};
      final data = json['data'] as Map<String, dynamic>?;
      if (data == null) return null;
      final card = data['card'] as Map<String, dynamic>?;
      if (card == null) return null;

      final name = card['name']?.toString() ?? '';
      final face = _normalizeCoverUrl(card['face']?.toString() ?? '');
      final sign = card['sign']?.toString() ?? '';
      final fans = (card['fans'] as num?)?.toInt() ?? 0;
      final videoCount = (data['archive_count'] as num?)?.toInt() ?? 0;
      final isFollowing = data['following'] == true;
      final level = (card['level_info']?['current_level'] as num?)?.toInt() ?? 0;

      return BilibiliUploaderProfile(
        mid: mid,
        name: name,
        face: face,
        sign: sign,
        fans: fans,
        fansText: _formatCount(fans),
        videoCount: videoCount,
        isFollowing: isFollowing,
        level: level,
      );
    } catch (_) {
      return null;
    }
  }

  /// Lấy danh sách video do uploader (UP) đăng tải
  Future<List<BilibiliAnimeItem>> getUploaderVideos(
    int mid, {
    String authorName = '',
    int page = 1,
    int pageSize = 30,
    String order = 'pubdate',
    String cookie = '',
  }) async {
    if (mid <= 0 && authorName.trim().isEmpty) return const [];
    try {
      Map<String, dynamic>? data;
      if (mid > 0) {
        try {
          data = await _getWbiJson(
            'https://api.bilibili.com/x/space/wbi/arc/search',
            {
              'mid': mid.toString(),
              'ps': pageSize.toString(),
              'pn': page.toString(),
              'order': order,
            },
            cookie,
          );
        } catch (_) {
          final response = await dio.get<Map<String, dynamic>>(
            'https://api.bilibili.com/x/space/arc/search',
            queryParameters: {
              'mid': mid.toString(),
              'ps': pageSize.toString(),
              'pn': page.toString(),
              'order': order,
            },
            options: Options(headers: requestHeaders(cookie)),
          );
          data = response.data?['data'] as Map<String, dynamic>?;
        }
      }

      final vlist = data?['list']?['vlist'] as List<dynamic>? ?? const [];
      final list = <BilibiliAnimeItem>[];

      for (final raw in vlist) {
        if (raw is! Map<String, dynamic>) continue;
        final bvid = raw['bvid']?.toString() ?? '';
        final title = _stripHtml(raw['title']?.toString() ?? '');
        final cover = _normalizeCoverUrl(raw['pic']?.toString() ?? '');
        final author = raw['author']?.toString() ?? authorName;
        final play = raw['play'];
        final danmaku = raw['video_review'];
        final lengthStr = raw['length']?.toString() ?? '';

        int durationSec = 0;
        if (lengthStr.isNotEmpty) {
          final parts = lengthStr.split(':');
          if (parts.length == 3) {
            final h = int.tryParse(parts[0]) ?? 0;
            final m = int.tryParse(parts[1]) ?? 0;
            final s = int.tryParse(parts[2]) ?? 0;
            durationSec = h * 3600 + m * 60 + s;
          } else if (parts.length == 2) {
            final m = int.tryParse(parts[0]) ?? 0;
            final s = int.tryParse(parts[1]) ?? 0;
            durationSec = m * 60 + s;
          }
        }

        list.add(
          BilibiliAnimeItem(
            title: title,
            cover: cover,
            bvid: bvid,
            author: author,
            durationSeconds: durationSec,
            durationText: lengthStr,
            viewCountText: play != null ? _formatCount(play) : '',
            danmakuText: danmaku != null ? _formatCount(danmaku) : '',
            pubdate: _parseUnixSec(raw['created']),
          ),
        );
      }

      // Nếu API space không trả danh sách và có authorName, fallback sang searchVideos
      if (list.isEmpty && authorName.trim().isNotEmpty) {
        return await searchVideos(
          authorName.trim(),
          page: page,
          pageSize: pageSize,
          order: order,
          cookie: cookie,
        );
      }

      return list;
    } catch (_) {
      if (authorName.trim().isNotEmpty) {
        try {
          return await searchVideos(
            authorName.trim(),
            page: page,
            pageSize: pageSize,
            order: order,
            cookie: cookie,
          );
        } catch (_) {}
      }
      return const [];
    }
  }

  /// Theo dõi / Hủy theo dõi UP trên Bilibili
  Future<bool> modifyRelation({
    required int mid,
    required bool follow,
    required String cookie,
    String csrf = '',
  }) async {
    if (mid <= 0) return false;
    try {
      var biliJct = csrf;
      if (biliJct.isEmpty) {
        final match = RegExp(r'bili_jct=([^;]+)').firstMatch(cookie);
        biliJct = match?.group(1)?.trim() ?? '';
      }
      final response = await dio.post<Map<String, dynamic>>(
        'https://api.bilibili.com/x/relation/modify',
        data: {
          'fid': mid.toString(),
          'act': follow ? '1' : '2',
          're_src': '11',
          'csrf': biliJct,
        },
        options: Options(
          headers: {
            ...requestHeaders(cookie),
            'Content-Type': 'application/x-www-form-urlencoded',
          },
        ),
      );
      final code = (response.data?['code'] as num?)?.toInt() ?? -1;
      return code == 0;
    } catch (_) {
      return false;
    }
  }
}

