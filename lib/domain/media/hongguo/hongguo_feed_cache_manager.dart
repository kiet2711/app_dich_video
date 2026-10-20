import 'dart:async';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../hongguo_cenc_decryptor.dart';
import 'hongguo_local_engine.dart';

/// Kết quả chuẩn bị media cho 1 tập phim trong Feed
class FeedEpisodeMedia {
  final int episodeIndex;
  final String vid;
  final String? localFilePath;
  final String? directStreamUrl;
  final bool isDrm;

  const FeedEpisodeMedia({
    required this.episodeIndex,
    required this.vid,
    this.localFilePath,
    this.directStreamUrl,
    required this.isDrm,
  });

  bool get isPlayable =>
      (localFilePath != null && File(localFilePath!).existsSync()) ||
      (directStreamUrl != null && directStreamUrl!.isNotEmpty);
}

/// Trình điều phối nạp trước (Prefetch) và quản lý bộ nhớ đệm tự hủy (Rolling Ephemeral Cache)
/// Đảm bảo KHÔNG lưu rác vào bộ nhớ máy, tối đa 3 file trong thư mục tạm, tự dọn dẹp khi thoát.
class HongguoFeedCacheManager {
  static final HongguoFeedCacheManager instance = HongguoFeedCacheManager._();
  HongguoFeedCacheManager._();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 45),
    ),
  );

  /// Lưu trữ các file tạm hiện đang có trong bộ đệm: vid -> File
  final Map<String, File> _activeTempFiles = {};

  /// Lưu trữ metadata info đã resolve: vid -> HongguoVideoInfo
  final Map<String, HongguoVideoInfo> _resolvedInfoCache = {};

  /// Các tác vụ đang tải dở: vid -> CancelToken
  final Map<String, CancelToken> _activeDownloads = {};

  Directory? _tempDir;

  Future<Directory> _getPreviewTempDir() async {
    if (_tempDir != null && _tempDir!.existsSync()) return _tempDir!;
    final baseTemp = await getTemporaryDirectory();
    final feedDir = Directory('${baseTemp.path}${Platform.pathSeparator}hg_feed_preview');
    if (!feedDir.existsSync()) {
      await feedDir.create(recursive: true);
    }
    _tempDir = feedDir;
    return feedDir;
  }

  /// Chuẩn bị nguồn phát cho một tập (Resolve info + Tải/Giải mã nếu có DRM)
  Future<FeedEpisodeMedia?> prepareEpisode({
    required String seriesId,
    required String vid,
    required int episodeIndex,
    bool isPrefetch = false,
  }) async {
    if (vid.isEmpty) return null;

    try {
      // 1. Kiểm tra xem file tạm đã có sẵn chưa
      final existingFile = _activeTempFiles[vid];
      if (existingFile != null && existingFile.existsSync() && existingFile.lengthSync() > 1024 * 100) {
        return FeedEpisodeMedia(
          episodeIndex: episodeIndex,
          vid: vid,
          localFilePath: existingFile.path,
          isDrm: true,
        );
      }

      // 2. Resolve thông tin video từ ByteDance
      HongguoVideoInfo? info = _resolvedInfoCache[vid];
      if (info == null) {
        info = await HongguoLocalEngine.resolveVideoInfo(vid);
        _resolvedInfoCache[vid] = info;
      }

      // Nếu không bị mã hóa DRM (public stream), trả thẳng link CDN để player stream online
      if (!info.isDrmProtected) {
        return FeedEpisodeMedia(
          episodeIndex: episodeIndex,
          vid: vid,
          directStreamUrl: info.realMainUrl,
          isDrm: false,
        );
      }

      // 3. Nếu có DRM: Tải vào thư mục tạm và giải mã CENC trong Isolate
      final tempDir = await _getPreviewTempDir();
      final targetFile = File('${tempDir.path}${Platform.pathSeparator}preview_${vid}_ep$episodeIndex.mp4');
      final encPartFile = File('${targetFile.path}.enc.tmp');

      if (targetFile.existsSync() && targetFile.lengthSync() > 1024 * 100) {
        _activeTempFiles[vid] = targetFile;
        return FeedEpisodeMedia(
          episodeIndex: episodeIndex,
          vid: vid,
          localFilePath: targetFile.path,
          isDrm: true,
        );
      }

      final cancelToken = CancelToken();
      _activeDownloads[vid] = cancelToken;

      try {
        // Tải video mã hóa
        await _dio.download(
          info.realMainUrl,
          encPartFile.path,
          cancelToken: cancelToken,
          options: Options(
            headers: {
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0',
            },
          ),
        );

        if (!encPartFile.existsSync() || encPartFile.lengthSync() < 1024) {
          throw StateError('File tải về không hợp lệ');
        }

        // Giải mã trong Isolate
        final encBytes = await encPartFile.readAsBytes();
        final keyBytes = Uint8List.fromList(hex.decode(info.contentKeyHex));
        final decBytes = await compute(_decryptIsolated, {
          'data': encBytes,
          'key': keyBytes,
        });

        await targetFile.writeAsBytes(decBytes, flush: true);
        if (encPartFile.existsSync()) {
          await encPartFile.delete();
        }

        _activeTempFiles[vid] = targetFile;
        return FeedEpisodeMedia(
          episodeIndex: episodeIndex,
          vid: vid,
          localFilePath: targetFile.path,
          isDrm: true,
        );
      } finally {
        _activeDownloads.remove(vid);
      }
    } catch (e) {
      debugPrint('[HongguoFeedCacheManager] Lỗi nạp tập $episodeIndex ($vid): $e');
      return null;
    }
  }

  static Uint8List _decryptIsolated(Map<String, dynamic> args) {
    final data = args['data'] as Uint8List;
    final key = args['key'] as Uint8List;
    return HongguoCencDecryptor.decryptMp4Cenc(data, key);
  }

  /// Dọn dẹp các file cũ cách xa vị trí hiện tại (Chỉ giữ lại tối đa 3 file: current-1, current, current+1)
  void maintainRollingCache(List<String> activeVids) {
    final activeSet = activeVids.toSet();
    final toRemove = <String>[];

    for (final entry in _activeTempFiles.entries) {
      if (!activeSet.contains(entry.key)) {
        try {
          if (entry.value.existsSync()) {
            entry.value.deleteSync();
          }
        } catch (_) {}
        toRemove.add(entry.key);
      }
    }

    for (final key in toRemove) {
      _activeTempFiles.remove(key);
    }
  }

  /// Hủy tải một tập nếu người dùng lướt qua nhanh
  void cancelDownload(String vid) {
    final token = _activeDownloads.remove(vid);
    token?.cancel('User swiped past');
  }

  /// Dọn sạch toàn bộ thư mục tạm khi người dùng thoát khỏi Feed
  Future<void> disposeAll() async {
    for (final token in _activeDownloads.values) {
      token.cancel('Disposing feed');
    }
    _activeDownloads.clear();

    for (final file in _activeTempFiles.values) {
      try {
        if (file.existsSync()) await file.delete();
      } catch (_) {}
    }
    _activeTempFiles.clear();
    _resolvedInfoCache.clear();

    if (_tempDir != null && _tempDir!.existsSync()) {
      try {
        await _tempDir!.delete(recursive: true);
      } catch (_) {}
      _tempDir = null;
    }
  }
}
