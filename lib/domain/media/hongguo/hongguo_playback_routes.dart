/// Quản lý sức khoẻ & thời gian hồi (cooldown) theo từng host CDN khi phát/tải stream Hongguo.
class HongguoPlaybackRoutes {
  HongguoPlaybackRoutes._();
  static final HongguoPlaybackRoutes instance = HongguoPlaybackRoutes._();

  static const Duration defaultCooldown = Duration(minutes: 5);
  final Map<String, DateTime> _hostCooldownUntil = <String, DateTime>{};

  void markFailed(String url, {Duration cooldown = defaultCooldown}) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return;
    _hostCooldownUntil[host] = DateTime.now().add(cooldown);
  }

  void markHealthy(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return;
    _hostCooldownUntil.remove(host);
  }

  bool isCooledDown(String url, {DateTime? now}) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return false;
    final until = _hostCooldownUntil[host];
    if (until == null) return false;
    final t = now ?? DateTime.now();
    if (!t.isBefore(until)) {
      _hostCooldownUntil.remove(host);
      return false;
    }
    return true;
  }

  /// Sắp xếp lại danh sách URL ứng viên: host khoẻ đứng trước, host đang cooldown đứng sau.
  List<String> orderUrls(List<String> candidates, {DateTime? now}) {
    final unique = <String>[];
    final seen = <String>{};
    for (final raw in candidates) {
      final url = raw.trim();
      if (url.isNotEmpty && seen.add(url)) {
        unique.add(url);
      }
    }
    if (unique.length <= 1) return unique;

    final healthy = <String>[];
    final cooled = <String>[];
    for (final url in unique) {
      if (isCooledDown(url, now: now)) {
        cooled.add(url);
      } else {
        healthy.add(url);
      }
    }
    return <String>[...healthy, ...cooled];
  }

  /// Chọn route kế tiếp chưa thử (ưu tiên route không bị cooldown).
  String? pickNextFallback(
    List<String> candidates, {
    required Set<String> triedUrls,
    DateTime? now,
  }) {
    final ordered = orderUrls(candidates, now: now);
    for (final url in ordered) {
      if (!triedUrls.contains(url)) return url;
    }
    return null;
  }

  void reset() => _hostCooldownUntil.clear();
}

