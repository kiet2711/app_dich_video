import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class _FeedStreamRegistration {
  final String streamId;
  String upstreamUrl;
  Map<String, String> headers;
  int? totalLength;
  DateTime lastAccess;

  _FeedStreamRegistration({
    required this.streamId,
    required this.upstreamUrl,
    required this.headers,
  }) : lastAccess = DateTime.now();

  void touch() => lastAccess = DateTime.now();
}

/// Local HTTP Range raw-byte cache server chuẩn TikTok/MDL cho Feed:
/// - Không giải mã DRM bằng Dart (giữ nguyên raw byte để FFmpeg/mpv giải mã CENC native).
/// - Tải trước 1.5MB đầu (3 chunk x 512KB) của N+1..N+4 vào RAM + Disk LRU cache.
/// - Phục vụ tức thì qua 127.0.0.1 khi lướt tiến liên tiếp hoặc lướt ngược N-1..N-4.
class FeedByteCacheServer {
  FeedByteCacheServer._();

  static final FeedByteCacheServer instance = FeedByteCacheServer._();

  static const int chunkSize = 512 * 1024; // 512 KB
  static const int defaultPreloadBytes = 1536 * 1024; // 1.5 MB (~6-10s video)
  static const int maxRamBytes = 20 * 1024 * 1024; // 20 MB hot RAM LRU
  static const int maxDiskBytes = 120 * 1024 * 1024; // 120 MB disk temp LRU
  static const int _maxRegistrations = 80;

  HttpServer? _server;
  int? _port;
  Future<void>? _startFuture;
  HttpClient? _httpClient;
  Directory? _cacheDir;
  bool _hasScheduledPrune = false;

  final LinkedHashMap<String, _FeedStreamRegistration> _registrations =
      LinkedHashMap<String, _FeedStreamRegistration>();
  final LinkedHashMap<String, Uint8List> _ramChunks =
      LinkedHashMap<String, Uint8List>();
  int _ramBytes = 0;

  final Map<String, Future<Uint8List?>> _inFlightChunks = {};

  /// Cho phép unit test ghi đè thư mục cache disk.
  @visibleForTesting
  Directory? testCacheDirectoryOverride;

  /// Cho phép unit test dùng mock HTTP upstream trên 127.0.0.1.
  @visibleForTesting
  bool allowLoopbackUpstreamForTesting = false;

  bool get isRunning => _server != null && _port != null;
  int? get port => _port;

  static bool isCacheableUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return false;
    final lower = trimmed.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return false;
    }
    if (lower.startsWith('http://127.0.0.1:') ||
        lower.startsWith('http://localhost:')) {
      return false;
    }
    if (lower.contains('.m3u8')) {
      return false;
    }
    return true;
  }

  HttpClient _ensureHttpClient() {
    final existing = _httpClient;
    if (existing != null) return existing;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 20)
      ..maxConnectionsPerHost = 6
      ..autoUncompress = false;
    _httpClient = client;
    return client;
  }

  Future<Directory?> _getCacheDir() async {
    if (testCacheDirectoryOverride != null) {
      if (!testCacheDirectoryOverride!.existsSync()) {
        testCacheDirectoryOverride!.createSync(recursive: true);
      }
      return testCacheDirectoryOverride;
    }
    if (_cacheDir != null && _cacheDir!.existsSync()) {
      return _cacheDir;
    }
    try {
      final tempDir = await getTemporaryDirectory();
      final dir = Directory(
        '${tempDir.path}${Platform.pathSeparator}feed_byte_cache',
      );
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
      }
      _cacheDir = dir;
      return dir;
    } catch (_) {
      return null;
    }
  }

  Future<void> ensureStarted() async {
    if (_server != null && _port != null) return;
    if (_startFuture != null) return _startFuture!;

    final future = () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      _port = server.port;
      server.listen(
        _handleRequest,
        onError: (Object e) {
          debugPrint('[FeedByteCacheServer] Server error: $e');
        },
      );
      _scheduleDiskPrune();
    }();

    _startFuture = future;
    try {
      await future;
    } finally {
      if (identical(_startFuture, future)) {
        _startFuture = null;
      }
    }
  }

  /// Tạo ID duy nhất theo rendition (host + path) để tránh trộn chunk giữa các độ phân giải khác nhau,
  /// đồng thời tái sử dụng được cache kể cả khi CDN đổi chữ ký query string.
  static String buildStreamId({
    required String url,
    String? cacheKeyHint,
  }) {
    final uri = Uri.tryParse(url);
    final stablePath = uri != null
        ? '${uri.host}${uri.path}'
        : url.split('?').first;
    final raw = '${cacheKeyHint ?? ''}|$stablePath';
    return md5.convert(utf8.encode(raw)).toString();
  }

  String registerStream({
    required String url,
    Map<String, String> headers = const {},
    String? cacheKeyHint,
  }) {
    if (_port == null) {
      throw StateError('FeedByteCacheServer chưa khởi động');
    }
    final streamId = buildStreamId(url: url, cacheKeyHint: cacheKeyHint);
    final existing = _registrations.remove(streamId);
    if (existing != null) {
      existing.upstreamUrl = url;
      if (headers.isNotEmpty) {
        existing.headers = Map<String, String>.from(headers);
      }
      existing.touch();
      _registrations[streamId] = existing;
    } else {
      _registrations[streamId] = _FeedStreamRegistration(
        streamId: streamId,
        upstreamUrl: url,
        headers: Map<String, String>.from(headers),
      );
      while (_registrations.length > _maxRegistrations) {
        _registrations.remove(_registrations.keys.first);
      }
    }
    return 'http://127.0.0.1:$_port/s/$streamId';
  }

  /// Tải trước [maxBytes] đầu tiên (mặc định 1.5MB = 3 chunk 512KB) vào RAM + Disk cache.
  Future<void> preloadFirstBytes({
    required String url,
    Map<String, String> headers = const {},
    String? cacheKeyHint,
    int maxBytes = defaultPreloadBytes,
    CancelToken? cancelToken,
  }) async {
    if (!allowLoopbackUpstreamForTesting && !isCacheableUrl(url)) return;
    if (cancelToken?.isCancelled == true) return;
    await ensureStarted();
    if (cancelToken?.isCancelled == true) return;

    final streamId = buildStreamId(url: url, cacheKeyHint: cacheKeyHint);
    registerStream(url: url, headers: headers, cacheKeyHint: cacheKeyHint);
    final reg = _registrations[streamId];
    if (reg == null) return;

    final chunksToFetch = math.max(1, (maxBytes + chunkSize - 1) ~/ chunkSize);
    for (var chunkIdx = 0; chunkIdx < chunksToFetch; chunkIdx++) {
      if (cancelToken?.isCancelled == true) return;
      final totalLen = reg.totalLength;
      if (totalLen != null && chunkIdx * chunkSize >= totalLen) {
        break;
      }
      final bytes = await _getOrFetchChunk(reg, chunkIdx);
      if (bytes == null || bytes.isEmpty) {
        break;
      }
    }
  }

  String _chunkCacheKey(String streamId, int chunkIndex) =>
      '$streamId:$chunkIndex';

  File _chunkFile(Directory dir, String streamId, int chunkIndex) => File(
        '${dir.path}${Platform.pathSeparator}${streamId}_$chunkIndex.chk',
      );

  File _metaFile(Directory dir, String streamId) =>
      File('${dir.path}${Platform.pathSeparator}$streamId.meta');

  Uint8List? _getRamChunk(String key) {
    final value = _ramChunks.remove(key);
    if (value != null) {
      _ramChunks[key] = value;
    }
    return value;
  }

  void _putRamChunk(String key, Uint8List data) {
    final prev = _ramChunks.remove(key);
    if (prev != null) {
      _ramBytes -= prev.length;
    }
    _ramChunks[key] = data;
    _ramBytes += data.length;
    while (_ramBytes > maxRamBytes && _ramChunks.length > 1) {
      final oldestKey = _ramChunks.keys.first;
      final removed = _ramChunks.remove(oldestKey);
      if (removed != null) {
        _ramBytes -= removed.length;
      }
    }
  }

  Future<int?> _readDiskTotalLength(String streamId) async {
    final dir = await _getCacheDir();
    if (dir == null) return null;
    try {
      final meta = _metaFile(dir, streamId);
      if (!meta.existsSync()) return null;
      final text = (await meta.readAsString()).trim();
      final len = int.tryParse(text);
      return (len != null && len > 0) ? len : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDiskTotalLength(String streamId, int totalLength) async {
    final dir = await _getCacheDir();
    if (dir == null) return;
    try {
      await _metaFile(dir, streamId).writeAsString(totalLength.toString());
    } catch (_) {}
  }

  Future<Uint8List?> _readDiskChunk(
    String streamId,
    int chunkIndex, {
    int? expectedLength,
  }) async {
    final dir = await _getCacheDir();
    if (dir == null) return null;
    try {
      final file = _chunkFile(dir, streamId, chunkIndex);
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      if (expectedLength != null && bytes.length != expectedLength) {
        try {
          await file.delete();
        } catch (_) {}
        return null;
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  void _writeDiskChunkAsync(String streamId, int chunkIndex, Uint8List data) {
    unawaited(() async {
      final dir = await _getCacheDir();
      if (dir == null) return;
      try {
        final file = _chunkFile(dir, streamId, chunkIndex);
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsBytes(data, flush: false);
        await tmp.rename(file.path);
        _scheduleDiskPrune();
      } catch (_) {}
    }());
  }

  void _scheduleDiskPrune() {
    if (_hasScheduledPrune) return;
    _hasScheduledPrune = true;
    Future<void>.delayed(const Duration(seconds: 3), () async {
      _hasScheduledPrune = false;
      await _pruneDiskCacheIfNeeded();
    });
  }

  Future<void> _pruneDiskCacheIfNeeded() async {
    final dir = await _getCacheDir();
    if (dir == null || !dir.existsSync()) return;
    try {
      final entries = <({File file, int size, DateTime modified})>[];
      var totalBytes = 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          totalBytes += stat.size;
          entries.add((file: entity, size: stat.size, modified: stat.modified));
        } catch (_) {}
      }
      if (totalBytes <= maxDiskBytes) return;
      entries.sort((a, b) => a.modified.compareTo(b.modified));
      final targetBytes = (maxDiskBytes * 0.78).round();
      for (final entry in entries) {
        if (totalBytes <= targetBytes) break;
        try {
          await entry.file.delete();
          totalBytes -= entry.size;
        } catch (_) {}
      }
    } catch (_) {}
  }

  int? _expectedChunkLength(int chunkIndex, int? totalLength) {
    if (totalLength == null || totalLength <= 0) return null;
    final start = chunkIndex * chunkSize;
    if (start >= totalLength) return 0;
    return math.min(chunkSize, totalLength - start);
  }

  Future<Uint8List?> _getOrFetchChunk(
    _FeedStreamRegistration reg,
    int chunkIndex,
  ) async {
    final key = _chunkCacheKey(reg.streamId, chunkIndex);
    final ramHit = _getRamChunk(key);
    if (ramHit != null) {
      reg.totalLength ??= await _readDiskTotalLength(reg.streamId);
      return ramHit;
    }

    final inFlight = _inFlightChunks[key];
    if (inFlight != null) {
      return inFlight;
    }

    final future = _loadOrFetchChunkImpl(reg, chunkIndex, key);
    _inFlightChunks[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlightChunks[key], future)) {
        _inFlightChunks.remove(key);
      }
    }
  }

  Future<Uint8List?> _loadOrFetchChunkImpl(
    _FeedStreamRegistration reg,
    int chunkIndex,
    String key,
  ) async {
    reg.totalLength ??= await _readDiskTotalLength(reg.streamId);
    final expected = _expectedChunkLength(chunkIndex, reg.totalLength);
    if (expected == 0) return Uint8List(0);

    final diskHit = await _readDiskChunk(
      reg.streamId,
      chunkIndex,
      expectedLength: expected,
    );
    if (diskHit != null) {
      _putRamChunk(key, diskHit);
      return diskHit;
    }

    return _fetchChunkFromUpstream(reg, chunkIndex, key);
  }

  Future<Uint8List?> _fetchChunkFromUpstream(
    _FeedStreamRegistration reg,
    int chunkIndex,
    String key,
  ) async {
    final start = chunkIndex * chunkSize;
    final end = reg.totalLength != null
        ? math.min(start + chunkSize - 1, reg.totalLength! - 1)
        : (start + chunkSize - 1);
    if (end < start) return Uint8List(0);

    final client = _ensureHttpClient();
    HttpClientRequest? req;
    try {
      req = await client.getUrl(Uri.parse(reg.upstreamUrl));
      reg.headers.forEach((k, v) {
        if (k.toLowerCase() != 'range' && k.toLowerCase() != 'host') {
          req!.headers.set(k, v);
        }
      });
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
      final res = await req.close().timeout(const Duration(seconds: 12));

      if (res.statusCode == HttpStatus.partialContent) {
        final contentRange = res.headers.value(HttpHeaders.contentRangeHeader);
        final parsedTotal = _parseTotalFromContentRange(contentRange);
        if (parsedTotal != null && parsedTotal > 0) {
          if (reg.totalLength != parsedTotal) {
            reg.totalLength = parsedTotal;
            unawaited(_writeDiskTotalLength(reg.streamId, parsedTotal));
          }
        }
        final data = await _collectBytes(res);
        if (data.isEmpty) return null;
        final expectedLen = _expectedChunkLength(chunkIndex, reg.totalLength);
        if (expectedLen != null && data.length != expectedLen) {
          // Bảo vệ: chỉ lưu nếu số byte khớp đúng range mong đợi.
          if (data.length > expectedLen) {
            final trimmed = Uint8List.sublistView(data, 0, expectedLen);
            _putRamChunk(key, trimmed);
            _writeDiskChunkAsync(reg.streamId, chunkIndex, trimmed);
            return trimmed;
          }
          return null;
        }
        _putRamChunk(key, data);
        _writeDiskChunkAsync(reg.streamId, chunkIndex, data);
        return data;
      }

      if (res.statusCode == HttpStatus.ok) {
        final contentLen = res.contentLength;
        // Chỉ đọc trực tiếp khi file nhỏ hơn hoặc bằng defaultPreloadBytes;
        // file lớn không hỗ trợ Range sẽ redirect thẳng lên CDN.
        if (contentLen > 0 && contentLen <= defaultPreloadBytes) {
          final fullBytes = await _collectBytes(res);
          reg.totalLength = fullBytes.length;
          unawaited(_writeDiskTotalLength(reg.streamId, fullBytes.length));
          var offset = 0;
          var idx = 0;
          Uint8List? requested;
          while (offset < fullBytes.length) {
            final sliceEnd = math.min(offset + chunkSize, fullBytes.length);
            final slice = Uint8List.fromList(
              fullBytes.sublist(offset, sliceEnd),
            );
            final cKey = _chunkCacheKey(reg.streamId, idx);
            _putRamChunk(cKey, slice);
            _writeDiskChunkAsync(reg.streamId, idx, slice);
            if (idx == chunkIndex) {
              requested = slice;
            }
            offset = sliceEnd;
            idx++;
          }
          return requested;
        }
        await res.drain<void>();
        return null;
      }

      await res.drain<void>();
      return null;
    } catch (_) {
      return null;
    }
  }

  static int? _parseTotalFromContentRange(String? header) {
    if (header == null || !header.contains('/')) return null;
    final totalStr = header.split('/').last.trim();
    if (totalStr == '*') return null;
    return int.tryParse(totalStr);
  }

  static Future<Uint8List> _collectBytes(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        await response.close();
        return;
      }

      final segments = request.uri.pathSegments;
      if (segments.length != 2 || segments[0] != 's') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final streamId = segments[1];
      final reg = _registrations[streamId];
      if (reg == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      reg.touch();

      // Đảm bảo biết totalLength (và có luôn chunk 0 trong cache).
      reg.totalLength ??= await _readDiskTotalLength(streamId);
      if (reg.totalLength == null) {
        final chunk0 = await _getOrFetchChunk(reg, 0);
        if (reg.totalLength == null || chunk0 == null) {
          // Upstream không hỗ trợ Range chuẩn hoặc lỗi tạm: redirect thẳng CDN để không hỏng phát.
          response.statusCode = HttpStatus.found;
          response.headers.set(HttpHeaders.locationHeader, reg.upstreamUrl);
          await response.close();
          return;
        }
      }

      final totalLength = reg.totalLength!;
      if (request.method == 'HEAD') {
        response.statusCode = HttpStatus.ok;
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
        response.headers.set(
          HttpHeaders.contentLengthHeader,
          totalLength.toString(),
        );
        await response.close();
        return;
      }

      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      var start = 0;
      var end = totalLength - 1;
      var isPartial = false;

      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final spec = rangeHeader.substring(6).split(',').first.trim();
        final parts = spec.split('-');
        if (parts.length == 2) {
          if (parts[0].isEmpty && parts[1].isNotEmpty) {
            final suffix = int.tryParse(parts[1]) ?? 0;
            start = math.max(0, totalLength - suffix);
            end = totalLength - 1;
          } else {
            start = int.tryParse(parts[0]) ?? 0;
            end = parts[1].isNotEmpty
                ? math.min(int.tryParse(parts[1]) ?? (totalLength - 1), totalLength - 1)
                : (totalLength - 1);
          }
          isPartial = true;
        }
      }

      if (start < 0 || start >= totalLength || end < start) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */$totalLength',
        );
        await response.close();
        return;
      }

      final contentLength = end - start + 1;
      response.bufferOutput = false;
      response.statusCode =
          isPartial ? HttpStatus.partialContent : HttpStatus.ok;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
      response.headers.set(
        HttpHeaders.contentLengthHeader,
        contentLength.toString(),
      );
      if (isPartial) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$totalLength',
        );
      }

      final firstChunk = start ~/ chunkSize;
      final lastChunk = end ~/ chunkSize;
      for (var chunkIdx = firstChunk; chunkIdx <= lastChunk; chunkIdx++) {
        final chunkBytes = await _getOrFetchChunk(reg, chunkIdx);
        if (chunkBytes == null || chunkBytes.isEmpty) {
          break;
        }
        final chunkStart = chunkIdx * chunkSize;
        final sliceStart = math.max(0, start - chunkStart);
        final sliceEnd = math.min(chunkBytes.length, end - chunkStart + 1);
        if (sliceEnd <= sliceStart) break;
        final slice = (sliceStart == 0 && sliceEnd == chunkBytes.length)
            ? chunkBytes
            : Uint8List.sublistView(chunkBytes, sliceStart, sliceEnd);
        try {
          response.add(slice);
          await response.flush();
        } catch (_) {
          // Client (mpv) đã đóng kết nối do tua hoặc chuyển video.
          return;
        }
      }

      try {
        await response.close();
      } catch (_) {}
    } catch (_) {
      try {
        await response.close();
      } catch (_) {}
    }
  }

  /// Giải phóng RAM/server (chủ yếu dùng cho test hoặc dọn bộ nhớ khi cần).
  Future<void> clearRamCache() async {
    _ramChunks.clear();
    _ramBytes = 0;
  }

  @visibleForTesting
  Future<void> stopForTesting() async {
    _registrations.clear();
    _ramChunks.clear();
    _ramBytes = 0;
    _inFlightChunks.clear();
    _httpClient?.close(force: true);
    _httpClient = null;
    final server = _server;
    _server = null;
    _port = null;
    _startFuture = null;
    if (server != null) {
      await server.close(force: true);
    }
  }
}
