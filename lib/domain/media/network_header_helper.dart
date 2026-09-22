class NetworkHeaderHelper {
  static bool isRemoteUri(String uri) {
    final lower = uri.toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  static Map<String, String> getHeadersForUri(String uri) {
    final lower = uri.toLowerCase();
    if (lower.contains('bilibili.com') || lower.contains('bilivideo.com')) {
      return {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Referer': 'https://www.bilibili.com/',
        'Origin': 'https://www.bilibili.com',
      };
    }
    return {'User-Agent': 'CapSub-Studio/2.0'};
  }
}
