import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:convert/convert.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

import '../hongguo_cenc_decryptor.dart';
import '../video_cache_manager.dart';
import 'hongguo_local_engine.dart';

/// Đại diện cho 1 khoảng sample đã mã hóa trong file MP4
class _SampleInterval {
  final int offset;
  final int size;
  final Uint8List iv8;

  int get endOffset => offset + size;

  _SampleInterval({
    required this.offset,
    required this.size,
    required this.iv8,
  });
}

/// Session quản lý siêu dữ liệu và bộ đệm cho một video đang phát
class _ProxyStreamSession {
  final String vid;
  final String seriesId;
  final int episodeIndex;

  HongguoVideoInfo? info;
  int? totalLength;
  Uint8List? sanitizedHeader;
  int moovEnd = 0;
  bool isDrm = false;
  Uint8List? contentKey;
  File? existingLocalFile;

  List<_SampleInterval> samples = [];

  // Bộ đệm khối (512 KB/chunk) đã giải mã: chunkIndex -> Uint8List
  final Map<int, Uint8List> chunkCache = {};
  DateTime lastAccess = DateTime.now();

  _ProxyStreamSession({
    required this.vid,
    this.seriesId = '',
    this.episodeIndex = 1,
  });

  void touch() => lastAccess = DateTime.now();
}

/// Máy chủ Local HTTP Streaming Proxy mô phỏng kiến trúc MDL (Mobile Download Layer) của ByteDance.
/// - Nhận yêu cầu Range từ Player (MediaKit) qua 127.0.0.1
/// - Tải Header và các chunk byte theo nhu cầu (On-Demand) từ ByteDance CDN
/// - Giải mã CENC on-the-fly ngay trong RAM khi dòng stream đang chảy
/// - Hỗ trợ nạp trước (Preload) 1MB đầu tiên giúp lướt phát ngay 0ms không xoay tròn.
class HongguoStreamProxyServer {
  static final HongguoStreamProxyServer instance = HongguoStreamProxyServer._();
  HongguoStreamProxyServer._();

  static const int chunkSize = 512 * 1024; // 512 KB mỗi chunk

  HttpServer? _server;
  int _port = 0;
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 45),
    ),
  );

  final Map<String, _ProxyStreamSession> _sessions = {};
  final Map<String, Future<void>> _inFlightPrepares = {};

  int get port => _port;
  bool get isRunning => _server != null;

  /// Đảm bảo máy chủ nội bộ đã khởi chạy
  Future<int> ensureStarted() async {
    if (_server != null) return _port;

    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _port = _server!.port;
      debugPrint('[HongguoStreamProxyServer] Khởi động tại http://127.0.0.1:$_port');
      _server!.listen(_handleHttpRequest, onError: (e) {
        debugPrint('[HongguoStreamProxyServer] Lỗi server: $e');
      });
      return _port;
    } catch (e) {
      debugPrint('[HongguoStreamProxyServer] Lỗi khởi động HTTP Server: $e');
      rethrow;
    }
  }

  /// Tạo URL stream nội bộ cho Player
  String getStreamUrl({
    required String vid,
    String? seriesId,
    int? episodeIndex,
  }) {
    if (_port == 0) {
      throw StateError('Proxy server chưa được khởi động. Hãy gọi ensureStarted() trước.');
    }
    final qVid = Uri.encodeComponent(vid);
    final qSid = Uri.encodeComponent(seriesId ?? '');
    final qEp = episodeIndex ?? 1;
    return 'http://127.0.0.1:$_port/stream?vid=$qVid&sid=$qSid&ep=$qEp';
  }

  /// Nạp trước (Preload) Header và 1.5MB đầu tiên của tập kế tiếp
  /// Giúp khi người dùng vuốt sang là phát ngay lập tức không có độ trễ
  Future<void> preloadStream({
    required String vid,
    String? seriesId,
    int? episodeIndex,
  }) async {
    if (vid.isEmpty) return;
    await ensureStarted();

    if (_inFlightPrepares.containsKey(vid)) {
      return _inFlightPrepares[vid];
    }

    final completer = Completer<void>();
    _inFlightPrepares[vid] = completer.future;

    try {
      final session = _getOrCreateSession(
        vid: vid,
        seriesId: seriesId ?? '',
        episodeIndex: episodeIndex ?? 1,
      );
      await _prepareSessionMetadata(session);
      completer.complete();
    } catch (e) {
      debugPrint('[HongguoStreamProxyServer] Preload lỗi ($vid): $e');
      completer.completeError(e);
    } finally {
      _inFlightPrepares.remove(vid);
    }
  }

  _ProxyStreamSession _getOrCreateSession({
    required String vid,
    required String seriesId,
    required int episodeIndex,
  }) {
    return _sessions.putIfAbsent(
      vid,
      () => _ProxyStreamSession(
        vid: vid,
        seriesId: seriesId,
        episodeIndex: episodeIndex,
      ),
    );
  }

  /// Chuẩn bị thông tin video, tải Header và giải mã bảng mẫu (Sample Table)
  Future<void> _prepareSessionMetadata(_ProxyStreamSession session) async {
    if (session.totalLength != null && (session.sanitizedHeader != null || !session.isDrm || session.existingLocalFile != null)) {
      session.touch();
      return;
    }

    // 1. Kiểm tra xem file đã có sẵn trong VideoCacheManager chưa
    try {
      final cachedFile = await VideoCacheManager.findCachedFile(
        url: '',
        seriesId: session.seriesId.isNotEmpty ? session.seriesId : null,
        episodeIndex: session.episodeIndex > 0 ? session.episodeIndex : null,
      );
      if (cachedFile != null && cachedFile.existsSync() && cachedFile.lengthSync() > 1024 * 50) {
        session.existingLocalFile = cachedFile;
        session.totalLength = cachedFile.lengthSync();
        session.touch();
        return;
      }
    } catch (_) {}

    // 2. Resolve thông tin video từ ByteDance
    session.info ??= await HongguoLocalEngine.resolveVideoInfo(session.vid);
    final info = session.info!;
    session.isDrm = info.isDrmProtected;

    // 3. Nếu không có DRM (public stream): Lấy Content-Length từ CDN
    if (!session.isDrm) {
      final headRes = await _dio.head(
        info.realMainUrl,
        options: Options(
          headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0',
            'Referer': 'https://hongguoduanju.com/',
          },
        ),
      );
      final lenStr = headRes.headers.value('content-length');
      session.totalLength = int.tryParse(lenStr ?? '0') ?? 0;
      session.touch();
      return;
    }

    // 4. Có DRM CENC: Tải 1MB đầu tiên để bóc tách Header moov và Sample Table
    session.contentKey = Uint8List.fromList(hex.decode(info.contentKeyHex));

    final initChunkRes = await _dio.get<List<int>>(
      info.realMainUrl,
      options: Options(
        responseType: ResponseType.bytes,
        headers: {
          'Range': 'bytes=0-1048575', // 1 MB đầu tiên
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0',
          'Referer': 'https://hongguoduanju.com/',
        },
      ),
    );

    final crHeader = initChunkRes.headers.value('content-range');
    if (crHeader != null && crHeader.contains('/')) {
      final totalStr = crHeader.split('/').last.trim();
      session.totalLength = int.tryParse(totalStr);
    }
    if (session.totalLength == null || session.totalLength! <= 0) {
      session.totalLength = 15 * 1024 * 1024; // Dự phòng 15MB
    }

    final rawInitBytes = Uint8List.fromList(initChunkRes.data!);

    // Bóc tách box moov
    final bd = ByteData.sublistView(rawInitBytes);
    var moovOff = -1;
    var moovSize = 0;
    final (foundMoovOff, foundMoovSz) = HongguoCencDecryptor.findBox(rawInitBytes, 'moov', 0);
    if (foundMoovOff >= 0) {
      moovOff = foundMoovOff;
      moovSize = foundMoovSz;
    } else {
      final ftypEnd = bd.getUint32(0, Endian.big);
      if (ftypEnd + 8 < rawInitBytes.length) {
        moovOff = ftypEnd;
        moovSize = bd.getUint32(ftypEnd, Endian.big);
      }
    }

    if (moovOff < 0 || moovSize <= 0) {
      throw FormatException('Không tìm thấy box moov trong 1MB đầu của video ${session.vid}');
    }

    session.moovEnd = moovOff + moovSize;

    // Parse các track và xây dựng danh sách sample
    final moovBytes = rawInitBytes.sublist(moovOff + 8, session.moovEnd);
    final allSamples = <_SampleInterval>[];

    var trakSearchStart = 0;
    while (trakSearchStart < moovBytes.length - 8) {
      final (tOff, tSz) = HongguoCencDecryptor.findBox(moovBytes, 'trak', trakSearchStart);
      if (tOff < 0 || tSz <= 0) break;
      trakSearchStart = tOff + (tSz > 0 ? tSz : 8);

      final parsed = HongguoCencDecryptor.parseTrack(moovBytes, tOff);
      if (parsed == null || parsed.ns == 0) continue;

      // Đọc bảng aux (IVs)
      Uint8List auxBytes;
      if (parsed.auxOff + parsed.auxSz <= rawInitBytes.length) {
        auxBytes = rawInitBytes.sublist(parsed.auxOff, parsed.auxOff + parsed.auxSz);
      } else {
        // Nếu aux nằm ngoài 1MB, tải thêm phần aux
        final auxRes = await _dio.get<List<int>>(
          info.realMainUrl,
          options: Options(
            responseType: ResponseType.bytes,
            headers: {
              'Range': 'bytes=${parsed.auxOff}-${parsed.auxOff + parsed.auxSz - 1}',
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0',
            },
          ),
        );
        auxBytes = Uint8List.fromList(auxRes.data!);
      }

      var si = 0;
      var ap = 0;
      for (var ci = 0; ci < parsed.offsets.length; ci++) {
        var off = parsed.offsets[ci];
        final count = parsed.cns[ci];

        for (var k = 0; k < count; k++) {
          if (si >= parsed.ns) break;
          final sz = parsed.sizes[si];
          final iv8 = Uint8List(8);
          if (ap + 8 <= auxBytes.length) {
            iv8.setRange(0, 8, auxBytes.sublist(ap, ap + 8));
          }
          allSamples.add(_SampleInterval(offset: off, size: sz, iv8: iv8));
          off += sz;
          si++;
          ap += 8;
        }
      }
    }

    allSamples.sort((a, b) => a.offset.compareTo(b.offset));
    session.samples = allSamples;

    // Sửa header: đổi sinf -> free và đổi FourCC encv -> hvc1/avc1, enca -> mp4a
    final cleanHeader = rawInitBytes.sublist(0, session.moovEnd);
    HongguoCencDecryptor.replaceSinf(cleanHeader);
    HongguoCencDecryptor.replaceFourcc(cleanHeader, ascii.encode('encv'), ascii.encode('hvc1'));
    HongguoCencDecryptor.replaceFourcc(cleanHeader, ascii.encode('enca'), ascii.encode('mp4a'));
    session.sanitizedHeader = cleanHeader;

    // Giải mã luôn phần mdat nằm trong 1MB đầu tiên và nạp vào chunkCache (Chunk 0, 1)
    if (rawInitBytes.length > session.moovEnd) {
      final initialMdat = rawInitBytes.sublist(session.moovEnd);
      _decryptSampleIntervals(
        data: initialMdat,
        rangeStart: session.moovEnd,
        samples: session.samples,
        contentKey: session.contentKey!,
      );

      // Ghép Header + Mdat đầu tiên thành 1 khối hoàn chỉnh cho Chunk 0 & 1
      final combined = Uint8List(cleanHeader.length + initialMdat.length);
      combined.setRange(0, cleanHeader.length, cleanHeader);
      combined.setRange(cleanHeader.length, combined.length, initialMdat);

      for (var off = 0; off < combined.length; off += chunkSize) {
        final end = math.min(off + chunkSize, combined.length);
        final chunkIdx = off ~/ chunkSize;
        session.chunkCache[chunkIdx] = combined.sublist(off, end);
      }
    }

    session.touch();
  }

  /// Giải mã một khối dữ liệu dựa theo vị trí offset của nó trong file
  static void _decryptSampleIntervals({
    required Uint8List data,
    required int rangeStart,
    required List<_SampleInterval> samples,
    required Uint8List contentKey,
  }) {
    final rangeEnd = rangeStart + data.length;

    for (final s in samples) {
      if (s.endOffset <= rangeStart) continue;
      if (s.offset >= rangeEnd) break;

      final intersectStart = math.max(s.offset, rangeStart);
      final intersectEnd = math.min(s.endOffset, rangeEnd);
      final intersectLen = intersectEnd - intersectStart;
      if (intersectLen <= 0) continue;

      final chunkBufOffset = intersectStart - rangeStart;
      final sampleRelOffset = intersectStart - s.offset;

      final blockIndex = sampleRelOffset ~/ 16;
      final offsetInBlock = sampleRelOffset % 16;

      final blockIv = Uint8List(16);
      blockIv.setRange(0, 8, s.iv8);
      ByteData.sublistView(blockIv).setUint64(8, blockIndex, Endian.big);

      final cipher = StreamCipher('AES/SIC')
        ..init(false, ParametersWithIV(KeyParameter(contentKey), blockIv));

      if (offsetInBlock > 0) {
        final dummy = Uint8List(offsetInBlock);
        cipher.processBytes(dummy, 0, offsetInBlock, dummy, 0);
      }

      final cipherSlice = data.sublist(chunkBufOffset, chunkBufOffset + intersectLen);
      final decryptedSlice = Uint8List(intersectLen);
      cipher.processBytes(cipherSlice, 0, intersectLen, decryptedSlice, 0);

      data.setRange(chunkBufOffset, chunkBufOffset + intersectLen, decryptedSlice);
    }
  }

  /// Lấy 1 chunk 512KB (đã giải mã) tại chunkIndex
  Future<Uint8List> _getOrFetchChunk(_ProxyStreamSession session, int chunkIndex) async {
    final cached = session.chunkCache[chunkIndex];
    if (cached != null) return cached;

    final start = chunkIndex * chunkSize;
    final total = session.totalLength ?? (30 * 1024 * 1024);
    final end = math.min(start + chunkSize - 1, total - 1);
    if (start >= total) return Uint8List(0);

    // Tải chunk từ CDN
    final res = await _dio.get<List<int>>(
      session.info!.realMainUrl,
      options: Options(
        responseType: ResponseType.bytes,
        headers: {
          'Range': 'bytes=$start-$end',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0',
          'Referer': 'https://hongguoduanju.com/',
        },
      ),
    );

    final chunkData = Uint8List.fromList(res.data!);

    // Giải mã nếu có DRM
    if (session.isDrm && session.contentKey != null) {
      // Nếu chunk này cắt qua phần Header moov: ghi đè phần header sạch
      if (start < session.moovEnd && session.sanitizedHeader != null) {
        final headerOverlapEnd = math.min(session.moovEnd, end + 1);
        final overlapLen = headerOverlapEnd - start;
        chunkData.setRange(0, overlapLen, session.sanitizedHeader!.sublist(start, headerOverlapEnd));

        // Phần còn lại thuộc mdat thì giải mã
        if (headerOverlapEnd < end + 1) {
          final mdatSlice = chunkData.sublist(overlapLen);
          _decryptSampleIntervals(
            data: mdatSlice,
            rangeStart: headerOverlapEnd,
            samples: session.samples,
            contentKey: session.contentKey!,
          );
          chunkData.setRange(overlapLen, chunkData.length, mdatSlice);
        }
      } else {
        // Toàn bộ chunk thuộc mdat
        _decryptSampleIntervals(
          data: chunkData,
          rangeStart: start,
          samples: session.samples,
          contentKey: session.contentKey!,
        );
      }
    }

    session.chunkCache[chunkIndex] = chunkData;
    return chunkData;
  }

  /// Điều phối xử lý yêu cầu HTTP từ MediaKit
  Future<void> _handleHttpRequest(HttpRequest request) async {
    try {
      final uri = request.uri;
      if (uri.path != '/stream') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      final vid = uri.queryParameters['vid'] ?? '';
      final sid = uri.queryParameters['sid'] ?? '';
      final ep = int.tryParse(uri.queryParameters['ep'] ?? '1') ?? 1;

      if (vid.isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }

      final session = _getOrCreateSession(vid: vid, seriesId: sid, episodeIndex: ep);
      await _prepareSessionMetadata(session);

      // Nếu có sẵn file local hoàn chỉnh, phát trực tiếp từ file
      if (session.existingLocalFile != null && session.existingLocalFile!.existsSync()) {
        await _serveLocalFile(request, session.existingLocalFile!);
        return;
      }

      final total = session.totalLength ?? 0;
      if (total <= 0) {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
        return;
      }

      // Đọc Range header
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      int start = 0;
      int end = total - 1;

      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final parts = rangeHeader.substring(6).split('-');
        start = int.tryParse(parts[0]) ?? 0;
        if (parts.length > 1 && parts[1].isNotEmpty) {
          final parsedEnd = int.tryParse(parts[1]);
          if (parsedEnd != null) end = math.min(parsedEnd, total - 1);
        }
      }

      if (start > end || start >= total) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await request.response.close();
        return;
      }

      final contentLength = end - start + 1;
      request.response.statusCode = (rangeHeader != null) ? HttpStatus.partialContent : HttpStatus.ok;
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
      request.response.headers.set(HttpHeaders.contentLengthHeader, contentLength.toString());
      if (rangeHeader != null) {
        request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
      }

      // Stream từng chunk cho Player
      final firstChunk = start ~/ chunkSize;
      final lastChunk = end ~/ chunkSize;

      for (var c = firstChunk; c <= lastChunk; c++) {
        final chunkBytes = await _getOrFetchChunk(session, c);
        final chunkStartOffset = c * chunkSize;

        final sliceStart = math.max(0, start - chunkStartOffset);
        final sliceEnd = math.min(chunkBytes.length, end - chunkStartOffset + 1);

        if (sliceStart < sliceEnd && sliceStart < chunkBytes.length) {
          request.response.add(chunkBytes.sublist(sliceStart, sliceEnd));
        }
      }

      await request.response.close();
    } catch (e) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  /// Phục vụ nhanh khi file đã có sẵn trong VideoCacheManager
  Future<void> _serveLocalFile(HttpRequest request, File file) async {
    final total = file.lengthSync();
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    int start = 0;
    int end = total - 1;

    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final parts = rangeHeader.substring(6).split('-');
      start = int.tryParse(parts[0]) ?? 0;
      if (parts.length > 1 && parts[1].isNotEmpty) {
        final parsedEnd = int.tryParse(parts[1]);
        if (parsedEnd != null) end = math.min(parsedEnd, total - 1);
      }
    }

    final contentLength = end - start + 1;
    request.response.statusCode = (rangeHeader != null) ? HttpStatus.partialContent : HttpStatus.ok;
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
    request.response.headers.set(HttpHeaders.contentLengthHeader, contentLength.toString());
    if (rangeHeader != null) {
      request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
    }

    final stream = file.openRead(start, end + 1);
    await stream.pipe(request.response);
  }

  /// Dọn dẹp các session cũ để giải phóng RAM (Chỉ giữ lại activeVids)
  void maintainSessions(List<String> activeVids) {
    final activeSet = activeVids.toSet();
    final toRemove = <String>[];

    for (final entry in _sessions.entries) {
      if (!activeSet.contains(entry.key)) {
        toRemove.add(entry.key);
      }
    }

    for (final key in toRemove) {
      _sessions.remove(key);
    }
  }

  /// Giải phóng toàn bộ khi đóng màn hình Feed
  Future<void> dispose() async {
    _sessions.clear();
    _inFlightPrepares.clear();
    await _server?.close(force: true);
    _server = null;
    _port = 0;
  }
}
