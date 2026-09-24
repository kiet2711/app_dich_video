class NetworkHeaderHelper {
  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  static bool isRemoteUri(String? uri) {
    if (uri == null || uri.trim().isEmpty) return false;
    final lower = uri.trim().toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  static bool isRemoteUrl(String? url) => isRemoteUri(url);

  /// Tự động lọc và bóc tách URL sạch từ chuỗi văn bản (kể cả khi người dùng dán kèm tiêu đề, icon, tiếng Trung từ nút Share).
  /// Ví dụ: "【免费观看...】 https://b23.tv/xyz" -> "https://b23.tv/xyz"
  static String extractCleanUrl(String? input) {
    if (input == null || input.trim().isEmpty) return '';
    final trimmed = input.trim();

    // 1. Tìm URL dạng https://... hoặc http://...
    final httpRegex = RegExp(r'https?://[^\s]+');
    final httpMatch = httpRegex.firstMatch(trimmed);
    if (httpMatch != null) {
      return httpMatch.group(0)!;
    }

    // 2. Tìm link rút gọn b23.tv/...
    final b23Regex = RegExp(r'b23\.tv/[a-zA-Z0-9]+');
    final b23Match = b23Regex.firstMatch(trimmed);
    if (b23Match != null) {
      return 'https://${b23Match.group(0)}';
    }

    // 3. Tìm mã BV...
    final bvRegex = RegExp(r'BV[a-zA-Z0-9]{10}', caseSensitive: false);
    final bvMatch = bvRegex.firstMatch(trimmed);
    if (bvMatch != null) {
      return 'https://www.bilibili.com/video/${bvMatch.group(0)}';
    }

    // 4. Tìm mã av...
    final avRegex = RegExp(r'av(\d+)', caseSensitive: false);
    final avMatch = avRegex.firstMatch(trimmed);
    if (avMatch != null) {
      return 'https://www.bilibili.com/video/${avMatch.group(0)}';
    }

    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      return 'https://$trimmed';
    }
    return trimmed;
  }

  static Map<String, String> getHeadersForUri(String? uri, [String? cookie]) {
    return getHeadersForUrl(uri, cookie);
  }

  static Map<String, String> getHeadersForUrl(String? url, [String? cookie]) {
    if (url == null || url.trim().isEmpty) return {};
    final lower = url.trim().toLowerCase();
    final headers = <String, String>{
      'User-Agent': defaultUserAgent,
    };

    if (lower.contains('bilivideo.com') ||
        lower.contains('bilibili.com') ||
        lower.contains('biliapi.net')) {
      headers['Referer'] = 'https://www.bilibili.com/';
      headers['Origin'] = 'https://www.bilibili.com';
      if (cookie != null && cookie.trim().isNotEmpty) {
        final formatted =
            cookie.contains('=') ? cookie.trim() : 'SESSDATA=${cookie.trim()}';
        headers['Cookie'] = formatted;
      }
    } else if (lower.contains('hongguoduanju.com') ||
        lower.contains('novelquickapp.com') ||
        lower.contains('qznovelvod.com') ||
        lower.contains('fanqiesc.com') ||
        lower.contains('fqnovel.com')) {
      headers['Referer'] = 'https://www.hongguoduanju.com/';
      headers['Origin'] = 'https://www.hongguoduanju.com';
    } else if (lower.contains('douyin.com') ||
        lower.contains('douyinvod.com') ||
        lower.contains('iesdouyin.com')) {
      headers['Referer'] = 'https://www.douyin.com/';
      headers['Origin'] = 'https://www.douyin.com';
    } else if (lower.contains('tiktok.com') || lower.contains('tiktokv.com')) {
      headers['Referer'] = 'https://www.tiktok.com/';
      headers['Origin'] = 'https://www.tiktok.com';
    } else if (lower.contains('kuaishou.com') || lower.contains('yximgs.com')) {
      headers['Referer'] = 'https://www.kuaishou.com/';
    }

    return headers;
  }

  static String getSuggestedTitle(String url) {
    try {
      final uri = Uri.parse(url);
      final host = uri.host.toLowerCase();
      final lastPathSegment =
          uri.pathSegments.isNotEmpty ? uri.pathSegments.last : null;

      final sourceTag = switch (host) {
        _ when host.contains('bilivideo') || host.contains('bilibili') => 'Bilibili',
        _ when host.contains('hongguo') || host.contains('qznovel') || host.contains('novelquickapp') => 'Hồng Quả',
        _ when host.contains('douyin') => 'Douyin',
        _ when host.contains('tiktok') => 'TikTok',
        _ when host.contains('kuaishou') => 'Kuaishou',
        _ when host.contains('youtube') || host.contains('googlevideo') => 'YouTube',
        _ => host.isNotEmpty ? host : 'Online',
      };

      if (lastPathSegment != null && lastPathSegment.contains('.')) {
        final cleanName =
            lastPathSegment.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), '');
        if (cleanName.length >= 3 && cleanName.length <= 40) {
          return '$sourceTag - $cleanName';
        }
      }

      return 'Video Online ($sourceTag)';
    } catch (_) {
      return 'Video Online';
    }
  }
}
