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
  });

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

  static int _scoreCdnUrl(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('mirroraliov') || lower.contains('aliov')) return 100;
    if (lower.contains('akamai')) return 90;
    if (lower.contains('mirrorcos')) return 80;
    if (lower.contains('upcdnbov')) return 75;
    if (lower.contains('mirrorali')) return 60;
    if (lower.contains('mirrorhw')) return 50;
    if (lower.contains('cn-')) return 10;
    return 40;
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
    final initialList = rawUrls
        .map((url) => url.trim())
        .where((url) => url.startsWith('http://') || url.startsWith('https://'))
        .toSet()
        .toList();

    // Sinh thêm link mirror quốc tế tốc độ cao nếu URL chứa cấu trúc UPOS
    final synthesized = <String>[];
    for (final u in initialList) {
      final uri = Uri.tryParse(u);
      if (uri != null && uri.path.contains('/upos/')) {
        synthesized.add(uri.replace(host: 'upos-sz-mirroraliov.bilivideo.com').toString());
        synthesized.add(uri.replace(host: 'upos-sz-mirrorakamai.bilivideo.com').toString());
        synthesized.add(uri.replace(host: 'upos-sz-upcdnbov.bilivideo.com').toString());
      }
    }

    final allUrls = {...synthesized, ...initialList}.toList();
    allUrls.sort((a, b) => _scoreCdnUrl(b).compareTo(_scoreCdnUrl(a)));
    return allUrls;
  }

  Future<List<BilibiliSubtitleInfo>> getSubtitles(
    BilibiliVideoDetails details, [
    String cookie = '',
  ]) async {
    var loginRequired = false;

    // 1. Thử endpoint x/player/v2
    try {
      final response = await dio.get<Map<String, dynamic>>(
        'https://api.bilibili.com/x/player/v2',
        queryParameters: {
          'aid': details.aid.toString(),
          'cid': details.cid.toString(),
        },
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
      // Tiếp tục thử fallback
    }

    // 2. Thử endpoint Danmaku & Subtitle (x/v2/dm/view)
    // Endpoint này được web/app Bilibili sử dụng công khai, trả về phụ đề CC/AI mà không yêu cầu login
    try {
      final response = await dio.get<Map<String, dynamic>>(
        'https://api.bilibili.com/x/v2/dm/view',
        queryParameters: {
          'type': '1',
          'oid': details.cid.toString(),
          'pid': details.aid.toString(),
        },
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

    // 3. Thử endpoint WBI v2
    try {
      final data = await _getWbiJson('https://api.bilibili.com/x/player/wbi/v2', {
        'aid': details.aid.toString(),
        'bvid': details.bvid,
        'cid': details.cid.toString(),
      }, cookie);
      if (data['need_login_subtitle'] == true) {
        loginRequired = true;
      }
      final list = parseSubtitles(data, throwOnLoginRequired: false);
      if (list.isNotEmpty) return list;
    } catch (_) {
      // Bỏ qua
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
    final list = subtitle?['subtitles'] as List<dynamic>? ?? const [];
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
        );
      }).where((it) => it.bvid != null && it.bvid!.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Lấy danh sách phim AI / AI漫剧 / AI短剧
  Future<List<BilibiliAnimeItem>> getAiManhuaVideos({
    String keyword = 'AI漫剧',
    int page = 1,
    int pageSize = 20,
    String order = 'totalrank', // totalrank, click (xem nhiều), pubdate (mới nhất)
    String cookie = '',
  }) async {
    return searchVideos(
      keyword,
      page: page,
      pageSize: pageSize,
      order: order,
      cookie: cookie,
    );
  }

  /// Tìm kiếm video trên Bilibili
  Future<List<BilibiliAnimeItem>> searchVideos(
    String keyword, {
    int page = 1,
    int pageSize = 20,
    String order = 'totalrank',
    String cookie = '',
  }) async {
    final cleanKeyword = keyword.trim();
    if (cleanKeyword.isEmpty) return const [];

    Map<String, dynamic>? data;
    try {
      data = await _getWbiJson(
        'https://api.bilibili.com/x/web-interface/wbi/search/type',
        {
          'search_type': 'video',
          'keyword': cleanKeyword,
          'page': '$page',
          'page_size': '$pageSize',
          'order': order,
        },
        cookie,
      );
    } catch (_) {
      // Fallback sang search thông thường nếu WBI fail
      final response = await dio.get<Map<String, dynamic>>(
        'https://api.bilibili.com/x/web-interface/search/type',
        queryParameters: {
          'search_type': 'video',
          'keyword': cleanKeyword,
          'page': '$page',
          'page_size': '$pageSize',
          'order': order,
        },
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
        badge: '',
        durationSeconds: durationSeconds,
        durationText: durationText,
        viewCountText: play != null ? _formatCount(play) : '',
        danmakuText: danmaku != null ? _formatCount(danmaku) : '',
      );
    }).toList();
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

