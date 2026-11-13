import 'dart:convert';
import 'dart:developer' as developer;

import 'package:dio/dio.dart';

class DouyinTarget {
  final String awemeId;
  final bool isNote;
  final String rawUrl;

  const DouyinTarget({
    required this.awemeId,
    this.isNote = false,
    required this.rawUrl,
  });

  String get canonicalUrl => isNote
      ? 'https://www.douyin.com/note/$awemeId'
      : 'https://www.douyin.com/video/$awemeId';
}

class DouyinQualityOption {
  final String id;
  final String label;
  final int width;
  final int height;
  final int bitrate;
  final int dataSize;
  final bool isH265;
  final List<String> urls;

  const DouyinQualityOption({
    required this.id,
    required this.label,
    required this.width,
    required this.height,
    required this.bitrate,
    required this.dataSize,
    required this.isH265,
    required this.urls,
  });
}

class DouyinVideoDetails {
  final String awemeId;
  final String title;
  final String rawDesc;
  final String author;
  final String? coverUrl;
  final int durationMs;
  final int width;
  final int height;
  final bool isNote;
  final List<String> playUrls;
  final List<DouyinQualityOption> qualityOptions;

  const DouyinVideoDetails({
    required this.awemeId,
    required this.title,
    required this.rawDesc,
    required this.author,
    this.coverUrl,
    required this.durationMs,
    this.width = 0,
    this.height = 0,
    this.isNote = false,
    required this.playUrls,
    this.qualityOptions = const [],
  });

  String get canonicalUrl => isNote
      ? 'https://www.douyin.com/note/$awemeId'
      : 'https://www.douyin.com/video/$awemeId';

  List<String> urlsForQuality([String qualityId = 'auto']) {
    final ordered = <String>[];
    final seen = <String>{};

    void addAll(Iterable<String> items) {
      for (final item in items) {
        final normalized = item.trim();
        if (normalized.isNotEmpty && seen.add(normalized)) {
          ordered.add(normalized);
        }
      }
    }

    if (qualityId != 'auto') {
      final matched = qualityOptions.where((q) => q.id == qualityId).firstOrNull;
      if (matched != null) {
        addAll(matched.urls);
      }
    }
    addAll(playUrls);
    return ordered;
  }
}

class DouyinResolver {
  DouyinResolver({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 15),
              validateStatus: (_) => true,
            ),
          );

  final Dio _dio;

  static const String webUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  static const String mobileUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
  static const String appUserAgent =
      'com.ss.android.ugc.aweme/270101 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TD1A.220804.031; Cronet/TTNetVersion:04657795)';

  static const List<String> _feedHosts = [
    'api5-normal-c-hl.amemv.com',
    'api3-normal-c-hl.amemv.com',
    'api5-normal-c-lf.amemv.com',
    'api5-normal-c-lq.amemv.com',
    'api3-normal-c-lf.amemv.com',
    'api-normal.amemv.com',
    'aweme.snssdk.com',
  ];

  static Map<String, String> cdnHeaders() => const {
    'User-Agent': webUserAgent,
    'Referer': 'https://www.douyin.com/',
    'Origin': 'https://www.douyin.com',
  };

  /// Trích xuất URL hợp lệ từ văn bản chia sẻ Douyin (ví dụ đoạn text tiếng Trung copy từ app Douyin).
  static String extractDouyinUrl(String? rawInput) {
    if (rawInput == null) return '';
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) return '';

    final httpRegex = RegExp(
      r'https?://[a-zA-Z0-9\-._~:/?#\[\]@!$&()*+,;=%]+',
    );
    final matches = httpRegex.allMatches(trimmed).toList();
    if (matches.isNotEmpty) {
      String? preferred;
      for (final m in matches) {
        final candidate = _trimTrailingPunctuation(m.group(0)!);
        final lower = candidate.toLowerCase();
        if (lower.contains('douyin.com') || lower.contains('iesdouyin.com')) {
          preferred = candidate;
          break;
        }
      }
      return preferred ?? _trimTrailingPunctuation(matches.first.group(0)!);
    }

    final bareRegex = RegExp(
      r'(?:v\.douyin\.com|www\.douyin\.com|m\.douyin\.com|douyin\.com|www\.iesdouyin\.com|iesdouyin\.com)/[a-zA-Z0-9\-._~:/?#\[\]@!$&()*+,;=%]+',
      caseSensitive: false,
    );
    final bareMatch = bareRegex.firstMatch(trimmed);
    if (bareMatch != null) {
      return 'https://${_trimTrailingPunctuation(bareMatch.group(0)!)}';
    }

    return trimmed;
  }

  static String _trimTrailingPunctuation(String url) {
    return url.replaceFirst(RegExp(r'[,.;!?)】」》"' "'" r'，。！？、]+$'), '');
  }

  /// Kiểm tra link có phải là trang chia sẻ/video Douyin cần resolver tách link MP4 hay không
  /// (không match link CDN `.mp4` trực tiếp như `zjcdn.com` / `douyinvod.com`).
  static bool isDouyinPageUrl(String? input) {
    final clean = extractDouyinUrl(input);
    if (clean.isEmpty) return false;

    final uri = Uri.tryParse(clean);
    if (uri == null || uri.host.isEmpty) {
      return RegExp(
        r'https?://(?:v\.douyin\.com|(?:www\.|m\.)?(?:ies)?douyin\.com)/',
        caseSensitive: false,
      ).hasMatch(clean);
    }

    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    if (path.endsWith('.mp4') ||
        path.endsWith('.m4a') ||
        path.endsWith('.m3u8') ||
        path.endsWith('.mp3')) {
      return false;
    }

    if (host == 'v.douyin.com') return true;

    if (host == 'iesdouyin.com' || host.endsWith('.iesdouyin.com')) {
      return path.contains('/share/video') ||
          path.contains('/share/note') ||
          path.contains('/video/') ||
          extractAwemeId(clean) != null;
    }

    if (host == 'douyin.com' || host.endsWith('.douyin.com')) {
      return path.contains('/video/') ||
          path.contains('/note/') ||
          uri.queryParameters.containsKey('modal_id') ||
          uri.queryParameters.containsKey('vid') ||
          extractAwemeId(clean) != null;
    }

    return false;
  }

  /// Kiểm tra rộng hơn cho URL/CDN/tài nguyên thuộc Douyin (phục vụ gắn header / nhận diện nguồn).
  static bool isDouyinUrl(String? input) {
    if (input == null || input.trim().isEmpty) return false;
    if (isDouyinPageUrl(input)) return true;
    final clean = extractDouyinUrl(input);
    final uri = Uri.tryParse(clean);
    final host = uri?.host.toLowerCase() ?? clean.toLowerCase();
    return host.contains('douyin.com') ||
        host.contains('iesdouyin.com') ||
        host.contains('douyinvod.com') ||
        host.contains('amemv.com') ||
        host.contains('zjcdn.com') ||
        host.contains('douyinpic.com');
  }

  /// Trích xuất `aweme_id` (15-22 chữ số) từ các dạng URL Douyin chuẩn.
  static String? extractAwemeId(String input) {
    final clean = extractDouyinUrl(input);
    if (clean.isEmpty) return null;

    final queryMatch = RegExp(
      r'(?:modal_id|aweme_id|item_ids|vid)=(\d{15,22})',
      caseSensitive: false,
    ).firstMatch(clean);
    if (queryMatch != null) return queryMatch.group(1);

    final pathMatch = RegExp(
      r'/(?:share/)?(?:video|note)/(\d{15,22})',
      caseSensitive: false,
    ).firstMatch(clean);
    if (pathMatch != null) return pathMatch.group(1);

    if (clean.toLowerCase().contains('douyin.com')) {
      final fallback = RegExp(r'\b(\d{18,22})\b').firstMatch(clean);
      if (fallback != null) return fallback.group(1);
    }

    return null;
  }

  /// Chuyển URL phát có watermark (`/playwm/`) sang URL không watermark (`/play/`).
  static String toNoWatermarkUrl(String url) {
    return url
        .replaceAll('/aweme/v1/playwm/', '/aweme/v1/play/')
        .replaceAll('playwm?', 'play?')
        .replaceAll('/playwm/', '/play/');
  }

  /// Giải link rút gọn `v.douyin.com/...` hoặc URL Douyin đầy đủ thành `DouyinTarget` chứa `awemeId`.
  Future<DouyinTarget> resolveTarget(String rawInput) async {
    final cleanUrl = extractDouyinUrl(rawInput);
    if (cleanUrl.isEmpty ||
        (!cleanUrl.startsWith('http://') && !cleanUrl.startsWith('https://'))) {
      throw ArgumentError('Link Douyin không hợp lệ: $rawInput');
    }

    final directId = extractAwemeId(cleanUrl);
    if (directId != null) {
      return DouyinTarget(
        awemeId: directId,
        isNote: cleanUrl.toLowerCase().contains('/note/'),
        rawUrl: cleanUrl,
      );
    }

    var currentUrl = cleanUrl;
    var resolvedIsNote = cleanUrl.toLowerCase().contains('/note/');

    for (var hop = 0; hop < 6; hop++) {
      final response = await _dio.get<String>(
        currentUrl,
        options: Options(
          followRedirects: false,
          responseType: ResponseType.plain,
          headers: const {
            'User-Agent': mobileUserAgent,
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
          },
        ),
      );

      final location = response.headers.value('location');
      if (location != null && location.isNotEmpty) {
        final nextUrl = Uri.parse(currentUrl).resolve(location).toString();
        if (nextUrl.toLowerCase().contains('/note/')) {
          resolvedIsNote = true;
        }
        final idFromLocation = extractAwemeId(nextUrl);
        if (idFromLocation != null) {
          return DouyinTarget(
            awemeId: idFromLocation,
            isNote: resolvedIsNote,
            rawUrl: nextUrl,
          );
        }
        currentUrl = nextUrl;
        continue;
      }

      final body = response.data ?? '';
      final idFromHtml = _extractAwemeIdFromHtml(body);
      if (idFromHtml != null) {
        return DouyinTarget(
          awemeId: idFromHtml,
          isNote: resolvedIsNote || body.contains('/share/note/'),
          rawUrl: currentUrl,
        );
      }
      break;
    }

    throw StateError(
      'Không trích xuất được ID video Douyin từ liên kết ($cleanUrl).',
    );
  }

  static String? _extractAwemeIdFromHtml(String html) {
    if (html.isEmpty) return null;
    for (final pattern in [
      RegExp(r'"awemeId"\s*:\s*"(\d{15,22})"'),
      RegExp(r'"aweme_id"\s*:\s*"?(\d{15,22})"?'),
      RegExp(r'"itemId"\s*:\s*"(\d{15,22})"'),
      RegExp(r'/(?:share/)?(?:video|note)/(\d{15,22})'),
    ]) {
      final m = pattern.firstMatch(html);
      if (m != null) return m.group(1);
    }
    return null;
  }

  /// Phân giải đầy đủ metadata & danh sách URL MP4 không watermark từ một link/text Douyin.
  Future<DouyinVideoDetails> resolveVideo(String rawInput) async {
    final target = await resolveTarget(rawInput);
    final awemeId = target.awemeId;

    Exception? lastError;
    for (final host in _feedHosts) {
      try {
        final response = await _dio.get<String>(
          'https://$host/aweme/v1/feed/',
          queryParameters: {'aweme_id': awemeId},
          options: Options(
            responseType: ResponseType.plain,
            headers: const {
              'User-Agent': appUserAgent,
              'Accept': 'application/json',
            },
          ),
        );
        final body = response.data;
        if (response.statusCode == 200 &&
            body != null &&
            body.trimLeft().startsWith('{')) {
          final decoded = jsonDecode(body);
          final details = parseFeedResponseJson(
            decoded,
            expectedAwemeId: awemeId,
            isNoteHint: target.isNote,
          );
          if (details != null) {
            return details;
          }
        }
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        developer.log('[DouyinResolver] Host $host lỗi: $e');
      }
    }

    // Fallback: thử SSR HTML của iesdouyin nếu các mirror feed không phản hồi khớp ID
    try {
      final shareUrl = target.isNote
          ? 'https://www.iesdouyin.com/share/note/$awemeId/'
          : 'https://www.iesdouyin.com/share/video/$awemeId/';
      final response = await _dio.get<String>(
        shareUrl,
        options: Options(
          responseType: ResponseType.plain,
          headers: const {
            'User-Agent': mobileUserAgent,
            'Accept-Language': 'zh-CN,zh;q=0.9',
          },
        ),
      );
      if (response.statusCode == 200 && response.data != null) {
        final ssrDetails = parseShareRouterDataHtml(
          response.data!,
          expectedAwemeId: awemeId,
          isNoteHint: target.isNote,
        );
        if (ssrDetails != null) {
          return ssrDetails;
        }
      }
    } catch (e) {
      lastError = e is Exception ? e : Exception(e.toString());
    }

    if (lastError != null) {
      throw StateError(
        'Không thể lấy luồng video Douyin ($awemeId): $lastError',
      );
    }
    throw StateError(
      'Không tìm thấy video Douyin ($awemeId). Video có thể đã bị xoá hoặc đặt ở chế độ riêng tư.',
    );
  }

  /// Parse JSON phản hồi từ `/aweme/v1/feed/?aweme_id=...`, chỉ chấp nhận item khớp `expectedAwemeId`.
  static DouyinVideoDetails? parseFeedResponseJson(
    dynamic decoded, {
    required String expectedAwemeId,
    bool isNoteHint = false,
  }) {
    if (decoded is! Map) return null;
    final list = decoded['aweme_list'];
    if (list is! List || list.isEmpty) return null;

    for (final rawItem in list) {
      if (rawItem is! Map) continue;
      final item = Map<String, dynamic>.from(rawItem);
      if (item['aweme_id']?.toString() == expectedAwemeId) {
        return parseAwemeItem(
          item,
          expectedAwemeId: expectedAwemeId,
          isNoteHint: isNoteHint,
        );
      }
    }
    return null;
  }

  /// Parse fallback HTML `window._ROUTER_DATA` trên `iesdouyin.com/share/video/{id}`.
  static DouyinVideoDetails? parseShareRouterDataHtml(
    String html, {
    required String expectedAwemeId,
    bool isNoteHint = false,
  }) {
    final match = RegExp(
      r'window\._ROUTER_DATA\s*=\s*(\{.*?\})\s*;?\s*</script>',
      dotAll: true,
    ).firstMatch(html);
    if (match == null) return null;

    try {
      final routerData = jsonDecode(match.group(1)!);
      if (routerData is! Map) return null;
      final loaderData = routerData['loaderData'];
      if (loaderData is! Map) return null;

      for (final entry in loaderData.values) {
        if (entry is! Map) continue;
        final videoInfoRes = entry['videoInfoRes'];
        if (videoInfoRes is! Map) continue;
        final itemList = videoInfoRes['item_list'];
        if (itemList is! List) continue;
        for (final rawItem in itemList) {
          if (rawItem is! Map) continue;
          final item = Map<String, dynamic>.from(rawItem);
          final id = item['aweme_id']?.toString();
          if (id == null || id == expectedAwemeId) {
            return parseAwemeItem(
              item,
              expectedAwemeId: expectedAwemeId,
              isNoteHint: isNoteHint,
            );
          }
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Chuẩn hoá một `aweme` item thành `DouyinVideoDetails` với danh sách URL không logo ưu tiên H.264.
  static DouyinVideoDetails parseAwemeItem(
    Map<String, dynamic> item, {
    required String expectedAwemeId,
    bool isNoteHint = false,
  }) {
    final awemeId = item['aweme_id']?.toString().trim().isNotEmpty == true
        ? item['aweme_id'].toString().trim()
        : expectedAwemeId;
    final rawDesc = (item['desc'] as String?)?.trim() ?? '';
    final authorMap = item['author'] is Map
        ? Map<String, dynamic>.from(item['author'] as Map)
        : const <String, dynamic>{};
    final author = (authorMap['nickname'] as String?)?.trim() ?? '';

    final video = item['video'] is Map
        ? Map<String, dynamic>.from(item['video'] as Map)
        : null;
    final images = item['images'] is List ? item['images'] as List : const [];

    if (video == null ||
        (_extractPlayAddrUrls(video['play_addr']).isEmpty &&
            _extractPlayAddrUrls(video['play_addr_h264']).isEmpty &&
            (video['bit_rate'] is! List ||
                (video['bit_rate'] as List).isEmpty))) {
      if (images.isNotEmpty) {
        throw StateError(
          'Bài đăng Douyin này là album ảnh ($awemeId), chưa có luồng video MP4.',
        );
      }
      throw StateError('Video Douyin ($awemeId) không chứa luồng phát hợp lệ.');
    }

    final coverUrl =
        _firstUrl(video['cover']) ??
        _firstUrl(video['origin_cover']) ??
        _firstUrl(video['dynamic_cover']);

    var durationMs = (item['duration'] as num?)?.toInt() ?? 0;
    if (durationMs <= 0) {
      durationMs = (video['duration'] as num?)?.toInt() ?? 0;
    }

    final primaryPlayAddr = video['play_addr'] is Map
        ? Map<String, dynamic>.from(video['play_addr'] as Map)
        : const <String, dynamic>{};
    final h264PlayAddr = video['play_addr_h264'] is Map
        ? Map<String, dynamic>.from(video['play_addr_h264'] as Map)
        : const <String, dynamic>{};

    final width =
        (video['width'] as num?)?.toInt() ??
        (primaryPlayAddr['width'] as num?)?.toInt() ??
        0;
    final height =
        (video['height'] as num?)?.toInt() ??
        (primaryPlayAddr['height'] as num?)?.toInt() ??
        0;

    final qualityOptions = _buildQualityOptions(video);

    final orderedUrls = <String>[];
    final seenUrls = <String>{};
    void addUrls(Iterable<String> urls) {
      for (final u in urls) {
        final normalized = toNoWatermarkUrl(u.trim());
        if (normalized.isNotEmpty && seenUrls.add(normalized)) {
          orderedUrls.add(normalized);
        }
      }
    }

    // Ưu tiên luồng H.264 tương thích tốt nhất với MediaCodec / ExoPlayer / AudioExtractor
    addUrls(_extractPlayAddrUrls(h264PlayAddr));

    final primaryIsH265 = (video['is_h265'] as num?)?.toInt() == 1;
    if (!primaryIsH265) {
      addUrls(_extractPlayAddrUrls(primaryPlayAddr));
    }

    for (final opt in qualityOptions.where((q) => !q.isH265)) {
      addUrls(opt.urls);
    }

    addUrls(_extractPlayAddrUrls(primaryPlayAddr));
    for (final opt in qualityOptions) {
      addUrls(opt.urls);
    }

    if (orderedUrls.isEmpty) {
      throw StateError('Không tìm thấy URL phát MP4 trong dữ liệu Douyin.');
    }

    final title = rawDesc.isNotEmpty
        ? rawDesc
        : (author.isNotEmpty ? 'Douyin - $author' : 'Douyin_$awemeId');

    return DouyinVideoDetails(
      awemeId: awemeId,
      title: title,
      rawDesc: rawDesc,
      author: author,
      coverUrl: coverUrl,
      durationMs: durationMs,
      width: width,
      height: height,
      isNote: isNoteHint || (item['aweme_type'] as num?)?.toInt() == 68,
      playUrls: orderedUrls,
      qualityOptions: qualityOptions,
    );
  }

  static List<DouyinQualityOption> _buildQualityOptions(
    Map<String, dynamic> video,
  ) {
    final options = <DouyinQualityOption>[];
    final seenIds = <String>{};

    final rawBitRates = video['bit_rate'];
    if (rawBitRates is List) {
      final parsed = <DouyinQualityOption>[];
      for (final entry in rawBitRates) {
        if (entry is! Map) continue;
        final gearName = (entry['gear_name'] as String?)?.trim() ?? '';
        final bitrate = (entry['bit_rate'] as num?)?.toInt() ?? 0;
        final isH265 =
            (entry['is_h265'] as num?)?.toInt() == 1 ||
            (entry['is_bytevc1'] as num?)?.toInt() == 1;
        final playAddr = entry['play_addr'] is Map
            ? Map<String, dynamic>.from(entry['play_addr'] as Map)
            : const <String, dynamic>{};
        final urls = _extractPlayAddrUrls(
          playAddr,
        ).map(toNoWatermarkUrl).toList();
        if (urls.isEmpty) continue;

        final w = (playAddr['width'] as num?)?.toInt() ?? 0;
        final h = (playAddr['height'] as num?)?.toInt() ?? 0;
        final dataSize = (playAddr['data_size'] as num?)?.toInt() ?? 0;

        final resolutionLabel = _inferResolutionLabel(
          width: w,
          height: h,
          gearName: gearName,
        );
        final mbLabel = dataSize > 0
            ? ' (~${(dataSize / (1024 * 1024)).toStringAsFixed(1)}MB)'
            : '';
        final codecTag = isH265 ? ' HEVC' : '';
        final id =
            '${resolutionLabel.toLowerCase()}_${isH265 ? "h265" : "h264"}';

        parsed.add(
          DouyinQualityOption(
            id: id,
            label: '$resolutionLabel$codecTag$mbLabel',
            width: w,
            height: h,
            bitrate: bitrate,
            dataSize: dataSize,
            isH265: isH265,
            urls: urls,
          ),
        );
      }

      // Sắp xếp H.264 trước, cùng codec sắp theo độ phân giải & bitrate cao nhất trước
      parsed.sort((a, b) {
        if (a.isH265 != b.isH265) return a.isH265 ? 1 : -1;
        final aMaxDim = a.width > a.height ? a.width : a.height;
        final bMaxDim = b.width > b.height ? b.width : b.height;
        if (aMaxDim != bMaxDim) return bMaxDim.compareTo(aMaxDim);
        return b.bitrate.compareTo(a.bitrate);
      });

      for (final opt in parsed) {
        if (seenIds.add(opt.id)) {
          options.add(opt);
        }
      }
    }

    return options;
  }

  static String _inferResolutionLabel({
    required int width,
    required int height,
    required String gearName,
  }) {
    final shortEdge = width > 0 && height > 0
        ? (width < height ? width : height)
        : 0;
    if (shortEdge >= 1000 || gearName.contains('1080')) return '1080p';
    if (shortEdge >= 700 || gearName.contains('720')) return '720p';
    if (shortEdge >= 500 || gearName.contains('540')) return '540p';
    if (shortEdge >= 360 || gearName.contains('480')) return '480p';
    if (gearName.isNotEmpty) return gearName;
    return 'Gốc';
  }

  static List<String> _extractPlayAddrUrls(dynamic rawPlayAddr) {
    if (rawPlayAddr is! Map) return const [];
    final urlList = rawPlayAddr['url_list'];
    if (urlList is! List) return const [];
    return urlList
        .map((e) => e?.toString().trim() ?? '')
        .where((e) => e.startsWith('http://') || e.startsWith('https://'))
        .toList();
  }

  static String? _firstUrl(dynamic rawMediaObj) {
    if (rawMediaObj is! Map) return null;
    final list = rawMediaObj['url_list'];
    if (list is! List || list.isEmpty) return null;
    final first = list.first?.toString().trim();
    return (first != null && first.isNotEmpty) ? first : null;
  }
}
