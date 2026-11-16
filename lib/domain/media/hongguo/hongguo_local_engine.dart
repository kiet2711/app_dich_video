import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../data/repository/settings_repository.dart';
import '../audio_extractor.dart';
import '../hongguo_cenc_decryptor.dart';
import '../video_cache_manager.dart';
import 'hongguo_codec_capabilities.dart';
import 'hongguo_device_service.dart';
import 'hongguo_playback_routes.dart';
import 'hongguo_remote_video.dart';
import 'hongguo_sixgod_signer.dart';
import 'hongguo_v5_signer.dart';

/// Thông tin nguồn phát video đã giải mã từ Hongguo Local Engine.
class HongguoVideoInfo {
  final String vid;
  final String realMainUrl;
  final String realBackupUrl;
  final String contentKeyHex;
  final String spadeA;
  final int durationMs;
  final String preferredQuality;
  final HongguoStreamLadder? ladder;
  final HongguoRendition? selectedRendition;
  final List<String> candidateUrls;

  bool get isDrmProtected => contentKeyHex.isNotEmpty;
  int get duration => durationMs > 0 ? durationMs ~/ 1000 : 0;
  String get quality => selectedRendition?.qualityLabel ?? 'HD';

  const HongguoVideoInfo({
    required this.vid,
    required this.realMainUrl,
    required this.realBackupUrl,
    required this.contentKeyHex,
    this.spadeA = '',
    this.durationMs = 0,
    this.preferredQuality = '1080',
    this.ladder,
    this.selectedRendition,
    List<String>? candidateUrls,
  }) : candidateUrls = candidateUrls ??
            const <String>[];

  /// Danh sách URL ứng viên đã sắp xếp theo tình trạng đường truyền (`HongguoPlaybackRoutes`).
  List<String> get orderedUrls {
    final base = candidateUrls.isNotEmpty
        ? candidateUrls
        : <String>[
            if (realMainUrl.isNotEmpty) realMainUrl,
            if (realBackupUrl.isNotEmpty && realBackupUrl != realMainUrl)
              realBackupUrl,
          ];
    return HongguoPlaybackRoutes.instance.orderUrls(base);
  }

  /// Chọn bản hạ cấp tiếp theo (HEVC -> H.264 hoặc 1080p -> 720p -> 480p).
  HongguoVideoInfo? downgradeWith(
    HongguoRendition nextRendition, {
    required String preferredQuality,
  }) {
    final ordered = HongguoPlaybackRoutes.instance.orderUrls(
      nextRendition.candidateUrls,
    );
    if (ordered.isEmpty) return null;
    return HongguoVideoInfo(
      vid: vid,
      realMainUrl: ordered.first,
      realBackupUrl: ordered.length > 1 ? ordered[1] : ordered.first,
      contentKeyHex: nextRendition.contentKeyHex,
      spadeA: nextRendition.spadeA,
      durationMs: durationMs,
      preferredQuality: preferredQuality,
      ladder: ladder,
      selectedRendition: nextRendition,
      candidateUrls: ordered,
    );
  }
}

/// Engine phân giải và giải mã video Hongguo thuần Dart (Mobile v5 + fallback v3 + StreamLadder + CENC Streaming).
class HongguoLocalEngine {
  HongguoLocalEngine._();

  static final Dio _defaultDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 15),
      validateStatus: (status) => status != null && status < 500,
    ),
  );

  static Dio? _overrideDio;

  @visibleForTesting
  static void setDioForTesting(Dio? dio) {
    _overrideDio = dio;
  }

  static Dio get _dio => _overrideDio ?? _defaultDio;

  static const String v5PlayerPath = '/novel/player/multi_video_model/player/v1';
  static const String v3PlayerPath = '/novel/player/multi_video_model/v1/';
  static const String videoModelUrlTemplate =
      'https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/'
      '?iid=3076883975280827&device_id=3076883975276731&ac=wifi&channel=update_64&aid=8662'
      '&app_name=novelread&version_code=71332&version_name=7.1.3.32'
      '&player_so_load=1&is_android_pad_screen=0';

  static const List<String> _apiHosts = <String>[
    'api5-normal-sinfonlinea.fqnovel.com',
    'api5-normal-sinfonlineb.fqnovel.com',
    'api5-normal-sinfonlinec.fqnovel.com',
    'api5-normal-lf.fqnovel.com',
    'api5-normal-lq.fqnovel.com',
    'api3-normal-lf.fqnovel.com',
  ];

  // Bộ nhớ tạm thời lượng thực tế (ms) theo `vid` (tối đa 128 mục gần nhất).
  static final Map<String, int> _durationCacheMs = <String, int>{};

  static void rememberDurationMs(String vid, int durationMs) {
    if (vid.isEmpty || durationMs <= 0) return;
    _durationCacheMs.remove(vid);
    _durationCacheMs[vid] = durationMs;
    while (_durationCacheMs.length > 128) {
      _durationCacheMs.remove(_durationCacheMs.keys.first);
    }
  }

  static int getCachedDurationMs(String vid) => _durationCacheMs[vid] ?? 0;

  /// Chuẩn hoá giá trị thời lượng từ API ByteDance sang milliseconds.
  ///
  /// API thường trả về đơn vị giây (`60` - `600`) hoặc đôi khi là milliseconds (`>= 10000`).
  static int normalizeDurationMs(dynamic rawDuration) {
    if (rawDuration == null) return 0;
    double? numVal;
    if (rawDuration is num) {
      numVal = rawDuration.toDouble();
    } else {
      numVal = double.tryParse(rawDuration.toString().trim());
    }
    if (numVal == null || numVal <= 0 || numVal.isNaN || numVal.isInfinite) {
      return 0;
    }
    if (numVal < 10000) {
      return (numVal * 1000).round();
    }
    return numVal.round();
  }

  /// Xác định thời lượng thực tế tốt nhất (ms) theo thứ tự độ tin cậy:
  /// 1. Native `AudioExtractor.probeDuration` (trên file cục bộ)
  /// 2. `HongguoCencDecryptor.probeMp4FileMetadata` (đọc hộp `moov`/`mdhd`/`stts`)
  /// 3. `HongguoStreamProxyServer.instance.getSessionDurationMs(vid)` (qua Stream Proxy)
  /// 4. `videoInfo.durationMs` / cache `getCachedDurationMs(vid)` / `apiDurationRaw`
  /// 5. `playerDurationMs` -> Fallback `120000` nếu mọi probe đều trả 0.
  static Future<int> resolveEffectiveDurationMs({
    String? localFilePath,
    String? vid,
    HongguoVideoInfo? videoInfo,
    dynamic apiDurationRaw,
    int? playerDurationMs,
    int proxySessionDurationMs = 0,
    Future<int> Function(String path)? probeAudioFn,
  }) async {
    if (localFilePath != null &&
        localFilePath.isNotEmpty &&
        !localFilePath.startsWith('http://') &&
        !localFilePath.startsWith('https://')) {
      final f = File(localFilePath);
      if (await f.exists()) {
        try {
          final probed = probeAudioFn != null
              ? await probeAudioFn(localFilePath)
              : await AudioExtractor.probeDuration(localFilePath);
          if (probed > 0) {
            if (vid != null && vid.isNotEmpty) rememberDurationMs(vid, probed);
            return probed;
          }
        } catch (_) {}
        final meta = await HongguoCencDecryptor.probeMp4FileMetadata(f);
        if (meta != null && meta.durationMs > 0) {
          if (vid != null && vid.isNotEmpty) {
            rememberDurationMs(vid, meta.durationMs);
          }
          return meta.durationMs;
        }
      }
    }

    if (proxySessionDurationMs > 0) {
      if (vid != null && vid.isNotEmpty) {
        rememberDurationMs(vid, proxySessionDurationMs);
      }
      return proxySessionDurationMs;
    }
    if (videoInfo != null && videoInfo.durationMs > 0) {
      return videoInfo.durationMs;
    }
    if (vid != null && vid.isNotEmpty) {
      final cached = getCachedDurationMs(vid);
      if (cached > 0) return cached;
    }
    final normalizedApi = normalizeDurationMs(apiDurationRaw);
    if (normalizedApi > 0) {
      if (vid != null && vid.isNotEmpty) {
        rememberDurationMs(vid, normalizedApi);
      }
      return normalizedApi;
    }
    if (playerDurationMs != null && playerDurationMs > 0) {
      return playerDurationMs;
    }
    return 120000;
  }

  /// Phân giải `videoId` sang đầy đủ `HongguoStreamLadder` + lựa chọn tối ưu theo thiết bị & chất lượng.
  static Future<HongguoVideoInfo> resolveVideoInfo(
    String videoId, {
    bool preferLowest = false,
    String? preferredQuality,
    bool forceH264 = false,
    Set<String> excludedRenditionKeys = const <String>{},
  }) async {
    final cleanVideoId = videoId.trim();
    if (cleanVideoId.isEmpty) {
      throw ArgumentError('video_id không được rỗng');
    }

    final quality = preferLowest
        ? '360'
        : (preferredQuality ?? await _readPreferredQuality());
    final hardwareSupport = await HongguoCodecCapabilities.instance
        .getHardwareSupport();
    final effectiveSupport = forceH264
        ? HongguoCodecSupport(
            avcSupported: hardwareSupport.avcSupported,
            hevcSupported: false,
          )
        : hardwareSupport;

    final videoModel = await _fetchVideoModelWithFallbacks(cleanVideoId);
    final durationMs = normalizeDurationMs(
      videoModel['video_duration'] ?? videoModel['duration'],
    );
    if (durationMs > 0) {
      rememberDurationMs(cleanVideoId, durationMs);
    }

    // 1. Parse video_list từ videoModel trước (hành vi ưu tiên của hongguoTV).
    final fallbackInfo = _extractFallbackApiInfo(videoModel);
    final renditions = <HongguoRendition>[
      ..._parseVideoListRenditions(
        cleanVideoId,
        videoModel['video_list'],
        keySeedB64: fallbackInfo.keySeedB64,
      ),
    ];

    // 2. Nếu chưa có luồng hợp lệ hoặc đang ép H.264 mà ladder chưa có H.264 -> gọi fallback_api.
    final hasH264 = renditions.any((r) => !r.isBytevc1);
    if ((renditions.isEmpty || (forceH264 && !hasH264)) &&
        fallbackInfo.url.isNotEmpty) {
      final extra = await _fetchFallbackApiRenditions(
        cleanVideoId,
        fallbackInfo.url,
        fallbackKeySeedB64: fallbackInfo.keySeedB64,
        forceH264: forceH264,
      );
      renditions.addAll(extra);
    }

    if (renditions.isEmpty) {
      throw StateError('Không tìm thấy luồng video khả dụng cho $cleanVideoId');
    }

    final ladder = HongguoStreamLadder(
      renditions: renditions,
      durationMs: durationMs,
    );
    final selected = ladder.selectBest(
      preferredQuality: quality,
      hardwareSupport: effectiveSupport,
      lessons: HongguoCodecCapabilities.instance.lessons,
      excludedKeys: excludedRenditionKeys,
    );
    if (selected == null || selected.candidateUrls.isEmpty) {
      throw StateError('Không chọn được rendition phù hợp cho $cleanVideoId');
    }

    final orderedUrls = HongguoPlaybackRoutes.instance.orderUrls(
      selected.candidateUrls,
    );
    return HongguoVideoInfo(
      vid: cleanVideoId,
      realMainUrl: orderedUrls.first,
      realBackupUrl: orderedUrls.length > 1 ? orderedUrls[1] : orderedUrls.first,
      contentKeyHex: selected.contentKeyHex,
      spadeA: selected.spadeA,
      durationMs: durationMs,
      preferredQuality: quality,
      ladder: ladder,
      selectedRendition: selected,
      candidateUrls: orderedUrls,
    );
  }

  /// Tải/giải mã stream hoặc trả về URL phát trực tiếp cho `vid`.
  static Future<String> resolveAndGetPlayableUrl(
    String seriesId,
    String vid, {
    int episodeIndex = 1,
    Function(double)? onProgress,
    String? preferredQuality,
    bool forceH264 = false,
    bool forceRedownload = false,
  }) async {
    if (!forceRedownload) {
      final cached = await VideoCacheManager.findCachedFile(
        url: 'hongguo://$vid',
        seriesId: seriesId,
        episodeIndex: episodeIndex,
      );
      if (cached != null) {
        return cached.path;
      }
    }

    var info = await resolveVideoInfo(
      vid,
      preferredQuality: preferredQuality,
      forceH264: forceH264,
    );

    if (!info.isDrmProtected && onProgress == null && !forceRedownload) {
      return info.realMainUrl;
    }

    final targetFile = await VideoCacheManager.getCachedVideoFile(
      url: info.realMainUrl,
      seriesId: seriesId,
      episodeIndex: episodeIndex,
    );

    final excludedKeys = <String>{};
    Object? lastError;

    for (var downgradeAttempt = 0; downgradeAttempt < 3; downgradeAttempt++) {
      final contentKey = info.isDrmProtected
          ? Uint8List.fromList(hex.decode(info.contentKeyHex))
          : null;

      for (final candidateUrl in info.orderedUrls) {
        final remote = HongguoRemoteVideo(
          url: candidateUrl,
          contentKey: contentKey,
        );
        try {
          final saved = await remote.streamDecryptedToFile(
            targetFile,
            onProgress: onProgress,
          );
          if (remote.durationMs > 0) {
            rememberDurationMs(vid, remote.durationMs);
          }
          if (await HongguoCencDecryptor.isCorruptedMp4File(saved)) {
            try {
              await saved.delete();
            } catch (_) {}
            throw const FormatException('MP4 sau giải mã không hợp lệ');
          }
          HongguoPlaybackRoutes.instance.markHealthy(candidateUrl);
          await VideoCacheManager.pruneCacheIfNeeded();
          return saved.path;
        } catch (e) {
          lastError = e;
          HongguoPlaybackRoutes.instance.markFailed(candidateUrl);
          debugPrint(
            '[HongguoLocalEngine] Route lỗi ($candidateUrl): $e',
          );
        } finally {
          remote.close();
        }
      }

      final curRendition = info.selectedRendition;
      if (curRendition == null || info.ladder == null) break;
      excludedKeys.add(curRendition.uniqueKey);
      final support = await HongguoCodecCapabilities.instance
          .getHardwareSupport();
      final next = info.ladder!.selectDowngrade(
        curRendition,
        hardwareSupport: support,
        lessons: HongguoCodecCapabilities.instance.lessons,
        excludedKeys: excludedKeys,
      );
      if (next == null) break;
      info = info.downgradeWith(next, preferredQuality: info.preferredQuality) ??
          info;
    }

    throw lastError ??
        StateError('Không thể tải/giải mã video Hongguo cho $vid');
  }

  static Future<String> _readPreferredQuality() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final q = prefs.getString('hongguo_preferred_quality') ?? '1080';
      return SettingsRepository.validHongguoQualities.contains(q) ? q : '1080';
    } catch (_) {
      return '1080';
    }
  }

  static Future<Map<String, dynamic>> _fetchVideoModelWithFallbacks(
    String videoId,
  ) async {
    var device = await HongguoDeviceService.instance.getOrRegisterDevice();

    // 1. Mobile v5 playback (`/novel/player/multi_video_model/player/v1` với `device_level: 1`).
    final v5Model = await _tryV5Hosts(videoId, device);
    if (v5Model != null) return v5Model;

    // 2. Fallback sang v3 (`/novel/player/multi_video_model/v1/`).
    var v3Model = await _tryV3Hosts(videoId, device);
    if (v3Model != null) return v3Model;

    // 3. Nếu thiết bị ẩn danh bị từ chối/chưa đăng ký, thử xoay danh tính 1 lần (có cooldown 5 phút).
    final rotated = await HongguoDeviceService.instance.rotateDevice(
      expected: device,
    );
    if (rotated) {
      device = await HongguoDeviceService.instance.getOrRegisterDevice();
      final retryV5 = await _tryV5Hosts(videoId, device);
      if (retryV5 != null) return retryV5;
      final retryV3 = await _tryV3Hosts(videoId, device);
      if (retryV3 != null) return retryV3;
    }

    throw StateError('Không lấy được video_model cho videoId=$videoId');
  }

  static Future<Map<String, dynamic>?> _tryV5Hosts(
    String videoId,
    HongguoDeviceInfo device,
  ) async {
    final payload = <String, dynamic>{
      'biz_param': const <String, dynamic>{
        'detail_page_version': 0,
        'device_level': 1,
        'disable_digg_stat': false,
        'disable_video_relate_book': false,
        'need_all_video_definition': true,
        'need_mp4_align': false,
        'use_os_player': false,
        'use_server_dns': false,
        'video_platform': 1024,
      },
      'mixed_video_id_map': <String, List<String>>{
        '1004': <String>[videoId],
      },
      'dr_scene': 'player',
    };
    final gzBytes = Uint8List.fromList(
      gzip.encode(utf8.encode(jsonEncode(payload))),
    );

    final orderedHosts = HongguoPlaybackRoutes.instance.orderUrls(
      _apiHosts.map((h) => 'https://$h$v5PlayerPath').toList(growable: false),
    );

    for (final endpoint in orderedHosts) {
      try {
        final signed = HongguoV5Signer.signPlaybackV5(
          baseUrl: endpoint,
          device: device,
          bodyBytes: gzBytes,
        );
        final res = await _dio.post<dynamic>(
          signed.url,
          data: Stream<List<int>>.fromIterable(<List<int>>[gzBytes]),
          options: Options(
            headers: <String, dynamic>{
              ...signed.headers,
              Headers.contentLengthHeader: gzBytes.length,
            },
            responseType: ResponseType.json,
          ),
        );
        final extracted = _extractVideoModelFromResponse(res.data, videoId);
        if (extracted != null) {
          HongguoPlaybackRoutes.instance.markHealthy(endpoint);
          return extracted;
        }
        HongguoPlaybackRoutes.instance.markFailed(
          endpoint,
          cooldown: const Duration(minutes: 2),
        );
      } catch (e) {
        HongguoPlaybackRoutes.instance.markFailed(endpoint);
        debugPrint('[HongguoLocalEngine] v5 host ($endpoint) lỗi: $e');
      }
    }
    return null;
  }

  static Future<Map<String, dynamic>?> _tryV3Hosts(
    String videoId,
    HongguoDeviceInfo device,
  ) async {
    final payload = <String, dynamic>{
      'biz_param': const <String, dynamic>{
        'detail_page_version': 0,
        'device_level': 1,
        'disable_digg_stat': false,
        'disable_video_relate_book': false,
        'need_all_video_definition': true,
        'need_mp4_align': false,
        'use_os_player': false,
        'use_server_dns': false,
        'video_platform': 1024,
      },
      'mixed_video_id_map': <String, List<String>>{
        '1004': <String>[videoId],
      },
    };

    final orderedHosts = HongguoPlaybackRoutes.instance.orderUrls(
      _apiHosts.map((h) => 'https://$h$v3PlayerPath').toList(growable: false),
    );

    for (final endpoint in orderedHosts) {
      try {
        final signed = HongguoSixgodSigner.signRequest(
          url: endpoint,
          body: payload,
          deviceId: device.deviceId,
          installId: device.installId,
          includeHelios: true,
        );
        final res = await _dio.post<dynamic>(
          signed.signedUrl,
          data: signed.bodyBytes,
          options: Options(
            headers: <String, dynamic>{
              ...signed.headers,
              if (device.cookieHeader.isNotEmpty) 'cookie': device.cookieHeader,
            },
            responseType: ResponseType.json,
          ),
        );
        final extracted = _extractVideoModelFromResponse(res.data, videoId);
        if (extracted != null) {
          HongguoPlaybackRoutes.instance.markHealthy(endpoint);
          return extracted;
        }
      } catch (e) {
        HongguoPlaybackRoutes.instance.markFailed(endpoint);
        debugPrint('[HongguoLocalEngine] v3 host ($endpoint) lỗi: $e');
      }
    }
    return null;
  }

  static Map<String, dynamic>? _extractVideoModelFromResponse(
    dynamic raw,
    String videoId,
  ) {
    dynamic root = raw;
    if (root is String && root.trim().isNotEmpty) {
      try {
        root = jsonDecode(root);
      } catch (_) {
        return null;
      }
    }
    if (root is! Map) return null;
    final data = root['data'];
    if (data is! Map) return null;

    final entries = data['1004'] is Map ? data['1004'] as Map : data;
    final entry = entries[videoId];
    if (entry is! Map) return null;

    var vm = entry['video_model'];
    if (vm is String && vm.trim().isNotEmpty) {
      try {
        vm = jsonDecode(vm);
      } catch (_) {
        return null;
      }
    }
    if (vm is Map) {
      return Map<String, dynamic>.from(vm);
    }
    return null;
  }

  static ({String url, String keySeedB64}) _extractFallbackApiInfo(
    Map<String, dynamic> videoModel,
  ) {
    dynamic raw = videoModel['fallback_api'];
    if (raw is String && raw.trim().startsWith('{')) {
      try {
        raw = jsonDecode(raw);
      } catch (_) {}
    }
    if (raw is Map) {
      return (
        url: raw['fallback_api']?.toString() ?? '',
        keySeedB64: raw['key_seed']?.toString() ?? '',
      );
    }
    if (raw is String && raw.startsWith('http')) {
      return (url: raw, keySeedB64: '');
    }
    return (url: '', keySeedB64: '');
  }

  static List<HongguoRendition> _parseVideoListRenditions(
    String vid,
    dynamic rawVideoList, {
    String keySeedB64 = '',
  }) {
    final keySeed = keySeedB64.isNotEmpty
        ? HongguoCencDecryptor.b64DecodePadded(keySeedB64)
        : null;
    final entries = <Map<String, dynamic>>[];
    if (rawVideoList is Map) {
      for (final val in rawVideoList.values) {
        if (val is Map) entries.add(Map<String, dynamic>.from(val));
      }
    } else if (rawVideoList is List) {
      for (final val in rawVideoList) {
        if (val is Map) entries.add(Map<String, dynamic>.from(val));
      }
    }

    final renditions = <HongguoRendition>[];
    for (final item in entries) {
      final codecRaw = (item['codec_type'] ??
              item['vtype'] ??
              item['codec'] ??
              item['video_codec'] ??
              'h264')
          .toString()
          .toLowerCase();
      if (codecRaw.contains('bytevc2') ||
          codecRaw.contains('bvc2') ||
          codecRaw.contains('vvc')) {
        continue;
      }

      final encryptInfo = item['encrypt_info'];
      final spadeA = (item['spade_a'] ??
              (encryptInfo is Map ? encryptInfo['spade_a'] : null) ??
              item['play_auth_token'] ??
              '')
          .toString()
          .trim();
      final mainUrl = _decodeStreamUrl(
        item['main_url']?.toString() ?? '',
        spadeA: spadeA,
        keySeed: keySeed,
      );
      if (mainUrl.isEmpty) continue;

      final backupUrl = _decodeStreamUrl(
        item['backup_url_1']?.toString() ??
            item['backup_url']?.toString() ??
            '',
        spadeA: spadeA,
        keySeed: keySeed,
      );

      final contentKeyHex = spadeA.isNotEmpty
          ? HongguoCencDecryptor.deriveContentKeyHex(spadeA)
          : '';

      renditions.add(
        HongguoRendition(
          vid: vid,
          definition: item['definition']?.toString() ?? '720p',
          codec: codecRaw,
          mainUrl: mainUrl,
          backupUrl: backupUrl,
          spadeA: spadeA,
          contentKeyHex: contentKeyHex,
          width: (item['vwidth'] as num?)?.toInt() ??
              (item['width'] as num?)?.toInt() ??
              0,
          height: (item['vheight'] as num?)?.toInt() ??
              (item['height'] as num?)?.toInt() ??
              0,
          bitrate: (item['bitrate'] as num?)?.toInt() ?? 0,
          fps: (item['fps'] as num?)?.toInt() ?? 0,
          sizeBytes: (item['size'] as num?)?.toInt() ?? 0,
          isDrmProtected: contentKeyHex.isNotEmpty,
        ),
      );
    }
    return renditions;
  }

  static Future<List<HongguoRendition>> _fetchFallbackApiRenditions(
    String vid,
    String fallbackUrl, {
    String fallbackKeySeedB64 = '',
    bool forceH264 = false,
  }) async {
    try {
      var target = fallbackUrl.trim();
      if (target.startsWith('/')) {
        target = 'https://is.snssdk.com$target';
      }
      if (forceH264) {
        final uri = Uri.parse(target);
        target = uri
            .replace(
              queryParameters: <String, String>{
                ...uri.queryParameters,
                'codec_type': '0',
                'force_codec': 'h264',
              },
            )
            .toString();
      }

      final res = await _dio.get<dynamic>(
        target,
        options: Options(
          headers: <String, dynamic>{
            'User-Agent': HongguoSixgodSigner.userAgent,
            'Accept-Encoding': 'gzip',
          },
          responseType: ResponseType.json,
        ),
      );
      dynamic body = res.data;
      if (body is String && body.trim().isNotEmpty) {
        body = jsonDecode(body);
      }
      if (body is! Map) return const <HongguoRendition>[];
      final data = body['data'] is Map ? body['data'] as Map : body;
      final effectiveSeed =
          data['key_seed']?.toString() ?? fallbackKeySeedB64;
      final videoList = data['video_list'];
      if (videoList != null) {
        return _parseVideoListRenditions(
          vid,
          videoList,
          keySeedB64: effectiveSeed,
        );
      }
    } catch (e) {
      debugPrint('[HongguoLocalEngine] fallback_api ($vid) lỗi: $e');
    }
    return const <HongguoRendition>[];
  }

  static String _decodeStreamUrl(
    String raw, {
    String spadeA = '',
    Uint8List? keySeed,
  }) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }

    // Thử giải mã plaintext base64 trước (multi_video_model hay trả URL base64 thuần).
    try {
      final b64Decoded = utf8.decode(
        HongguoCencDecryptor.b64DecodePadded(trimmed),
        allowMalformed: false,
      );
      if (b64Decoded.startsWith('http://') || b64Decoded.startsWith('https://')) {
        return b64Decoded;
      }
    } catch (_) {}

    // Giải mã URL mã hoá bởi key_seed / spade_a.
    if (keySeed != null && keySeed.isNotEmpty) {
      try {
        final dec = HongguoCencDecryptor.decryptSpadeUrl(trimmed, keySeed);
        if (dec.startsWith('http://') || dec.startsWith('https://')) {
          return dec;
        }
      } catch (_) {}
    }

    if (spadeA.isNotEmpty) {
      try {
        final spadeSeed = HongguoCencDecryptor.b64DecodePadded(spadeA);
        final dec = HongguoCencDecryptor.decryptSpadeUrl(trimmed, spadeSeed);
        if (dec.startsWith('http://') || dec.startsWith('https://')) {
          return dec;
        }
      } catch (_) {}
    }

    return '';
  }

  /// Tạo một rendition tương ứng bản dự phòng nếu player báo lỗi với stream hiện tại.
  static HongguoRendition? pickFallbackRendition(
    HongguoVideoInfo info, {
    required HongguoRendition current,
    required HongguoCodecSupport support,
    Set<String> excludedKeys = const <String>{},
  }) {
    return info.ladder?.selectDowngrade(
      current,
      hardwareSupport: support,
      lessons: HongguoCodecCapabilities.instance.lessons,
      excludedKeys: excludedKeys,
    );
  }
}
