import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../data/repository/settings_repository.dart';
import 'network_header_helper.dart';
import 'hongguo/hongguo_local_engine.dart';

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
  final bool isAccessible;

  const HongguoEpisodeItem({
    required this.index,
    required this.vid,
    required this.title,
    this.isAccessible = true,
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
  final int accessibleEpisodes;

  const HongguoDramaDetail({
    required this.seriesId,
    required this.title,
    required this.cover,
    required this.intro,
    required this.totalEpisodes,
    this.tags = const [],
    this.episodes = const [],
    this.accessibleEpisodes = 3,
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
    : dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              followRedirects: true,
              headers: {
                'User-Agent': defaultUserAgent,
                'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
                'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
                'Referer': '$siteOrigin/',
              },
            ),
          );

  static const List<HongguoCategory> categories = [
    HongguoCategory(slug: 'discover', label: '✨ Đề Xuất'),
    HongguoCategory(slug: 'rank/hot-drama', label: '🔥 Hot Nhất'),
    HongguoCategory(slug: 'category/real-drama', label: '🎬 Người Thật'),
    HongguoCategory(slug: 'category/comic-drama', label: '🎨 Hoạt Hình'),
    HongguoCategory(slug: 'category/ai-drama', label: '🤖 Phim AI'),
  ];

  static const List<HongguoGenre> realDramaGenres = [
    HongguoGenre(slug: '', label: 'Tất cả'),
    HongguoGenre(slug: 'fantasy', label: 'Tu tiên / Huyền huyễn (修仙)'),
    HongguoGenre(slug: 'youth', label: 'Học đường / Thanh xuân (校园)'),
    HongguoGenre(slug: 'romance', label: 'Tình cảm (爱情)'),
    HongguoGenre(slug: 'clan', label: 'Hào môn / Tổng tài (豪门)'),
    HongguoGenre(slug: 'comeback', label: 'Nghịch tập (逆袭)'),
    HongguoGenre(slug: 'urban', label: 'Đô thị (都市)'),
    HongguoGenre(slug: 'costume', label: 'Cổ trang (古装)'),
    HongguoGenre(slug: 'sci-fi', label: 'Khoa huyễn (科幻)'),
    HongguoGenre(slug: 'action-adventure', label: 'Hành động (动作)'),
    HongguoGenre(slug: 'supernatural', label: 'Linh dị (灵异)'),
    HongguoGenre(slug: 'cute-kids', label: 'Manh bảo (萌宝)'),
    HongguoGenre(slug: 'growth', label: 'Trưởng thành (成长)'),
    HongguoGenre(slug: 'family', label: 'Gia đình (家庭)'),
    HongguoGenre(slug: 'period', label: 'Niên đại (年代)'),
    HongguoGenre(slug: 'suspense', label: 'Hồi hộp (悬疑)'),
    HongguoGenre(slug: 'comedy', label: 'Hài hước (喜剧)'),
  ];

  static const List<HongguoGenre> comicDramaGenres = [
    HongguoGenre(slug: '', label: 'Tất cả Hoạt Hình'),
    HongguoGenre(slug: 'fantasy', label: 'Tu tiên / Huyền huyễn (修仙)'),
    HongguoGenre(slug: 'creative', label: 'Hệ thống / Xuyên không (系统)'),
    HongguoGenre(slug: 'drama', label: 'Tình cảm / Học đường (剧情)'),
    HongguoGenre(slug: 'adventure', label: 'Nhiệt huyết / Phiêu lưu (热血)'),
    HongguoGenre(slug: 'wonder', label: 'Kỳ ảo / Dị giới (奇幻)'),
    HongguoGenre(slug: 'wealthy-family', label: 'Hào môn / Đô thị (豪门)'),
    HongguoGenre(slug: 'apocalypse', label: 'Mạt thế / Sinh tồn (末世)'),
    HongguoGenre(slug: 'sci-fi', label: 'Khoa huyễn (科幻)'),
  ];

  static const List<HongguoGenre> aiDramaGenres = [
    HongguoGenre(slug: '', label: 'Tất cả AI'),
    HongguoGenre(slug: 'fantasy', label: 'Tu tiên / Huyền huyễn (玄幻)'),
    HongguoGenre(slug: 'sci-fi', label: 'Khoa huyễn (科幻)'),
    HongguoGenre(slug: 'wealthy-family', label: 'Hào môn / Tổng tài (豪门)'),
    HongguoGenre(slug: 'apocalypse', label: 'Mạt thế / Sinh tồn (末世)'),
    HongguoGenre(slug: 'creative', label: 'Ý tưởng sáng tạo (脑洞)'),
    HongguoGenre(slug: 'wonder', label: 'Kỳ ảo (奇幻)'),
    HongguoGenre(slug: 'adventure', label: 'Phiêu lưu (冒险)'),
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
    if (category == 'discover') {
      return getRandomRecommendations(genre: genre);
    }

    var url = '$siteOrigin/$category';
    if (genre.isNotEmpty && !category.startsWith('rank/')) {
      url = '$url/$genre';
    }
    if (page > 1) {
      url = '$url?page=$page';
    }

    final res = await dio.get<String>(
      url,
      options: Options(
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    final html = res.data ?? '';

    return _parseDramaList(html, page);
  }

  /// Lấy danh sách phim đề xuất mới ngẫu nhiên (Load phim mới)
  Future<HongguoBrowseResult> getRandomRecommendations({
    String? preferredCategory,
    String? genre,
  }) async {
    final rng = Random();

    // 1. Nếu có chỉ định danh mục cụ thể (vd: Người Thật, Phim AI, Hoạt Hình)
    if (preferredCategory != null &&
        preferredCategory.isNotEmpty &&
        preferredCategory != 'rank/hot-drama' &&
        preferredCategory != 'discover') {
      final maxRand = (genre != null && genre.isNotEmpty) ? 6 : 25;
      final randomPage = rng.nextInt(maxRand) + 1;
      try {
        var res = await browseList(
          category: preferredCategory,
          genre: genre ?? '',
          page: randomPage,
        );
        if (res.items.isEmpty && randomPage > 1) {
          res = await browseList(
            category: preferredCategory,
            genre: genre ?? '',
            page: 1,
          );
        }
        if (res.items.isNotEmpty) {
          final shuffled = List<HongguoDramaItem>.from(res.items)..shuffle(rng);
          return HongguoBrowseResult(
            items: shuffled,
            currentPage: res.currentPage,
            totalPages: res.totalPages,
            totalItems: res.totalItems,
          );
        }
      } catch (_) {}
    }

    // 2. Nếu ở chế độ Tất cả nhưng có chọn thể loại:
    if (genre != null && genre.isNotEmpty) {
      final candidateCats = <String>['category/real-drama'];
      if ([
        'fantasy',
        'sci-fi',
        'creative',
        'apocalypse',
        'wealthy-family',
        'wonder',
        'adventure',
        'drama',
      ].contains(genre)) {
        candidateCats.add('category/comic-drama');
      }
      if ([
        'fantasy',
        'sci-fi',
        'wealthy-family',
        'apocalypse',
        'creative',
        'wonder',
        'adventure',
      ].contains(genre)) {
        candidateCats.add('category/ai-drama');
      }
      final pickedCat = candidateCats[rng.nextInt(candidateCats.length)];
      final randomPage = rng.nextInt(6) + 1;
      try {
        var res = await browseList(
          category: pickedCat,
          genre: genre,
          page: randomPage,
        );
        if (res.items.isEmpty && randomPage > 1) {
          res = await browseList(category: pickedCat, genre: genre, page: 1);
        }
        if (res.items.isNotEmpty) {
          final shuffled = List<HongguoDramaItem>.from(res.items)..shuffle(rng);
          return HongguoBrowseResult(
            items: shuffled,
            currentPage: res.currentPage,
            totalPages: res.totalPages,
            totalItems: res.totalItems,
          );
        }
      } catch (_) {}
    }

    // 3. Nếu không chỉ định thể loại (Đề xuất ngẫu nhiên hoàn toàn):
    final pool = <String>[
      'category/real-drama',
      'category/real-drama',
      'category/comic-drama',
      'category/ai-drama',
      'rank/hot-drama',
      'rank/hot-real-drama',
    ];
    final selectedCat = pool[rng.nextInt(pool.length)];
    final maxPage = selectedCat.startsWith('rank/') ? 5 : 25;
    final randomPage = rng.nextInt(maxPage) + 1;

    try {
      final res = await browseList(
        category: selectedCat,
        genre: '',
        page: randomPage,
      );
      if (res.items.isNotEmpty) {
        final shuffled = List<HongguoDramaItem>.from(res.items)..shuffle(rng);
        return HongguoBrowseResult(
          items: shuffled,
          currentPage: 1,
          totalPages: 10,
          totalItems: res.totalItems > 0 ? res.totalItems : 240,
        );
      }
    } catch (_) {}

    // Fallback: nếu lỗi trang ngẫu nhiên, lấy trang 1 của real-drama
    return browseList(category: 'category/real-drama', page: 1);
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
    var title = _cleanJsonString(
      _extractMatch(html, r'"series_name"\s*:\s*"([^"]+)"'),
    );
    if (title.isEmpty) {
      title = _cleanJsonString(_extractMatch(html, r'"name"\s*:\s*"([^"]+)"'))
          .replaceAll(RegExp(r'\s*第\d+集.*$'), '');
    }
    if (title.isEmpty) {
      title = 'Phim Hồng Quả #$cleanId';
    }

    // Ảnh bìa
    var cover = _normalizeImageUrl(
      _extractMatch(html, r'"series_cover"\s*:\s*"([^"]+)"'),
    );
    if (cover.isEmpty) {
      cover = _normalizeImageUrl(
        _extractMatch(html, r'"image"\s*:\s*"([^"]+)"'),
      );
    }
    if (cover.isEmpty) {
      cover = _normalizeImageUrl(
        _extractMatch(html, r'"thumbnailUrl"\s*:\s*\[\s*"([^"]+)"'),
      );
    }

    // Tóm tắt nội dung
    final intro = _cleanJsonString(
      _extractMatch(html, r'"description"\s*:\s*"([^"]+)"'),
    );

    // Số tập xem được trên nền tảng Web Hồng Quả (mặc định các phim web chỉ mở xem trước 3 tập)
    final accMatch = RegExp(r'"accessible_episode_cnt"\s*:\s*(\d+)')
        .firstMatch(html);
    final accessibleEpisodes = accMatch != null
        ? int.tryParse(accMatch.group(1)!) ?? 3
        : 3;

    // Danh sách tập (vid_list)
    final vidListMatch = RegExp(r'"vid_list"\s*:\s*\[([^\]]*)\]')
        .firstMatch(html);
    final episodes = <HongguoEpisodeItem>[];

    if (vidListMatch != null) {
      final vids = vidListMatch
          .group(1)!
          .split(',')
          .map((s) => s.replaceAll('"', '').trim())
          .where((s) => s.isNotEmpty && RegExp(r'^\d+$').hasMatch(s))
          .toList();

      for (var i = 0; i < vids.length; i++) {
        final epNum = i + 1;
        episodes.add(
          HongguoEpisodeItem(
            index: epNum,
            vid: vids[i],
            title: 'Tập $epNum',
            isAccessible: true, // Mở khóa toàn bộ qua Cloud Resolver
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
        episodes.add(
          HongguoEpisodeItem(
            index: 1,
            vid: cleanId,
            title: 'Tập 1',
            isAccessible: true,
          ),
        );
        final seen = <String>{cleanId};

        for (final m in playerLinks) {
          final vid = m.group(1)!;
          if (seen.add(vid)) {
            final epNum = idx++;
            episodes.add(
              HongguoEpisodeItem(
                index: epNum,
                vid: vid,
                title: 'Tập $epNum',
                isAccessible: true,
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
      totalEpisodes: episodes.isNotEmpty ? episodes.length : accessibleEpisodes,
      episodes: episodes,
      accessibleEpisodes: episodes.isNotEmpty
          ? episodes.length
          : accessibleEpisodes,
    );
  }

  /// URL Server API trên Hugging Face Spaces (sử dụng Sixgod signing engine)
  static const String hfApiBase = 'https://kietno1-hongqua.hf.space';

  /// Giải mã video qua Hugging Face Cloud Resolver
  Future<String?> _resolveFromHfApi(String vid) async {
    try {
      debugPrint('[HongguoResolver] 🌐 Đang gọi Hugging Face Space giải mã video: $vid...');
      final res = await dio.post(
        '$hfApiBase/gradio_api/call/get_play_url',
        data: {
          'data': [vid],
        },
        options: Options(
          receiveTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 15),
        ),
      );

      final eventId = res.data is Map ? res.data['event_id'] : null;
      if (eventId == null) {
        debugPrint('[HongguoResolver] HF không trả về event_id');
        return null;
      }

      final eventRes = await dio.get<String>(
        '$hfApiBase/gradio_api/call/get_play_url/$eventId',
        options: Options(
          responseType: ResponseType.plain,
          receiveTimeout: const Duration(seconds: 80),
        ),
      );

      final lines = (eventRes.data ?? '').split('\n');
      for (final line in lines) {
        if (line.startsWith('data:')) {
          final jsonStr = line.substring(5).trim();
          final parsed = jsonDecode(jsonStr);
          if (parsed is List && parsed.isNotEmpty) {
            if (parsed[0] is Map) {
              final fileData = parsed[0] as Map;
              final url = fileData['url']?.toString();
              if (url != null && url.startsWith('http')) {
                debugPrint('[HongguoResolver] ✅ HF trả về stream URL: $url');
                return url;
              }
            } else if (parsed[0] == null && parsed.length > 1 && parsed[1] is Map) {
              final err = parsed[1] as Map;
              final errMsg = err['error'] ?? 'Server HF báo lỗi xử lý';
              debugPrint('[HongguoResolver] ❌ Server HF báo lỗi xử lý: $errMsg');
              throw StateError('Server HF báo lỗi: $errMsg');
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[HongguoResolver] ❌ Lỗi kết nối HF Cloud: $e');
      rethrow;
    }
    return null;
  }

  /// Lấy trực tiếp link MP4 của một tập phim để phát hoặc tải về
  Future<String> getEpisodePlayUrl(
    String seriesId,
    String vid, {
    int episodeIndex = 1,
  }) async {
    final actualVid = (vid.isNotEmpty && vid != seriesId) ? vid : '';

    // Khi có Video ID: Chạy duy nhất engine đã chọn để kiểm tra độc lập tốc độ & lỗi (Fallback: TẮT)
    if (actualVid.isNotEmpty) {
      final settings = await SettingsRepository.getInstance();
      final engine = settings.hongguoVideoResolverEngine;
      debugPrint(
        '[HongguoResolver] ⚡ Đang chạy duy nhất engine: '
        '${engine == 'hf' ? 'Hugging Face Space' : 'LOCAL ON-DEVICE'} '
        'cho tập $episodeIndex (Fallback: ĐÃ TẮT)',
      );

      if (engine == 'local') {
        // Chạy Local Engine thuần túy trên thiết bị (không fallback sang HF)
        return await HongguoLocalEngine.resolveAndGetPlayableUrl(
          seriesId,
          actualVid,
          episodeIndex: episodeIndex,
        );
      } else {
        // Chạy Hugging Face Space thuần túy (không fallback sang Local)
        final hfPlayUrl = await _resolveFromHfApi(actualVid);
        if (hfPlayUrl != null && hfPlayUrl.isNotEmpty) {
          return hfPlayUrl;
        }
        throw StateError(
          'Hugging Face không trả về link phát cho tập $episodeIndex.',
        );
      }
    }

    // Chỉ dùng web public khi không có Video ID cụ thể
    final candidates = <String>[
      if (vid.isNotEmpty && vid != seriesId)
        '$siteOrigin/player/$seriesId/$vid',
      if (episodeIndex == 1 || vid.isEmpty || vid == seriesId)
        '$siteOrigin/player/$seriesId',
      if (vid.isNotEmpty && vid != seriesId) '$siteOrigin/player/_/$vid',
    ];

    for (final url in candidates) {
      try {
        final res = await dio.get<String>(
          url,
          options: Options(
            validateStatus: (status) => status != null && status < 400,
          ),
        );
        final html = res.data ?? '';

        final contentUrl = _cleanJsonString(
          _extractMatch(html, r'"contentUrl"\s*:\s*"([^"]+)"'),
        );
        if (contentUrl.startsWith('http://') ||
            contentUrl.startsWith('https://')) {
          return contentUrl;
        }

        final mainUrl = _cleanJsonString(
          _extractMatch(html, r'"main_url"\s*:\s*"([^"]+)"'),
        );
        if (mainUrl.startsWith('http://') || mainUrl.startsWith('https://')) {
          return mainUrl;
        }
      } catch (_) {}
    }

    if (episodeIndex > 1) {
      throw StateError(
        'Không thể lấy liên kết MP4 cho tập $episodeIndex (Fallback đang tắt).',
      );
    }
    throw StateError('Không thể lấy liên kết MP4 cho tập phim này.');
  }

  // ===== CÁC HÀM HELPER PARSE HTML NỘI BỘ =====

  HongguoBrowseResult _parseDramaList(String html, int requestedPage) {
    final items = <HongguoDramaItem>[];
    final seen = <String>{};

    // Cách 1: Parse từ SSR JSON nhúng trong HTML (chứa series_name, cover, vid_list, tags...)
    final jsonBlocks = RegExp(r'\{[^{}]*"series_id"\s*:\s*"(\d+)"[^{}]*\}')
        .allMatches(html);
    for (final b in jsonBlocks) {
      final block = b.group(0)!;
      final sid = _extractMatch(block, r'"series_id"\s*:\s*"(\d+)"');
      if (sid.isEmpty || !seen.add(sid)) continue;

      final title = _cleanDramaTitle(
        _extractMatch(block, r'"series_name"\s*:\s*"([^"]+)"'),
      );
      if (title.isEmpty) continue;

      final cover = _normalizeImageUrl(
        _extractMatch(block, r'"series_cover"\s*:\s*"([^"]+)"'),
      );
      final epRightText = _cleanJsonString(
        _extractMatch(block, r'"episode_right_text"\s*:\s*"([^"]+)"'),
      );
      final epCntMatch = RegExp(r'(\d+)').firstMatch(epRightText);
      final epCount = epCntMatch != null
          ? int.tryParse(epCntMatch.group(1)!) ?? 0
          : 0;

      final intro = _cleanJsonString(
        _extractMatch(block, r'"series_intro"\s*:\s*"([^"]+)"'),
      );

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
        var title = _extractMatch(content, r'alt="([^"]+)"').isNotEmpty
            ? _extractMatch(content, r'alt="([^"]+)"')
            : _stripHtml(content);
        title = _cleanDramaTitle(title);

        final cover = _normalizeImageUrl(
          _extractMatch(content, r'src="([^"]+)"'),
        );
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
    } else {
      // Bóc tách số trang nếu SSR không trả JSON pagination (như trang bảng xếp hạng rank/hot-drama)
      final pageLinks = RegExp(r'[?&]page=(\d+)').allMatches(html);
      if (pageLinks.isNotEmpty) {
        var maxP = 1;
        for (final m in pageLinks) {
          final p = int.tryParse(m.group(1)!) ?? 1;
          if (p > maxP) maxP = p;
        }
        totalPages = maxP;
        totalItems = maxP * items.length;
      }
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
        .replaceAll(r'\/', '/')
        .replaceAll('&amp;', '&')
        .trim();
  }

  static String _normalizeImageUrl(String raw) {
    var clean = _cleanJsonString(raw);
    if (clean.isEmpty) return '';
    if (clean.startsWith('//')) {
      clean = 'https:$clean';
    } else if (clean.startsWith('http://')) {
      clean = clean.replaceFirst('http://', 'https://');
    }
    return clean;
  }

  static String _cleanDramaTitle(String raw) {
    return _cleanJsonString(raw).replaceAll(RegExp(r'封面$'), '').trim();
  }

  static String _stripHtml(String html) {
    return html.replaceAll(RegExp(r'<[^>]*>'), '').trim();
  }
}
