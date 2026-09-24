import 'package:dio/dio.dart';

import 'network_header_helper.dart';

class HongguoDramaItem {
  final String seriesId;
  final String title;
  final String cover;
  final int episodeCount;
  final List<String> tags;
  final String intro;
  final List<String> vidList;

  const HongguoDramaItem({
    required this.seriesId,
    required this.title,
    required this.cover,
    required this.episodeCount,
    this.tags = const [],
    this.intro = '',
    this.vidList = const [],
  });
}

class HongguoEpisodeItem {
  final int index; // Tập 1, 2, 3...
  final String vid;
  final String title;

  const HongguoEpisodeItem({
    required this.index,
    required this.vid,
    required this.title,
  });
}

class HongguoDramaDetail {
  final String seriesId;
  final String title;
  final String cover;
  final String intro;
  final int totalEpisodes;
  final List<String> tags;
  final List<HongguoEpisodeItem> episodes;

  const HongguoDramaDetail({
    required this.seriesId,
    required this.title,
    required this.cover,
    required this.intro,
    required this.totalEpisodes,
    this.tags = const [],
    this.episodes = const [],
  });
}

class HongguoBrowseResult {
  final List<HongguoDramaItem> items;
  final int currentPage;
  final int totalPages;
  final int totalItems;

  const HongguoBrowseResult({
    required this.items,
    this.currentPage = 1,
    this.totalPages = 1,
    this.totalItems = 0,
  });
}

class HongguoCategory {
  final String slug;
  final String label;

  const HongguoCategory({required this.slug, required this.label});
}

class HongguoGenre {
  final String slug;
  final String label;

  const HongguoGenre({required this.slug, required this.label});
}

class HongguoResolver {
  static const String siteOrigin = 'https://www.hongguoduanju.com';
  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  final Dio dio;

  HongguoResolver({Dio? dio})
      : dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 30),
                followRedirects: true,
                headers: {
                  'User-Agent': defaultUserAgent,
                  'Accept':
                      'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
                  'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
                  'Referer': '$siteOrigin/',
                },
              ),
            );

  static const List<HongguoCategory> categories = [
    HongguoCategory(slug: 'rank/hot-drama', label: '🔥 Hot Nhất'),
    HongguoCategory(slug: 'category/real-drama', label: '🎬 Người Thật'),
    HongguoCategory(slug: 'category/comic-drama', label: '🎨 Hoạt Hình'),
    HongguoCategory(slug: 'category/ai-drama', label: '🤖 Phim AI'),
  ];

  static const List<HongguoGenre> realDramaGenres = [
    HongguoGenre(slug: '', label: 'Tất cả'),
    HongguoGenre(slug: 'urban', label: 'Đô thị (都市)'),
    HongguoGenre(slug: 'romance', label: 'Tình cảm (爱情)'),
    HongguoGenre(slug: 'comeback', label: 'Nghịch tập (逆袭)'),
    HongguoGenre(slug: 'cute-kids', label: 'Manh bảo (萌宝)'),
    HongguoGenre(slug: 'growth', label: 'Trưởng thành (成长)'),
    HongguoGenre(slug: 'family', label: 'Gia đình (家庭)'),
    HongguoGenre(slug: 'costume', label: 'Cổ trang (古装)'),
    HongguoGenre(slug: 'fantasy', label: 'Huyền huyễn (玄幻)'),
    HongguoGenre(slug: 'period', label: 'Niên đại (年代)'),
    HongguoGenre(slug: 'suspense', label: 'Hồi hộp (悬疑)'),
    HongguoGenre(slug: 'comedy', label: 'Hài hước (喜剧)'),
  ];

  static bool isHongguoUrl(String input) {
    final lower = input.trim().toLowerCase();
    return lower.contains('hongguoduanju.com') ||
        lower.contains('novelquickapp.com') ||
        lower.contains('fanqiesc.com') ||
        lower.contains('qznovelvod.com') ||
        RegExp(r'series_id=\d{6,}').hasMatch(lower) ||
        (RegExp(r'^\d{15,22}$').hasMatch(lower));
  }

  /// Tự động bóc tách series_id từ URL hoặc chuỗi văn bản chia sẻ
  Future<String> resolveSeriesId(String input) async {
    final clean = NetworkHeaderHelper.extractCleanUrl(input);
    final target = clean.isNotEmpty ? clean : input.trim();

    // 1. Kiểm tra nếu input là ID số thuần tuý
    if (RegExp(r'^\d{15,22}$').hasMatch(target)) {
      return target;
    }

    // 2. Tìm query parameter `series_id=...`
    final seriesMatch = RegExp(r'series_id=(\d{6,})').firstMatch(target);
    if (seriesMatch != null) {
      return seriesMatch.group(1)!;
    }

    // 3. Nếu là link rút gọn của app (novelquickapp.com, v.v.), theo vết chuyển hướng
    try {
      final res = await dio.get<dynamic>(
        target,
        options: Options(
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      final realUrl = res.realUri.toString();

      final m1 = RegExp(r'series_id=(\d{6,})').firstMatch(realUrl);
      if (m1 != null) return m1.group(1)!;

      final m2 = RegExp(r'/player/(\d{6,})').firstMatch(realUrl);
      if (m2 != null) return m2.group(1)!;

      final body = res.data?.toString() ?? '';
      final m3 = RegExp(r'"series_id"\s*:\s*"(\d{6,})"').firstMatch(body);
      if (m3 != null) return m3.group(1)!;
    } catch (_) {}

    // Fallback: tìm bất kỳ chuỗi số 18-20 ký tự nào trong input
    final numMatch = RegExp(r'\b(\d{18,20})\b').firstMatch(input);
    if (numMatch != null) {
      return numMatch.group(1)!;
    }

    throw FormatException('Không tìm thấy mã ID phim Hồng Quả trong liên kết.');
  }

  /// Duyệt phim theo danh mục / thể loại và phân trang
  Future<HongguoBrowseResult> browseList({
    String category = 'category/real-drama',
    String genre = '',
    int page = 1,
  }) async {
    var url = '$siteOrigin/$category';
    if (genre.isNotEmpty && !category.startsWith('rank/')) {
      url = '$url/$genre';
    }
    if (page > 1) {
      url = '$url?page=$page';
    }

    final res = await dio.get<String>(url);
    final html = res.data ?? '';

    return _parseDramaList(html, page);
  }

  /// Tìm kiếm phim theo từ khóa
  Future<List<HongguoDramaItem>> search(String keyword) async {
    final cleanKw = keyword.trim();
    if (cleanKw.isEmpty) return [];

    final url = '$siteOrigin/search/${Uri.encodeComponent(cleanKw)}';
    final res = await dio.get<String>(url);
    final html = res.data ?? '';

    final result = _parseDramaList(html, 1);
    return result.items;
  }

  /// Lấy chi tiết bộ phim và danh sách toàn bộ các tập
  Future<HongguoDramaDetail> getDramaDetail(String seriesId) async {
    final cleanId = await resolveSeriesId(seriesId);

    // Mở trang player để lấy đầy đủ vid_list và thông tin phim
    final url = '$siteOrigin/player/$cleanId';
    final res = await dio.get<String>(url);
    final html = res.data ?? '';

    // Tên phim
    var title = _cleanJsonString(_extractMatch(html, r'"series_name"\s*:\s*"([^"]+)"'));
    if (title.isEmpty) {
      title = _cleanJsonString(_extractMatch(html, r'"name"\s*:\s*"([^"]+)"'))
          .replaceAll(RegExp(r'\s*第\d+集.*$'), '');
    }
    if (title.isEmpty) {
      title = 'Phim Hồng Quả #$cleanId';
    }

    // Ảnh bìa
    var cover = _cleanJsonString(_extractMatch(html, r'"series_cover"\s*:\s*"([^"]+)"'));
    if (cover.isEmpty) {
      cover = _cleanJsonString(_extractMatch(html, r'"image"\s*:\s*"([^"]+)"'));
    }
    if (cover.isEmpty) {
      cover = _cleanJsonString(_extractMatch(html, r'"thumbnailUrl"\s*:\s*\[\s*"([^"]+)"'));
    }

    // Tóm tắt nội dung
    final intro = _cleanJsonString(_extractMatch(html, r'"description"\s*:\s*"([^"]+)"'));

    // Danh sách tập (vid_list)
    final vidListMatch = RegExp(r'"vid_list"\s*:\s*\[([^\]]*)\]').firstMatch(html);
    final episodes = <HongguoEpisodeItem>[];

    if (vidListMatch != null) {
      final vids = vidListMatch
          .group(1)!
          .split(',')
          .map((s) => s.replaceAll('"', '').trim())
          .where((s) => s.isNotEmpty && RegExp(r'^\d+$').hasMatch(s))
          .toList();

      for (var i = 0; i < vids.length; i++) {
        episodes.add(
          HongguoEpisodeItem(
            index: i + 1,
            vid: vids[i],
            title: 'Tập ${i + 1}',
          ),
        );
      }
    }

    // Nếu không có vid_list, tìm từ các thẻ player links trong trang detail
    if (episodes.isEmpty) {
      final detailUrl = '$siteOrigin/detail?series_id=$cleanId';
      try {
        final dRes = await dio.get<String>(detailUrl);
        final dHtml = dRes.data ?? '';

        final playerLinks = RegExp(r'/player/\d+/(\d+)').allMatches(dHtml);
        var idx = 2;
        episodes.add(HongguoEpisodeItem(index: 1, vid: cleanId, title: 'Tập 1'));
        final seen = <String>{cleanId};

        for (final m in playerLinks) {
          final vid = m.group(1)!;
          if (seen.add(vid)) {
            episodes.add(
              HongguoEpisodeItem(
                index: idx++,
                vid: vid,
                title: 'Tập ${episodes.length + 1}',
              ),
            );
          }
        }
      } catch (_) {}
    }

    return HongguoDramaDetail(
      seriesId: cleanId,
      title: title,
      cover: cover,
      intro: intro,
      totalEpisodes: episodes.length,
      episodes: episodes,
    );
  }

  /// Lấy trực tiếp link MP4 của một tập phim để phát hoặc tải về
  Future<String> getEpisodePlayUrl(String seriesId, String vid) async {
    final candidates = <String>[
      if (vid.isNotEmpty && vid != seriesId)
        '$siteOrigin/player/$seriesId/$vid',
      '$siteOrigin/player/$seriesId',
      if (vid.isNotEmpty) '$siteOrigin/player/_/$vid',
    ];

    for (final url in candidates) {
      try {
        final res = await dio.get<String>(url);
        final html = res.data ?? '';

        // 1. Thử lấy contentUrl từ VideoObject JSON-LD
        final contentUrl = _cleanJsonString(
          _extractMatch(html, r'"contentUrl"\s*:\s*"([^"]+)"'),
        );
        if (contentUrl.startsWith('http://') || contentUrl.startsWith('https://')) {
          return contentUrl;
        }

        // 2. Thử lấy main_url từ video_model
        final mainUrl = _cleanJsonString(
          _extractMatch(html, r'"main_url"\s*:\s*"([^"]+)"'),
        );
        if (mainUrl.startsWith('http://') || mainUrl.startsWith('https://')) {
          return mainUrl;
        }
      } catch (_) {}
    }

    throw StateError('Không thể lấy liên kết MP4 cho tập phim này.');
  }

  // ===== CÁC HÀM HELPER PARSE HTML NỘI BỘ =====

  HongguoBrowseResult _parseDramaList(String html, int requestedPage) {
    final items = <HongguoDramaItem>[];
    final seen = <String>{};

    // Cách 1: Parse từ SSR JSON nhúng trong HTML (chứa series_name, cover, vid_list, tags...)
    final jsonBlocks = RegExp(r'\{[^{}]*"series_id"\s*:\s*"(\d+)"[^{}]*\}').allMatches(html);
    for (final b in jsonBlocks) {
      final block = b.group(0)!;
      final sid = _extractMatch(block, r'"series_id"\s*:\s*"(\d+)"');
      if (sid.isEmpty || !seen.add(sid)) continue;

      final title = _cleanJsonString(_extractMatch(block, r'"series_name"\s*:\s*"([^"]+)"'));
      if (title.isEmpty) continue;

      final cover = _cleanJsonString(_extractMatch(block, r'"series_cover"\s*:\s*"([^"]+)"'));
      final epRightText = _cleanJsonString(_extractMatch(block, r'"episode_right_text"\s*:\s*"([^"]+)"'));
      final epCntMatch = RegExp(r'(\d+)').firstMatch(epRightText);
      final epCount = epCntMatch != null ? int.tryParse(epCntMatch.group(1)!) ?? 0 : 0;

      final intro = _cleanJsonString(_extractMatch(block, r'"series_intro"\s*:\s*"([^"]+)"'));

      // Tags
      final tagsMatch = RegExp(r'"tags"\s*:\s*\[([^\]]*)\]').firstMatch(block);
      final tags = <String>[];
      if (tagsMatch != null) {
        tags.addAll(
          tagsMatch
              .group(1)!
              .split(',')
              .map((s) => _cleanJsonString(s.replaceAll('"', '').trim()))
              .where((s) => s.isNotEmpty),
        );
      }

      items.add(
        HongguoDramaItem(
          seriesId: sid,
          title: title,
          cover: cover,
          episodeCount: epCount,
          tags: tags,
          intro: intro,
        ),
      );
    }

    // Cách 2: Parse từ HTML DOM links nếu SSR JSON chưa bắt hết
    if (items.isEmpty) {
      final linkCards = RegExp(
        r'<a[^>]+href="[^"]*series_id=(\d+)[^"]*"[^>]*>([\s\S]*?)<\/a>',
      ).allMatches(html);

      for (final card in linkCards) {
        final sid = card.group(1)!;
        if (!seen.add(sid)) continue;

        final content = card.group(2)!;
        final title = _extractMatch(content, r'alt="([^"]+)"').isNotEmpty
            ? _extractMatch(content, r'alt="([^"]+)"')
            : _stripHtml(content);

        final cover = _extractMatch(content, r'src="([^"]+)"');
        final epText = _extractMatch(content, r'全(\d+)集');
        final epCount = int.tryParse(epText) ?? 0;

        if (title.isNotEmpty) {
          items.add(
            HongguoDramaItem(
              seriesId: sid,
              title: title,
              cover: cover,
              episodeCount: epCount,
            ),
          );
        }
      }
    }

    // Pagination
    var pageNum = requestedPage;
    var totalPages = 1;
    var totalItems = items.length;

    final paginationMatch = RegExp(
      r'"pagination"\s*:\s*\{[^}]*"total"\s*:\s*(\d+)[^}]*"pageNum"\s*:\s*(\d+)[^}]*"totalPages"\s*:\s*(\d+)',
    ).firstMatch(html);

    if (paginationMatch != null) {
      totalItems = int.tryParse(paginationMatch.group(1)!) ?? totalItems;
      pageNum = int.tryParse(paginationMatch.group(2)!) ?? pageNum;
      totalPages = int.tryParse(paginationMatch.group(3)!) ?? totalPages;
    }

    return HongguoBrowseResult(
      items: items,
      currentPage: pageNum,
      totalPages: totalPages,
      totalItems: totalItems,
    );
  }

  static String _extractMatch(String text, String pattern) {
    final m = RegExp(pattern).firstMatch(text);
    return m?.group(1) ?? '';
  }

  static String _cleanJsonString(String raw) {
    return raw
        .replaceAll(r'\u002F', '/')
        .replaceAll(r'\u0026', '&')
        .replaceAll('&amp;', '&')
        .trim();
  }

  static String _stripHtml(String html) {
    return html.replaceAll(RegExp(r'<[^>]*>'), '').trim();
  }
}
