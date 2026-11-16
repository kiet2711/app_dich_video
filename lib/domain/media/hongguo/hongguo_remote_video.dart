import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'hongguo_mp4_cenc.dart';
import 'hongguo_sixgod_signer.dart';

class _CachedAuxSlice {
  final int start;
  final Uint8List bytes;

  const _CachedAuxSlice({required this.start, required this.bytes});
  int get end => start + bytes.length;
}

/// Bộ đọc và giải mã stream Hongguo CENC theo dải byte (Range 256 KiB - 512 KiB).
///
/// Đảm bảo mức tiêu thụ RAM cực thấp (< 2 MB) khi phát proxy hoặc tải về file cục bộ,
/// tự động tìm box `moov` ở cả đầu file (FastStart) lẫn cuối file (`ftyp + mdat + moov`).
class HongguoRemoteVideo {
  final String url;
  final Uint8List? contentKey;
  final Map<String, String> requestHeaders;
  final Dio _dio;
  final bool _ownsDio;

  int? _contentLength;
  HongguoPreparedCenc? _prepared;
  List<_CachedAuxSlice> _auxSlices = const <_CachedAuxSlice>[];
  Future<void>? _prepareFuture;

  HongguoRemoteVideo({
    required this.url,
    required this.contentKey,
    Map<String, String> headers = const <String, String>{},
    Dio? dio,
  })  : requestHeaders = <String, String>{
          'User-Agent': HongguoSixgodSigner.userAgent,
          ...headers,
        },
        _ownsDio = dio == null,
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 12),
                receiveTimeout: const Duration(seconds: 25),
                followRedirects: true,
                maxRedirects: 5,
                validateStatus: (status) =>
                    status != null && status >= 200 && status < 400,
              ),
            );

  int? get contentLength => _contentLength;
  HongguoPreparedCenc? get prepared => _prepared;
  Mp4ContainerMetadata? get metadata => _prepared?.metadata;
  int get durationMs => _prepared?.metadata.durationMs ?? 0;

  void close() {
    if (_ownsDio) {
      _dio.close();
    }
  }

  /// Thăm dò tổng kích thước, tải box `moov` + bảng `saio`/`saiz` (chỉ ~50-200 KB).
  Future<HongguoPreparedCenc> prepare() async {
    if (_prepared != null) return _prepared!;
    _prepareFuture ??= _doPrepare();
    try {
      await _prepareFuture;
      return _prepared!;
    } catch (e) {
      _prepareFuture = null;
      rethrow;
    }
  }

  Future<void> _doPrepare() async {
    // 1. Đọc 64 KiB đầu để lấy totalLength & thường tóm gọn ftyp + moov header.
    const probeSize = 64 * 1024;
    final probe = await _fetchRangeWithTotal(0, probeSize - 1);
    var totalLen = probe.totalLength;
    if (totalLen <= 0) {
      totalLen = await _headContentLength() ?? probe.bytes.length;
    }
    if (totalLen <= 0) {
      throw const HttpException('Không xác định được kích thước video Hongguo');
    }
    _contentLength = totalLen;

    // 2. Duyệt các top-level box tìm `moov` (chỉ đọc header 16B mỗi box nếu vượt khỏi probe).
    Uint8List? moovBytes;
    var moovOffset = -1;
    var cursor = 0;
    for (var steps = 0; steps < 64 && cursor + 8 <= totalLen; steps++) {
      final headerBytes = await _readFromProbeOrRemote(
        probe.bytes,
        cursor,
        min(16, totalLen - cursor),
      );
      if (headerBytes.length < 8) break;
      final bd = ByteData.sublistView(headerBytes);
      final box = Mp4BoxScanner.readBoxHeader(
        headerBytes,
        bd,
        0,
        totalLen - cursor,
      );
      // Nếu size32 == 1 hoặc 0, readBoxHeader dùng containerEnd tương đối từ 0.
      if (box == null || box.size <= 0) break;
      final boxSize = box.size;
      if (box.type == 'moov') {
        if (boxSize > 24 * 1024 * 1024) {
          throw StateError('Box moov quá lớn ($boxSize bytes)');
        }
        moovOffset = cursor;
        moovBytes = await _readFromProbeOrRemote(probe.bytes, cursor, boxSize);
        break;
      }
      cursor += boxSize;
    }

    if (moovBytes == null || moovOffset < 0) {
      throw const FormatException('Không tìm thấy box moov trong MP4 stream');
    }

    final prepared = HongguoPreparedCenc.parseMoov(
      moovBytes,
      moovFileOffset: moovOffset,
    );

    // 3. Nếu là video CENC, chỉ tải duy nhất dải saio/saiz cần thiết để dựng map giải mã.
    if (contentKey != null &&
        contentKey!.length == 16 &&
        prepared.auxRanges.isNotEmpty) {
      final slices = <_CachedAuxSlice>[];
      for (final r in prepared.auxRanges) {
        final safeEnd = min(totalLen, r.end);
        if (r.start >= safeEnd) continue;
        final auxData = await _readFromProbeOrRemote(
          probe.bytes,
          r.start,
          safeEnd - r.start,
        );
        slices.add(_CachedAuxSlice(start: r.start, bytes: auxData));
      }
      _auxSlices = slices;
      prepared.finalizeWithAuxChunks((off, len) {
        for (final s in _auxSlices) {
          if (off >= s.start && off + len <= s.end) {
            return Uint8List.sublistView(
              s.bytes,
              off - s.start,
              off - s.start + len,
            );
          }
        }
        return null;
      });
    } else if (!prepared.isFinalized) {
      prepared.finalizeWithAuxChunks((_, _) => null);
    }

    _prepared = prepared;
  }

  Future<Uint8List> _readFromProbeOrRemote(
    Uint8List probeBytes,
    int fileOffset,
    int length,
  ) async {
    if (length <= 0) return Uint8List(0);
    if (fileOffset >= 0 && fileOffset + length <= probeBytes.length) {
      return Uint8List.sublistView(probeBytes, fileOffset, fileOffset + length);
    }
    final res = await _fetchRangeWithTotal(fileOffset, fileOffset + length - 1);
    return res.bytes;
  }

  /// Đọc và giải mã tại chỗ một khoảng `[start, endExclusive)` cho streaming proxy server.
  Future<Uint8List> readDecryptedRange(int start, int endExclusive) async {
    final prep = await prepare();
    final total = _contentLength ?? 0;
    final clampedStart = max(0, min(start, total));
    final clampedEnd = max(clampedStart, min(endExclusive, total));
    if (clampedStart >= clampedEnd) return Uint8List(0);

    final fetched = await _fetchRangeWithTotal(clampedStart, clampedEnd - 1);
    final buf = Uint8List.fromList(fetched.bytes);
    prep.decryptRange(clampedStart, buf, contentKey: contentKey);
    return buf;
  }

  /// Tải & giải mã nối tiếp từng khối (`512 KiB`) thẳng ra ổ đĩa, RAM luôn < 2 MB.
  ///
  /// Hỗ trợ cả server trả `206 Partial Content` (từng chunk Range với retry độc lập) lẫn server
  /// trả `200 OK` (stream trực tiếp xuống đĩa và giải mã từng lát `chunkSize`).
  Future<File> streamDecryptedToFile(
    File targetFile, {
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
    int chunkSize = 512 * 1024,
  }) async {
    final prep = await prepare();
    final total = _contentLength ?? 0;
    if (total <= 0) {
      throw const HttpException('Kích thước video bằng 0');
    }

    if (!await targetFile.parent.exists()) {
      await targetFile.parent.create(recursive: true);
    }
    final tempFile = File('${targetFile.path}.part');
    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    final raf = await tempFile.open(mode: FileMode.write);
    var offset = 0;
    try {
      while (offset < total) {
        if (cancelToken?.isCancelled ?? false) {
          throw DioException.requestCancelled(
            requestOptions: RequestOptions(path: url),
            reason: 'Cancelled',
          );
        }
        final endInclusive = min(total - 1, offset + chunkSize - 1);
        final res = await _fetchRangeOrFullStream(
          offset,
          endInclusive,
          cancelToken: cancelToken,
        );
        if (res.fullStream != null) {
          // CDN không hỗ trợ Range và trả HTTP 200 full body: stream theo từng lát 512 KiB.
          var streamOffset = 0;
          final carry = BytesBuilder(copy: false);
          await for (final packet in res.fullStream!) {
            if (cancelToken?.isCancelled ?? false) {
              throw DioException.requestCancelled(
                requestOptions: RequestOptions(path: url),
                reason: 'Cancelled',
              );
            }
            carry.add(packet);
            while (carry.length >= chunkSize) {
              final all = carry.takeBytes();
              final block = Uint8List.sublistView(all, 0, chunkSize);
              if (all.length > chunkSize) {
                carry.add(Uint8List.sublistView(all, chunkSize));
              }
              final outBlock = Uint8List.fromList(block);
              prep.decryptRange(streamOffset, outBlock, contentKey: contentKey);
              await raf.writeFrom(outBlock);
              streamOffset += outBlock.length;
              onProgress?.call((streamOffset / total).clamp(0.0, 1.0));
            }
          }
          if (carry.length > 0) {
            final rem = carry.takeBytes();
            prep.decryptRange(streamOffset, rem, contentKey: contentKey);
            await raf.writeFrom(rem);
            streamOffset += rem.length;
          }
          offset = streamOffset;
          break;
        }

        final chunkBytes = Uint8List.fromList(res.bytes!);
        if (chunkBytes.isEmpty) {
          throw HttpException('Server trả chunk rỗng tại offset=$offset/$total');
        }
        prep.decryptRange(offset, chunkBytes, contentKey: contentKey);
        await raf.writeFrom(chunkBytes);
        offset += chunkBytes.length;
        onProgress?.call((offset / total).clamp(0.0, 1.0));
      }
      await raf.flush();
    } catch (_) {
      await raf.close();
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      rethrow;
    }
    await raf.close();

    if (offset < total) {
      if (await tempFile.exists()) await tempFile.delete();
      throw HttpException('Tải video chưa hoàn chỉnh: $offset/$total bytes');
    }
    if (await targetFile.exists()) {
      await targetFile.delete();
    }
    return tempFile.rename(targetFile.path);
  }

  Future<({Uint8List bytes, int totalLength})> _fetchRangeWithTotal(
    int start,
    int endInclusive, {
    CancelToken? cancelToken,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final response = await _dio.get<List<int>>(
          url,
          cancelToken: cancelToken,
          options: Options(
            responseType: ResponseType.bytes,
            headers: <String, dynamic>{
              ...requestHeaders,
              'Range': 'bytes=$start-$endInclusive',
              'Accept-Encoding': 'identity',
            },
          ),
        );
        final raw = Uint8List.fromList(response.data ?? const <int>[]);
        final total = _parseTotalLength(response.headers, raw.length);
        // Nếu server trả 200 OK toàn bộ file khi chỉ xin range nhỏ: cắt đúng slice [start..end].
        if (response.statusCode == 200 &&
            (start > 0 || raw.length > (endInclusive - start + 1))) {
          final sliceEnd = min(raw.length, endInclusive + 1);
          final sliceStart = min(start, sliceEnd);
          return (
            bytes: Uint8List.fromList(
              Uint8List.sublistView(raw, sliceStart, sliceEnd),
            ),
            totalLength: raw.length,
          );
        }
        return (bytes: raw, totalLength: total);
      } catch (e) {
        if (cancelToken?.isCancelled ?? false) rethrow;
        lastError = e;
        if (attempt < 2) {
          await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
        }
      }
    }
    throw lastError ?? const HttpException('Lỗi tải range video');
  }

  Future<({Uint8List? bytes, Stream<Uint8List>? fullStream})>
      _fetchRangeOrFullStream(
    int start,
    int endInclusive, {
    CancelToken? cancelToken,
  }) async {
    if (start == 0) {
      final response = await _dio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: <String, dynamic>{
            ...requestHeaders,
            'Range': 'bytes=$start-$endInclusive',
            'Accept-Encoding': 'identity',
          },
        ),
      );
      if (response.statusCode == 200 && response.data != null) {
        return (bytes: null, fullStream: response.data!.stream);
      }
      if (response.data != null) {
        final chunks = await response.data!.stream.toList();
        return (
          bytes: Uint8List.fromList(chunks.expand((e) => e).toList()),
          fullStream: null,
        );
      }
    }
    final fetched = await _fetchRangeWithTotal(
      start,
      endInclusive,
      cancelToken: cancelToken,
    );
    return (bytes: fetched.bytes, fullStream: null);
  }

  Future<int?> _headContentLength() async {
    try {
      final resp = await _dio.head<void>(
        url,
        options: Options(headers: requestHeaders),
      );
      final len = int.tryParse(resp.headers.value('content-length') ?? '');
      return (len != null && len > 0) ? len : null;
    } catch (_) {
      return null;
    }
  }

  static int _parseTotalLength(Headers headers, int fallbackLength) {
    final cr = headers.value('content-range');
    if (cr != null) {
      final slash = cr.lastIndexOf('/');
      if (slash >= 0 && slash + 1 < cr.length) {
        final totalStr = cr.substring(slash + 1).trim();
        final parsed = int.tryParse(totalStr);
        if (parsed != null && parsed > 0) return parsed;
      }
    }
    final cl = int.tryParse(headers.value('content-length') ?? '');
    if (cl != null && cl > 0) return cl;
    return fallbackLength;
  }
}
