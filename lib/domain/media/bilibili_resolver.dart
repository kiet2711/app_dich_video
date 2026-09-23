import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

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

class BilibiliVideoDetails {
  final String bvid;
  final int aid;
  final int cid;
  final String title;
  final int durationSeconds;

  const BilibiliVideoDetails({
    required this.bvid,
    required this.aid,
    required this.cid,
    required this.title,
    required this.durationSeconds,
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
  String? _cachedImgKey;
  String? _cachedSubKey;
  DateTime? _wbiFetchedAt;

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
        RegExp(r'BV[a-zA-Z0-9]{10}', caseSensitive: false).hasMatch(value) ||
        RegExp(r'av\d+', caseSensitive: false).hasMatch(value);
  }

  static bool isBilibiliPageUrl(String input) {
    final lower = input.trim().toLowerCase();
    return isBilibiliUrl(input) &&
        !lower.contains('bilivideo.com') &&
        !lower.contains('biliapi');
  }

  static Map<String, String> requestHeaders([String cookie = '']) {
    final trimmed = cookie.trim();
    final sessData = trimmed.isEmpty
        ? ''
        : trimmed.contains('SESSDATA=')
        ? trimmed
        : 'SESSDATA=$trimmed';
    return {
      'User-Agent': _userAgent,
      'Referer': _referer,
      'Origin': 'https://www.bilibili.com',
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Cookie': sessData.isEmpty
          ? 'CURRENT_FNVAL=4048'
          : '$sessData; CURRENT_FNVAL=4048',
    };
  }

  Future<BilibiliTarget> resolveUrl(String input) async {
    var target =
        RegExp(r'https?://[^\s]+').firstMatch(input.trim())?.group(0) ??
        input.trim();
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
      r'BV[a-zA-Z0-9]{10}',
      caseSensitive: false,
    ).firstMatch(target)?.group(0);
    final aid = RegExp(
      r'av(\d+)',
      caseSensitive: false,
    ).firstMatch(target)?.group(1);
    final page =
        int.tryParse(
          RegExp(
                r'[?&]p=(\d+)',
                caseSensitive: false,
              ).firstMatch(target)?.group(1) ??
              '',
        ) ??
        1;
    if (bvid == null && aid == null) {
      throw FormatException('Không tìm thấy mã BV/av trong link Bilibili.');
    }
    return BilibiliTarget(
      bvid: bvid,
      aid: aid,
      pageIndex: page,
      rawUrl: target,
    );
  }

  Future<BilibiliVideoDetails> getVideoDetails(
    BilibiliTarget target, [
    String cookie = '',
  ]) async {
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
    final pages = (data['pages'] as List<dynamic>? ?? const []);
    var cid = (data['cid'] as num?)?.toInt() ?? 0;
    var pageDuration = 0;
    for (final raw in pages) {
      final page = raw as Map<String, dynamic>;
      if ((page['page'] as num?)?.toInt() == target.pageIndex) {
        cid = (page['cid'] as num?)?.toInt() ?? cid;
        pageDuration = (page['duration'] as num?)?.toInt() ?? 0;
      }
    }
    if (cid == 0 && pages.isNotEmpty) {
      cid =
          ((pages.first as Map<String, dynamic>)['cid'] as num?)?.toInt() ?? 0;
    }
    if (cid == 0) throw StateError('Bilibili không trả CID của video.');

    return BilibiliVideoDetails(
      bvid: data['bvid']?.toString() ?? target.bvid ?? '',
      aid: (data['aid'] as num?)?.toInt() ?? 0,
      cid: cid,
      title: data['title']?.toString() ?? 'Video Bilibili',
      durationSeconds: pageDuration > 0
          ? pageDuration
          : ((data['duration'] as num?)?.toInt() ?? 0),
    );
  }

  Future<String> getAudioUrl(
    BilibiliVideoDetails details, [
    String cookie = '',
  ]) async {
    final data = await _getPlayData(details, cookie, fnval: '4048');
    final dash = data['dash'] as Map<String, dynamic>?;
    final audio = dash?['audio'] as List<dynamic>? ?? const [];
    if (audio.isEmpty) throw StateError('Bilibili không trả track audio DASH.');
    audio.sort(
      (a, b) => ((b as Map<String, dynamic>)['bandwidth'] as num? ?? 0)
          .compareTo((a as Map<String, dynamic>)['bandwidth'] as num? ?? 0),
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
  ]) async {
    final urls = await getMuxedVideoUrls(details, cookie);
    return urls.first;
  }

  Future<List<String>> getMuxedVideoUrls(
    BilibiliVideoDetails details, [
    String cookie = '',
  ]) async {
    final data = await _getPlayData(details, cookie, fnval: '0', quality: '80');
    final urls = extractMuxedVideoUrls(data);
    if (urls.isEmpty) {
      throw StateError('Bilibili không trả luồng video MP4 tương thích iOS.');
    }
    return urls;
  }

  static List<String> extractMuxedVideoUrls(Map<String, dynamic> data) {
    final durl = data['durl'] as List<dynamic>? ?? const [];
    if (durl.isEmpty || durl.first is! Map<String, dynamic>) return const [];
    final first = durl.first as Map<String, dynamic>;
    final urls = <String>[
      first['url']?.toString() ?? '',
      ...(first['backup_url'] as List<dynamic>? ?? const []).map(
        (url) => url.toString(),
      ),
      ...(first['backupUrl'] as List<dynamic>? ?? const []).map(
        (url) => url.toString(),
      ),
    ];
    return urls
        .map((url) => url.trim())
        .where((url) => url.startsWith('http://') || url.startsWith('https://'))
        .toSet()
        .toList(growable: false);
  }

  Future<List<BilibiliSubtitleInfo>> getSubtitles(
    BilibiliVideoDetails details, [
    String cookie = '',
  ]) async {
    try {
      final data = await _getWbiJson(
        'https://api.bilibili.com/x/player/wbi/v2',
        {'bvid': details.bvid, 'cid': details.cid.toString()},
        cookie,
      );
      final subtitle = data['subtitle'] as Map<String, dynamic>?;
      final list = subtitle?['subtitles'] as List<dynamic>? ?? const [];
      return list
          .map((raw) {
            final item = raw as Map<String, dynamic>;
            var url = item['subtitle_url']?.toString() ?? '';
            if (url.startsWith('//')) url = 'https:$url';
            final language = item['lan']?.toString() ?? '';
            return BilibiliSubtitleInfo(
              language: language,
              languageName: item['lan_doc']?.toString() ?? language,
              isAi:
                  language.startsWith('ai-') ||
                  (item['ai_type'] as num?)?.toInt() == 1,
              url: url,
            );
          })
          .where((item) => item.url.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<SubtitleDocument?> downloadSubtitle(
    BilibiliSubtitleInfo subtitle,
  ) async {
    final response = await dio.get<Map<String, dynamic>>(
      subtitle.url,
      options: Options(headers: requestHeaders()),
    );
    final body = response.data?['body'] as List<dynamic>? ?? const [];
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
    void Function(double progress, String message)? onProgress,
  }) async {
    await destination.parent.create(recursive: true);
    await dio.download(
      audioUrl,
      destination.path,
      options: Options(headers: requestHeaders(cookie)),
      onReceiveProgress: (received, total) {
        final progress = total > 0 ? received / total : 0.0;
        onProgress?.call(
          progress,
          'Đang tải audio Bilibili ${(progress * 100).round()}%',
        );
      },
    );
    if (!await destination.exists() || await destination.length() < 1024) {
      throw StateError('Audio tải từ Bilibili không hợp lệ.');
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
        now.difference(_wbiFetchedAt!) < const Duration(minutes: 30)) {
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
}
