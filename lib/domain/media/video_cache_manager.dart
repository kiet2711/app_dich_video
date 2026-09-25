import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'bilibili_resolver.dart';


class VideoCacheManager {
  static const int defaultMaxCacheSizeBytes = 1500 * 1024 * 1024; // 1.5 GB

  static Directory? _cacheDirectory;

  /// Lấy thư mục lưu cache video của ứng dụng
  static Future<Directory> getCacheDirectory() async {
    if (_cacheDirectory != null && await _cacheDirectory!.exists()) {
      return _cacheDirectory!;
    }
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory('${supportDir.path}${Platform.pathSeparator}video_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDirectory = dir;
    return dir;
  }

  /// Tạo tên file chuẩn cho video đã tải
  static String getCacheKey({
    required String url,
    String? seriesId,
    int? episodeIndex,
    String? bvid,
    int? bilibiliPage,
  }) {
    if (bvid != null && bvid.isNotEmpty) {
      final cleanBvid = bvid.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '');
      final p = (bilibiliPage != null && bilibiliPage > 0) ? bilibiliPage : 1;
      return 'bili_${cleanBvid}_p$p.mp4';
    }
    if (seriesId != null && seriesId.isNotEmpty && episodeIndex != null && episodeIndex > 0) {
      final cleanSid = seriesId.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '');
      return 'hg_${cleanSid}_ep$episodeIndex.mp4';
    }

    // Tự động nhận diện nếu url là liên kết Bilibili
    final biliMatch = RegExp(r'(BV[a-zA-Z0-9]+)', caseSensitive: false).firstMatch(url);
    if (biliMatch != null) {
      final bvidFromUrl = biliMatch.group(1)!;
      final pMatch = RegExp(r'[?&]p=(\d+)').firstMatch(url);
      final p = pMatch?.group(1) ?? '1';
      return 'bili_${bvidFromUrl}_p$p.mp4';
    }

    final cleanUrl = url.split('?').first.trim();
    final hash = md5.convert(utf8.encode(cleanUrl.isNotEmpty ? cleanUrl : url)).toString();
    return 'video_$hash.mp4';
  }

  /// Lấy đối tượng File của video trong cache
  static Future<File> getCachedVideoFile({
    required String url,
    String? seriesId,
    int? episodeIndex,
    String? bvid,
    int? bilibiliPage,
  }) async {
    final dir = await getCacheDirectory();
    final fileName = getCacheKey(
      url: url,
      seriesId: seriesId,
      episodeIndex: episodeIndex,
      bvid: bvid,
      bilibiliPage: bilibiliPage,
    );
    return File('${dir.path}${Platform.pathSeparator}$fileName');
  }

  /// Kiểm tra xem file video đã được tải hoàn chỉnh vào cache chưa
  static Future<bool> hasValidCache({
    required String url,
    String? seriesId,
    int? episodeIndex,
    String? bvid,
    int? bilibiliPage,
  }) async {
    try {
      final file = await getCachedVideoFile(
        url: url,
        seriesId: seriesId,
        episodeIndex: episodeIndex,
        bvid: bvid,
        bilibiliPage: bilibiliPage,
      );
      return await file.exists() && await file.length() > 1024 * 100;
    } catch (_) {
      return false;
    }
  }

  /// Tìm file video đã tải trong cache (trả về File nếu hợp lệ, ngược lại trả về null)
  static Future<File?> findCachedFile({
    required String url,
    String? seriesId,
    int? episodeIndex,
    String? bvid,
    int? bilibiliPage,
  }) async {
    try {
      // 1. Kiểm tra trực tiếp theo cache key tiêu chuẩn
      final file = await getCachedVideoFile(
        url: url,
        seriesId: seriesId,
        episodeIndex: episodeIndex,
        bvid: bvid,
        bilibiliPage: bilibiliPage,
      );
      if (await file.exists() && await file.length() > 1024 * 100) {
        return file;
      }

      // 2. Nếu chưa tìm thấy và url có thể là Bilibili (bao gồm link rút gọn b23.tv)
      if (bvid == null && BilibiliResolver.isBilibiliPageUrl(url)) {
        try {
          final target = await BilibiliResolver().resolveUrl(url);
          if (target.bvid != null && target.bvid!.isNotEmpty) {
            final page = bilibiliPage ?? target.pageIndex;
            final fileResolved = await getCachedVideoFile(
              url: target.rawUrl,
              bvid: target.bvid,
              bilibiliPage: page,
            );
            if (await fileResolved.exists() && await fileResolved.length() > 1024 * 100) {
              return fileResolved;
            }
          }
        } catch (_) {}
      }
    } catch (_) {}
    return null;
  }

  /// Tự động dọn dẹp các video cũ nhất khi tổng dung lượng cache vượt quá giới hạn
  static Future<void> pruneCacheIfNeeded({int maxSizeBytes = defaultMaxCacheSizeBytes}) async {
    try {
      final dir = await getCacheDirectory();
      final entities = dir.listSync();
      final files = entities.whereType<File>().toList();

      var totalBytes = 0;
      for (final f in files) {
        totalBytes += f.lengthSync();
      }

      if (totalBytes > maxSizeBytes) {
        // Sắp xếp theo thời gian truy cập/sửa đổi cũ nhất lên đầu (LRU)
        files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));

        for (final f in files) {
          if (totalBytes <= maxSizeBytes * 0.75) break; // Giảm xuống 75% ngưỡng
          final size = f.lengthSync();
          try {
            f.deleteSync();
            totalBytes -= size;
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Xoá toàn bộ video đã cache để giải phóng bộ nhớ
  static Future<void> clearAllCache() async {
    try {
      final dir = await getCacheDirectory();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        _cacheDirectory = null;
      }
    } catch (_) {}
  }
}
