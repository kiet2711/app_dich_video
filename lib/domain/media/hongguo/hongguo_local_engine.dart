import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../hongguo_cenc_decryptor.dart';
import '../video_cache_manager.dart';
import 'hongguo_sixgod_signer.dart';

Future<void> _decryptDownloadedHongguoVideo(Map<String, String> args) async {
  final encryptedFile = File(args['inputPath']!);
  final outputFile = File(args['outputPath']!);
  final encryptedBytes = await encryptedFile.readAsBytes();
  final keyBytes = Uint8List.fromList(hex.decode(args['contentKeyHex']!));
  final decryptedBytes = HongguoCencDecryptor.decryptMp4Cenc(
    encryptedBytes,
    keyBytes,
  );
  await outputFile.writeAsBytes(decryptedBytes, flush: true);
}

/// Kết quả trích xuất thông tin video từ ByteDance
class HongguoVideoInfo {
  final String videoId;
  final String title;
  final int duration;
  final String realMainUrl;
  final String contentKeyHex;
  final String quality;

  const HongguoVideoInfo({
    required this.videoId,
    required this.title,
    required this.duration,
    required this.realMainUrl,
    required this.contentKeyHex,
    required this.quality,
  });

  bool get isDrmProtected => contentKeyHex.isNotEmpty;
}

/// Trình xử lý giải mã video Hồng Quả On-Device thuần Dart
class HongguoLocalEngine {
  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );

  static const String videoModelUrlTemplate =
      'https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/'
      '?iid=3076883975280827&device_id=3076883975276731&ac=wifi&channel=update_64&aid=8662'
      '&app_name=novelread&version_code=71332&version_name=7.1.3.32'
      '&device_platform=android&os=android&ssmix=a&device_type=25053RT47C'
      '&device_brand=Redmi&language=zh&os_api=36&os_version=16'
      '&manifest_version_code=71332&resolution=1280*2772&dpi=520'
      '&update_version_code=71332&host_abi=arm64-v8a&dragon_device_type=phone'
      '&pv_player=71332&compliance_status=0&need_personal_recommend=1'
      '&player_so_load=1&is_android_pad_screen=0';

  /// Lấy trực tiếp thông tin URL stream và Content Key từ API gốc của ByteDance
  static Future<HongguoVideoInfo> resolveVideoInfo(String videoId) async {
    final cleanVideoId = videoId.trim();
    if (!RegExp(r'^\d+$').hasMatch(cleanVideoId)) {
      throw ArgumentError.value(videoId, 'videoId', 'Video ID phải là dãy số');
    }
    final payload = {
      'biz_param': {
        'detail_page_version': 0,
        'device_level': 3,
        'disable_digg_stat': false,
        'need_all_video_definition': true,
        'need_mp4_align': false,
        'use_os_player': false,
        'use_server_dns': false,
        'video_platform': 1024,
      },
      'mixed_video_id_map': {
        '1004': [cleanVideoId],
      },
    };

    final signed = HongguoSixgodSigner.signRequest(
      url: videoModelUrlTemplate,
      body: payload,
    );

    final res = await _dio.post(
      signed.signedUrl,
      data: signed.bodyBytes,
      options: Options(
        headers: signed.headers,
        responseType: ResponseType.json,
      ),
    );
    debugPrint('[HongguoLocalEngine] API status: ${res.statusCode}');

    final data = res.data is Map ? res.data as Map : <String, dynamic>{};
    final apiCode = int.tryParse(data['code']?.toString() ?? '0') ?? 0;
    if (apiCode != 0) {
      throw StateError(
        'ByteDance từ chối request (code $apiCode): '
        '${data['message'] ?? data['Message'] ?? 'không rõ lỗi'}',
      );
    }
    final dataMap = data['data'] is Map
        ? data['data'] as Map
        : <String, dynamic>{};
    var videoEntry = dataMap[cleanVideoId];
    if (videoEntry == null && dataMap.isNotEmpty) {
      videoEntry = dataMap.values.first;
    }

    if (videoEntry == null) {
      throw StateError(
        'Không tìm thấy thông tin video ID: $cleanVideoId từ ByteDance',
      );
    }

    dynamic vm = videoEntry['video_model'];
    Map videoModel = {};
    if (vm is String && vm.isNotEmpty) {
      try {
        videoModel = jsonDecode(vm) as Map;
      } catch (_) {}
    } else if (vm is Map) {
      videoModel = vm;
    }

    var fallbackRaw = videoModel['fallback_api'] ?? '';
    var fallbackApi = '';
    if (fallbackRaw is String) {
      if (fallbackRaw.startsWith('{')) {
        try {
          final dec = jsonDecode(fallbackRaw) as Map;
          fallbackApi = dec['fallback_api']?.toString() ?? '';
        } catch (_) {}
      }
      if (fallbackApi.isEmpty) fallbackApi = fallbackRaw;
    } else if (fallbackRaw is Map) {
      fallbackApi = fallbackRaw['fallback_api']?.toString() ?? '';
    }

    if (fallbackApi.isEmpty) {
      throw StateError('Không tìm thấy fallback_api cho video $cleanVideoId');
    }

    final fbRes = await _dio.get(
      fallbackApi,
      options: Options(
        headers: {'user-agent': HongguoSixgodSigner.userAgent},
        responseType: ResponseType.json,
      ),
    );

    final fbData = fbRes.data is Map ? fbRes.data as Map : <String, dynamic>{};
    final videoInfo = fbData['video_info'] is Map
        ? fbData['video_info'] as Map
        : <String, dynamic>{};
    final videoData = videoInfo['data'] is Map
        ? videoInfo['data'] as Map
        : <String, dynamic>{};

    final keySeedB64 = videoData['key_seed']?.toString() ?? '';
    final keySeedRaw = keySeedB64.isNotEmpty
        ? HongguoCencDecryptor.b64DecodePadded(keySeedB64)
        : Uint8List(0);

    final videoList = videoData['video_list'] is Map
        ? videoData['video_list'] as Map
        : <String, dynamic>{};
    Map bestItem = {};
    var bestHeight = 0;

    for (final item in videoList.values) {
      if (item is Map) {
        final h = int.tryParse(item['vheight']?.toString() ?? '0') ?? 0;
        if (h > bestHeight) {
          bestHeight = h;
          bestItem = item;
        }
      }
    }

    if (bestItem.isEmpty && videoList.isNotEmpty) {
      bestItem = videoList.values.first as Map;
    }

    final spadeA = bestItem['spade_a']?.toString() ?? '';
    var contentKeyHex = '';
    if (spadeA.isNotEmpty) {
      try {
        final keyBytes = HongguoCencDecryptor.deriveContentKey(spadeA);
        contentKeyHex = hex.encode(keyBytes);
      } catch (e) {
        debugPrint('[HongguoLocalEngine] Không thể derive key từ spade_a: $e');
      }
    }

    final rawMainUrl =
        bestItem['main_url']?.toString() ??
        bestItem['play_addr']?.toString() ??
        '';
    var realMainUrl = rawMainUrl;
    if (keySeedRaw.isNotEmpty && rawMainUrl.length > 10) {
      try {
        final dec = HongguoCencDecryptor.decryptSpadeUrl(
          rawMainUrl,
          keySeedRaw,
        );
        if (dec.isNotEmpty && dec.startsWith('http')) {
          realMainUrl = dec;
        }
      } catch (e) {
        debugPrint('[HongguoLocalEngine] Không thể decrypt spade url: $e');
      }
    }
    if (!realMainUrl.startsWith('http://') &&
        !realMainUrl.startsWith('https://')) {
      throw StateError(
        'ByteDance không trả về URL phát hợp lệ cho video $cleanVideoId',
      );
    }

    final duration =
        int.tryParse(
          videoModel['duration']?.toString() ??
              videoData['duration']?.toString() ??
              '0',
        ) ??
        0;
    final title =
        videoModel['title']?.toString() ??
        videoData['title']?.toString() ??
        videoId;

    return HongguoVideoInfo(
      videoId: cleanVideoId,
      title: title,
      duration: duration,
      realMainUrl: realMainUrl,
      contentKeyHex: contentKeyHex,
      quality: bestHeight > 0 ? '${bestHeight}p' : 'HD',
    );
  }

  /// Tải về và tự động giải mã DRM CENC trực tiếp trên điện thoại
  /// Trả về đường dẫn file mp4 cục bộ đã sẵn sàng phát
  static Future<String> resolveAndGetPlayableUrl(
    String seriesId,
    String vid, {
    int episodeIndex = 1,
    Function(double)? onProgress,
  }) async {
    // 1. Kiểm tra cache trong máy trước
    final cached = await VideoCacheManager.findCachedFile(
      url: '',
      seriesId: seriesId,
      episodeIndex: episodeIndex,
    );
    if (cached != null &&
        await cached.exists() &&
        await cached.length() > 1024 * 50) {
      debugPrint(
        '[HongguoLocalEngine] ✅ Tìm thấy video trong cache máy: ${cached.path}',
      );
      return cached.path;
    }

    // 2. Tự sinh chữ ký & lấy thông tin từ ByteDance API
    debugPrint(
      '[HongguoLocalEngine] ⚡ Đang gọi API ByteDance trực tiếp trên máy...',
    );
    final info = await resolveVideoInfo(vid);
    final urlPreview = info.realMainUrl.length > 50
        ? '${info.realMainUrl.substring(0, 50)}...'
        : info.realMainUrl;
    debugPrint(
      '[HongguoLocalEngine] 🎯 Lấy stream URL thành công: '
      '$urlPreview (DRM: ${info.isDrmProtected})',
    );

    // Nếu video KHÔNG bị mã hóa DRM (ví dụ web mở hoặc public stream), trả link CDN trực tiếp luôn
    if (!info.isDrmProtected) {
      return info.realMainUrl;
    }

    // 3. Nếu video CÓ mã hóa DRM CENC: Tải về và giải mã tại chỗ trên điện thoại
    final cacheDir = await VideoCacheManager.getCacheDirectory();
    final cleanSid = seriesId.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '');
    final targetFile = File(
      '${cacheDir.path}${Platform.pathSeparator}hg_${cleanSid}_ep$episodeIndex.mp4',
    );
    final encryptedFile = File('${targetFile.path}.encrypted.part');
    final decryptedPartFile = File('${targetFile.path}.part');

    for (final staleFile in [encryptedFile, decryptedPartFile]) {
      if (await staleFile.exists()) {
        await staleFile.delete();
      }
    }

    debugPrint(
      '[HongguoLocalEngine] 📥 Đang tải chunk MP4 mã hóa từ CDN ByteDance...',
    );
    await _dio.download(
      info.realMainUrl,
      encryptedFile.path,
      deleteOnError: true,
      options: Options(
        headers: {
          'user-agent': HongguoSixgodSigner.userAgent,
          'referer': 'https://novel.snssdk.com/',
        },
      ),
      onReceiveProgress: (received, total) {
        if (total > 0 && onProgress != null) {
          onProgress(received / total);
        }
      },
    );

    final encryptedSize = await encryptedFile.length();
    if (encryptedSize < 1024) {
      await encryptedFile.delete();
      throw StateError('File video tải về không hợp lệ ($encryptedSize bytes)');
    }
    debugPrint(
      '[HongguoLocalEngine] 🔓 Đang giải mã CENC DRM trên máy '
      '(size: $encryptedSize bytes)...',
    );
    try {
      await compute(_decryptDownloadedHongguoVideo, {
        'inputPath': encryptedFile.path,
        'outputPath': decryptedPartFile.path,
        'contentKeyHex': info.contentKeyHex,
      });
      if (await targetFile.exists()) {
        await targetFile.delete();
      }
      await decryptedPartFile.rename(targetFile.path);
    } finally {
      if (await encryptedFile.exists()) {
        await encryptedFile.delete();
      }
      if (await decryptedPartFile.exists()) {
        await decryptedPartFile.delete();
      }
    }
    debugPrint(
      '[HongguoLocalEngine] 🎉 Giải mã hoàn tất! File lưu tại: ${targetFile.path}',
    );

    // Tự động dọn dẹp cache nếu đầy
    await VideoCacheManager.pruneCacheIfNeeded();

    return targetFile.path;
  }
}
