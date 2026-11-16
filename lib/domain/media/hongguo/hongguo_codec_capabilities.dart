import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Kết quả kiểm tra khả năng giải mã phần cứng của thiết bị.
class HongguoCodecSupport {
  final bool avcSupported;
  final bool hevcSupported;

  const HongguoCodecSupport({
    this.avcSupported = true,
    this.hevcSupported = true,
  });

  bool supportsCodec(String codec) {
    final lower = codec.toLowerCase();
    if (lower.contains('bytevc2') || lower.contains('bvc2') || lower.contains('vvc')) {
      return false;
    }
    if (lower.contains('hevc') ||
        lower.contains('bytevc1') ||
        lower.contains('h265') ||
        lower.contains('hev1') ||
        lower.contains('hvc1')) {
      return hevcSupported;
    }
    return avcSupported;
  }
}

/// Một phiên bản chất lượng/codec trong thang stream trả về từ API Hongguo.
class HongguoRendition {
  final String vid;
  final String definition;
  final String codec;
  final String mainUrl;
  final String backupUrl;
  final String spadeA;
  final String contentKeyHex;
  final int width;
  final int height;
  final int bitrate;
  final int fps;
  final int sizeBytes;
  final bool isDrmProtected;

  const HongguoRendition({
    required this.vid,
    required this.definition,
    required this.codec,
    required this.mainUrl,
    this.backupUrl = '',
    this.spadeA = '',
    this.contentKeyHex = '',
    this.width = 0,
    this.height = 0,
    this.bitrate = 0,
    this.fps = 0,
    this.sizeBytes = 0,
    this.isDrmProtected = false,
  });

  String get normalizedCodec {
    final c = codec.toLowerCase();
    if (c.contains('bytevc2') || c.contains('bvc2') || c.contains('vvc')) {
      return 'bytevc2';
    }
    if (c.contains('hevc') ||
        c.contains('bytevc1') ||
        c.contains('h265') ||
        c.contains('hev1') ||
        c.contains('hvc1')) {
      return 'bytevc1';
    }
    return 'h264';
  }

  bool get isBytevc1 => normalizedCodec == 'bytevc1';
  bool get isSupportedCodec => normalizedCodec != 'bytevc2';

  int get qualityTier {
    final lower = definition.toLowerCase();
    if (lower.contains('1080') || lower.contains('4k') || lower.contains('2160')) {
      return 1080;
    }
    if (lower.contains('720')) return 720;
    if (lower.contains('480') || lower.contains('540')) return 480;
    if (lower.contains('360')) return 360;

    final shortSide = (width > 0 && height > 0)
        ? (width < height ? width : height)
        : (width > height ? width : height);
    if (shortSide >= 900) return 1080;
    if (shortSide >= 640) return 720;
    if (shortSide >= 420) return 480;
    if (shortSide > 0) return 360;
    return 720;
  }

  String get qualityLabel => '${qualityTier}P';
  String get uniqueKey => '${normalizedCodec}_$qualityTier';

  List<String> get candidateUrls => <String>[
        if (mainUrl.isNotEmpty) mainUrl,
        if (backupUrl.isNotEmpty && backupUrl != mainUrl) backupUrl,
      ];
}

/// Bậc thang các luồng phát (tự động loại bỏ `bytevc2` không tương thích).
class HongguoStreamLadder {
  final List<HongguoRendition> renditions;
  final int durationMs;

  const HongguoStreamLadder({
    required this.renditions,
    this.durationMs = 0,
  });

  /// Danh sách mốc chất lượng duy nhất (tương thích) giảm dần (`['1080', '720', '480', '360']`).
  List<String> get availableQualityTiers {
    final tiers = renditions
        .where((r) => r.isSupportedCodec)
        .map((r) => r.qualityTier)
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a));
    return tiers.map((t) => t.toString()).toList(growable: false);
  }

  /// Chọn rendition tối ưu theo chất lượng ưu tiên, hỗ trợ decoder phần cứng & DecoderLessons.
  HongguoRendition? selectBest({
    String preferredQuality = '1080',
    HongguoCodecSupport? hardwareSupport,
    HongguoDecoderLessons? lessons,
    Set<String> excludedKeys = const <String>{},
  }) {
    final compatible = renditions
        .where((r) => r.isSupportedCodec && r.candidateUrls.isNotEmpty)
        .toList(growable: false);
    if (compatible.isEmpty) return null;

    final support = hardwareSupport ?? const HongguoCodecSupport();
    final targetTier = _parsePreferredTier(preferredQuality);

    final candidates = compatible.where((r) {
      if (excludedKeys.contains(r.uniqueKey)) return false;
      if (!support.supportsCodec(r.normalizedCodec)) return false;
      if (lessons != null && lessons.isBlocked(r.normalizedCodec, r.qualityTier)) {
        return false;
      }
      return true;
    }).toList();

    final pool = candidates.isNotEmpty
        ? candidates
        : compatible.where((r) => !excludedKeys.contains(r.uniqueKey)).toList();
    final activePool = pool.isNotEmpty ? pool : compatible;

    activePool.sort((a, b) {
      final sa = _scoreRendition(a, targetTier: targetTier, support: support);
      final sb = _scoreRendition(b, targetTier: targetTier, support: support);
      return sb.compareTo(sa);
    });
    return activePool.first;
  }

  /// Chọn rendition hạ cấp tự động khi gặp lỗi giải mã hoặc đứng hình (buffer stall).
  ///
  /// Ưu tiên giữ nguyên độ phân giải nhưng chuyển HEVC -> H.264 trước; nếu đang H.264
  /// hoặc không có H.264 cùng mức thì hạ xuống bậc chất lượng kế tiếp.
  HongguoRendition? selectDowngrade(
    HongguoRendition current, {
    HongguoCodecSupport? hardwareSupport,
    HongguoDecoderLessons? lessons,
    Set<String> excludedKeys = const <String>{},
  }) {
    final nextExcluded = <String>{...excludedKeys, current.uniqueKey};
    final support = hardwareSupport ?? const HongguoCodecSupport();

    final remaining = renditions
        .where(
          (r) =>
              r.isSupportedCodec &&
              r.candidateUrls.isNotEmpty &&
              !nextExcluded.contains(r.uniqueKey) &&
              !(lessons?.isBlocked(r.normalizedCodec, r.qualityTier) ?? false),
        )
        .toList();
    if (remaining.isEmpty) return null;

    // 1. Nếu bản hiện tại là HEVC, ưu tiên fallback sang H.264 ở cùng tier (hoặc thấp hơn).
    if (current.isBytevc1) {
      final h264SameOrLower = remaining
          .where((r) => !r.isBytevc1 && r.qualityTier <= current.qualityTier)
          .toList()
        ..sort((a, b) => b.qualityTier.compareTo(a.qualityTier));
      if (h264SameOrLower.isNotEmpty) return h264SameOrLower.first;
    }

    // 2. Hạ xuống bậc phân giải thấp hơn gần nhất.
    final lowerTier = remaining
        .where((r) => r.qualityTier < current.qualityTier)
        .toList()
      ..sort((a, b) {
        final tierCmp = b.qualityTier.compareTo(a.qualityTier);
        if (tierCmp != 0) return tierCmp;
        // Ưu tiên H.264 an toàn khi đang fallback.
        return a.isBytevc1 == b.isBytevc1 ? 0 : (a.isBytevc1 ? 1 : -1);
      });
    if (lowerTier.isNotEmpty) return lowerTier.first;

    // 3. Thử bất kỳ rendition nào còn khả dụng.
    return selectBest(
      preferredQuality: current.qualityTier.toString(),
      hardwareSupport: support,
      lessons: lessons,
      excludedKeys: nextExcluded,
    );
  }

  static int _parsePreferredTier(String preferredQuality) {
    final lower = preferredQuality.trim().toLowerCase();
    if (lower == 'auto') return 1080;
    if (lower == 'lowest') return 360;
    return int.tryParse(lower.replaceAll('p', '')) ?? 1080;
  }

  static int _scoreRendition(
    HongguoRendition r, {
    required int targetTier,
    required HongguoCodecSupport support,
  }) {
    var score = 0;
    final tier = r.qualityTier;
    if (tier == targetTier) {
      score += 10000;
    } else if (tier < targetTier) {
      // Mức thấp hơn gần targetTier nhất tốt hơn mức quá cao hoặc quá thấp.
      score += 5000 + tier;
    } else {
      // Lớn hơn targetTier -> ưu tiên sát targetTier nhất.
      score += 3000 - (tier - targetTier);
    }

    // Ở cùng độ phân giải, HEVC giúp tiết kiệm băng thông nếu phần cứng hỗ trợ tốt;
    // ngược lại H.264/AVC luôn an toàn nhất.
    if (r.isBytevc1 && support.hevcSupported) {
      score += 200;
    } else if (!r.isBytevc1) {
      score += 100;
    }

    // Video có âm thanh/kích thước hợp lệ & bitrate cao nhẹ được ưu tiên.
    score += (r.bitrate ~/ 10000).clamp(0, 99);
    return score;
  }
}

/// Ghi nhớ các cặp `(codec, tier)` từng gặp lỗi giải mã trên thiết bị hiện tại (TTL 7 ngày).
class HongguoDecoderLessons {
  static const String _prefKey = 'hongguo_decoder_lessons_v1';
  static const Duration lessonTtl = Duration(days: 7);

  final Map<String, int> _failuresEpochMs = <String, int>{};
  bool _loaded = false;

  int get count => _failuresEpochMs.length;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final cutoff = nowMs - lessonTtl.inMilliseconds;
        decoded.forEach((k, v) {
          final ms = (v as num?)?.toInt() ?? 0;
          if (ms > cutoff) {
            _failuresEpochMs[k.toString()] = ms;
          }
        });
      }
    } catch (_) {}
  }

  static String _lessonKey(String codec, int qualityTier) {
    final norm = codec.toLowerCase().contains('hevc') ||
            codec.toLowerCase().contains('bytevc1') ||
            codec.toLowerCase().contains('h265') ||
            codec.toLowerCase().contains('hev1') ||
            codec.toLowerCase().contains('hvc1')
        ? 'bytevc1'
        : 'h264';
    return '$norm:$qualityTier';
  }

  bool isBlocked(String codec, int qualityTier) {
    final key = _lessonKey(codec, qualityTier);
    final ts = _failuresEpochMs[key];
    if (ts == null) return false;
    final age = DateTime.now().millisecondsSinceEpoch - ts;
    if (age > lessonTtl.inMilliseconds) {
      _failuresEpochMs.remove(key);
      return false;
    }
    return true;
  }

  Future<void> learnFailure(String codec, int qualityTier) async {
    await load();
    final key = _lessonKey(codec, qualityTier);
    _failuresEpochMs[key] = DateTime.now().millisecondsSinceEpoch;
    await _persist();
  }

  Future<void> clearAll() async {
    _failuresEpochMs.clear();
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefKey);
    } catch (_) {}
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, jsonEncode(_failuresEpochMs));
    } catch (_) {}
  }
}

/// Kiểm tra năng lực codec phần cứng qua MethodChannel `com.capcut.capsub/media`
/// (`MediaCodecList` trên Android, `VideoToolbox` trên iOS) và kết hợp `DecoderLessons`.
class HongguoCodecCapabilities {
  HongguoCodecCapabilities._();
  static final HongguoCodecCapabilities instance = HongguoCodecCapabilities._();

  static const MethodChannel _channel = MethodChannel('com.capcut.capsub/media');

  final HongguoDecoderLessons lessons = HongguoDecoderLessons();
  HongguoCodecSupport? _cachedSupport;

  Future<HongguoCodecSupport> getHardwareSupport({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _cachedSupport != null) {
      return _cachedSupport!;
    }
    await lessons.load();
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'checkVideoDecoderSupport',
        const <String, dynamic>{
          'width': 1080,
          'height': 1920,
        },
      );
      if (res != null) {
        _cachedSupport = HongguoCodecSupport(
          avcSupported: (res['avc'] as bool?) ?? true,
          hevcSupported: (res['hevc'] as bool?) ?? true,
        );
        return _cachedSupport!;
      }
    } on MissingPluginException {
      // Môi trường unit test hoặc desktop: mặc định cho phép AVC/HEVC.
    } catch (e) {
      debugPrint('[HongguoCodecCapabilities] Probe failed: $e');
    }
    _cachedSupport = const HongguoCodecSupport();
    return _cachedSupport!;
  }

  Future<void> learnFailure(HongguoRendition rendition) async {
    await lessons.learnFailure(rendition.normalizedCodec, rendition.qualityTier);
  }

  @visibleForTesting
  void setSupportForTesting(HongguoCodecSupport? support) {
    _cachedSupport = support;
  }
}
