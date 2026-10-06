import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'bilibili_resolver.dart';
import 'hongguo_cenc_decryptor.dart';


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
      if (await file.exists() && await file.length() > 1024 * 100) {
        if (await HongguoCencDecryptor.isCorruptedMp4File(file)) {
          try { await file.delete(); } catch (_) {}
          return false;
        }
        return true;
      }
      return false;
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
      final dir = await getCacheDirectory();

      Future<File?> validateFile(File? f) async {
        if (f == null || !await f.exists()) return null;
        if (await f.length() <= 1024 * 50) return null;
        if (await HongguoCencDecryptor.isCorruptedMp4File(f)) {
          debugPrint('[VideoCacheManager] ⚠️ Xóa file cache MP4 lỗi atom: ${f.path}');
          try {
            await f.delete();
          } catch (_) {}
          return null;
        }
        return f;
      }

      // 1. Kiểm tra trực tiếp theo cache key tiêu chuẩn
      final file = await getCachedVideoFile(
        url: url,
        seriesId: seriesId,
        episodeIndex: episodeIndex,
        bvid: bvid,
        bilibiliPage: bilibiliPage,
      );
      final validStandard = await validateFile(file);
      if (validStandard != null) {
        return validStandard;
      }

      // 2. Nếu là phim bộ Hồng Quả (có seriesId & episodeIndex):
      // Quét thư mục tìm file khớp prefix 'hg_${cleanSid}_ep$episodeIndex'
      if (seriesId != null && seriesId.isNotEmpty && episodeIndex != null && episodeIndex > 0) {
        final cleanSid = seriesId.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '');
        final targetName = 'hg_${cleanSid}_ep$episodeIndex.mp4';
        final exactFile = File('${dir.path}${Platform.pathSeparator}$targetName');
        final validExact = await validateFile(exactFile);
        if (validExact != null) {
          return validExact;
        }

        // Quét danh sách file trong cache đề phòng case-sensitivity hoặc suffix
        try {
          final entities = dir.listSync();
          final prefix = 'hg_${cleanSid}_ep$episodeIndex';
          for (final e in entities) {
            if (e is File) {
              final filename = e.path.split(RegExp(r'[/\\]')).last;
              if (filename.toLowerCase().startsWith(prefix.toLowerCase()) &&
                  filename.endsWith('.mp4') &&
                  !filename.endsWith('.part')) {
                final validEntity = await validateFile(e);
                if (validEntity != null) {
                  return validEntity;
                }
              }
            }
          }
        } catch (_) {}
      }

      // 3. Kiểm tra theo URL MD5 hash (cho trường hợp video tải bằng URL online)
      if (url.isNotEmpty && (url.startsWith('http://') || url.startsWith('https://'))) {
        final cleanUrl = url.split('?').first.trim();
        final hash1 = md5.convert(utf8.encode(cleanUrl.isNotEmpty ? cleanUrl : url)).toString();
        final fileHash1 = File('${dir.path}${Platform.pathSeparator}video_$hash1.mp4');
        final validHash1 = await validateFile(fileHash1);
        if (validHash1 != null) {
          return validHash1;
        }

        final hash2 = md5.convert(utf8.encode(url)).toString();
        final fileHash2 = File('${dir.path}${Platform.pathSeparator}video_$hash2.mp4');
        final validHash2 = await validateFile(fileHash2);
        if (validHash2 != null) {
          return validHash2;
        }
      }

      // 4. Nếu chưa tìm thấy và url có thể là Bilibili (bao gồm link rút gọn b23.tv)
      if (bvid == null && url.isNotEmpty && BilibiliResolver.isBilibiliPageUrl(url)) {
        try {
          final target = await BilibiliResolver().resolveUrl(url);
          if (target.bvid != null && target.bvid!.isNotEmpty) {
            final page = bilibiliPage ?? target.pageIndex;
            final fileResolved = await getCachedVideoFile(
              url: target.rawUrl,
              bvid: target.bvid,
              bilibiliPage: page,
            );
            if (await fileResolved.exists() && await fileResolved.length() > 1024 * 50) {
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

  /// Xoá file video cache của một tập phim Hồng Quả cụ thể (ví dụ: tập đã xem trước đó)
  static Future<bool> deleteHongguoEpisodeCache({
    required String seriesId,
    required int episodeIndex,
  }) async {
    try {
      final dir = await getCacheDirectory();
      final cleanSid = seriesId.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '');
      final targetPrefix = 'hg_${cleanSid}_ep$episodeIndex';
      var deleted = false;

      // 1. Xoá file mp4 chính xác
      final exactFile = File('${dir.path}${Platform.pathSeparator}$targetPrefix.mp4');
      if (await exactFile.exists()) {
        await exactFile.delete();
        deleted = true;
        debugPrint('[CacheManager] ✅ Đã xoá cache tập cũ: $targetPrefix.mp4');
      }

      // 2. Xoá file tạm .part nếu có
      final partFile = File('${dir.path}${Platform.pathSeparator}$targetPrefix.mp4.part');
      if (await partFile.exists()) {
        await partFile.delete();
        deleted = true;
      }

      // 3. Quét kiểm tra phòng trường hợp có đuôi mở rộng hoặc case sensitivity
      try {
        final entities = dir.listSync();
        for (final e in entities) {
          if (e is File) {
            final filename = e.path.split(RegExp(r'[/\\]')).last;
            if (filename.toLowerCase().startsWith('${targetPrefix.toLowerCase()}.') ||
                filename.toLowerCase() == '$targetPrefix.mp4'.toLowerCase()) {
              if (await e.exists()) {
                await e.delete();
                deleted = true;
                debugPrint('[CacheManager] ✅ Đã dọn file cache tập cũ liên quan: $filename');
              }
            }
          }
        }
      } catch (_) {}

      return deleted;
    } catch (e) {
      debugPrint('[CacheManager] ⚠️ Lỗi khi xoá cache tập $episodeIndex: $e');
      return false;
    }
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
