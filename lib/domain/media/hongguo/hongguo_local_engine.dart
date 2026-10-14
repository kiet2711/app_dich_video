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
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    debugPrint('[HongguoLocalEngine] API status: ${res.statusCode}');

    final data = res.data is Map ? res.data as Map : <String, dynamic>{};
    final apiCode =
        int.tryParse((data['Code'] ?? data['code'])?.toString() ?? '0') ?? 0;
    if (apiCode != 0) {
      throw StateError(
        'ByteDance từ chối request (code $apiCode): '
        '${data['Message'] ?? data['message'] ?? 'không rõ lỗi'}',
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
    for (final responsePart in [fbData, videoInfo]) {
      final code =
          int.tryParse(
            (responsePart['Code'] ?? responsePart['code'] ?? 0).toString(),
          ) ??
          0;
      if (code != 0) {
        throw StateError('ByteDance fallback từ chối request (code $code)');
      }
    }
    final videoData = videoInfo['data'] is Map
        ? videoInfo['data'] as Map
        : <String, dynamic>{};
    if (videoData.isEmpty) {
      throw StateError('ByteDance fallback không trả về dữ liệu video');
    }

    final keySeedB64 = videoData['key_seed']?.toString() ?? '';
    final keySeedRaw = keySeedB64.isNotEmpty
        ? HongguoCencDecryptor.b64DecodePadded(keySeedB64)
        : Uint8List(0);

    final videoList = videoData['video_list'] is Map
        ? videoData['video_list'] as Map
        : <String, dynamic>{};
    int codecRank(Map item) {
      final meta = item['video_meta'];
      final codec =
          (item['codec_type'] ??
                  (meta is Map ? meta['codec_type'] : null) ??
                  '')
              .toString()
              .toLowerCase();
      if (const ['h264', 'avc', 'avc1'].contains(codec)) return 0;
      if (const ['h265', 'hevc', 'hvc1', 'hev1', 'bytevc1'].contains(codec)) {
        return 1;
      }
      return 2;
    }

    int streamHeight(Map item) {
      final meta = item['video_meta'];
      for (final value in [
        item['vheight'],
        item['height'],
        if (meta is Map) meta['vheight'],
        if (meta is Map) meta['height'],
      ]) {
        final parsed = int.tryParse(value?.toString() ?? '');
        if (parsed != null && parsed > 0) return parsed;
      }
      final label =
          (item['quality_desc'] ??
                  item['definition'] ??
                  (meta is Map ? meta['definition'] : null) ??
                  '')
              .toString();
      return int.tryParse(RegExp(r'\d+').firstMatch(label)?.group(0) ?? '') ??
          0;
    }

    final streams =
        videoList.values
            .whereType<Map>()
            .where((item) => codecRank(item) < 2)
            .toList()
          ..sort((a, b) {
            final codecCompare = codecRank(a).compareTo(codecRank(b));
            if (codecCompare != 0) return codecCompare;
            return streamHeight(b).compareTo(streamHeight(a));
          });

    String realMainUrl = '';
    String contentKeyHex = '';
    var bestHeight = 0;
    for (final item in streams) {
      final encryptInfo = item['encrypt_info'];
      final spadeA =
          (item['spade_a'] ??
                  (encryptInfo is Map ? encryptInfo['spade_a'] : null) ??
                  '')
              .toString();
      var candidateKey = '';
      if (spadeA.isNotEmpty) {
        try {
          candidateKey = hex.encode(
            HongguoCencDecryptor.deriveContentKey(spadeA),
          );
        } catch (e) {
          debugPrint('[HongguoLocalEngine] Bỏ qua stream có spade_a lỗi: $e');
          continue;
        }
      }

      final rawCandidates = <dynamic>[
        item['main_url'],
        item['backup_url'],
        if (item['backup_url_list'] is List) ...item['backup_url_list'] as List,
        item['play_addr'],
      ];
      for (final raw in rawCandidates) {
        final encodedUrl = raw?.toString() ?? '';
        if (encodedUrl.isEmpty) continue;
        try {
          final decodedUrl = keySeedRaw.isNotEmpty
              ? HongguoCencDecryptor.decryptSpadeUrl(encodedUrl, keySeedRaw)
              : encodedUrl
                    .replaceAll(r'\/', '/')
                    .replaceAll(r'\u0026', '&')
                    .replaceAll('&amp;', '&');
          if (decodedUrl.startsWith('https://') ||
              decodedUrl.startsWith('http://')) {
            realMainUrl = decodedUrl;
            contentKeyHex = candidateKey;
            bestHeight = streamHeight(item);
            break;
          }
        } catch (e) {
          debugPrint('[HongguoLocalEngine] URL stream không dùng được: $e');
        }
      }
      if (realMainUrl.isNotEmpty) break;
    }

    if (realMainUrl.isEmpty) {
      throw StateError(
        'ByteDance không trả về stream H.264/HEVC hợp lệ cho video $cleanVideoId',
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
          'referer': 'https://novelquickapp.com/',
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
