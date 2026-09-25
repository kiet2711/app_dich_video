import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

class MultiThreadDownloader {
  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 35),
      receiveTimeout: const Duration(seconds: 60),
      followRedirects: true,
    ),
  );

  static const List<String> cdnFallbackHosts = [
    'upos-sz-mirrorcos.bilivideo.com',
    'upos-sz-mirrorali.bilivideo.com',
    'upos-sz-mirrorhw.bilivideo.com',
    'upos-sz-mirror08c.bilivideo.com',
  ];

  static Future<int> downloadFile({
    required String url,
    required File outputFile,
    Map<String, String> headers = const {},
    int concurrency = 16,
    void Function(double progress, String message)? progressCallback,
  }) async {
    final cleanUrl = url.trim();
    progressCallback?.call(0.02, 'Đang kết nối và kiểm tra kích thước...');

    if (!await outputFile.parent.exists()) {
      await outputFile.parent.create(recursive: true);
    }

    final totalBytes = await _probeFileSize(cleanUrl, headers);
    // Với file nhỏ <= 15MB (Hongguo tập phim, TikTok, short clip...):
    // Tải 1 luồng trực tiếp là tối ưu nhất (1-2s giống tool PC).
    if (totalBytes > 0 && totalBytes <= 15 * 1024 * 1024) {
      return _downloadSingleStream(cleanUrl, outputFile, headers, progressCallback, knownTotalBytes: totalBytes);
    }

    final totalMb = totalBytes / (1024.0 * 1024.0);
    // Với file > 15MB (audio dài vài tiếng, video Bilibili nặng):
    // Dùng 4 luồng song song luân chuyển qua 4 cụm CDN (Tencent, Alibaba, Huawei, Bilibili)
    final effectiveConcurrency = concurrency.clamp(2, 4);
    // Chunk size 3MB chuẩn theo tool PC để các luồng kéo liên tục theo hàng đợi động
    const chunkSize = 3 * 1024 * 1024;
    final chunks = <_Chunk>[];
    var curr = 0;
    var chunkIdx = 0;
    while (curr < totalBytes) {
      final end = min(curr + chunkSize - 1, totalBytes - 1);
      chunks.add(_Chunk(index: chunkIdx++, start: curr, end: end));
      curr = end + 1;
    }

    final raf = await outputFile.open(mode: FileMode.write);
    try {
      await raf.truncate(totalBytes);
    } catch (_) {}

    var downloadedBytes = 0;
    var chunkQueueIndex = 0;
    final startTime = DateTime.now().millisecondsSinceEpoch;
    var lastNotifyTime = 0;

    // Hàng đợi ghi file tuần tự để chống xung đột con trỏ tệp giữa các luồng
    var writeQueue = Future<void>.value();
    Future<void> writeBuffer(int start, Uint8List buffer) {
      writeQueue = writeQueue.then((_) async {
        await raf.setPosition(start);
        await raf.writeFrom(buffer);
      });
      return writeQueue;
    }

    Future<void> worker(int workerId) async {
      while (true) {
        if (chunkQueueIndex >= chunks.length) break;
        final idx = chunkQueueIndex++;
        if (idx >= chunks.length) break;
        final chunk = chunks[idx];

        final buffer = await _fetchChunkWithRetry(
          cleanUrl,
          chunk.start,
          chunk.end,
          headers,
          workerId,
        );

        await writeBuffer(chunk.start, buffer);

        downloadedBytes += buffer.length;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastNotifyTime > 150 || downloadedBytes >= totalBytes) {
          lastNotifyTime = now;
          final elapsedSec = (now - startTime) / 1000.0;
          final speedMBs = elapsedSec > 0.1
              ? (downloadedBytes / (1024.0 * 1024.0)) / elapsedSec
              : 0.0;
          final pct = (downloadedBytes / totalBytes).clamp(0.0, 1.0);
          final msg =
              'Đang tải tốc độ cao ($effectiveConcurrency cụm CDN): ${(downloadedBytes / (1024 * 1024)).toStringAsFixed(1)} / ${totalMb.toStringAsFixed(1)} MB (${speedMBs.toStringAsFixed(1)} MB/s)';
          progressCallback?.call(pct, msg);
        }
      }
    }

    try {
      final futures = List.generate(effectiveConcurrency, (id) => worker(id));
      await Future.wait(futures);
      await writeQueue;
      await raf.flush();
    } finally {
      await raf.close();
    }

    final totalTime = (DateTime.now().millisecondsSinceEpoch - startTime) / 1000.0;
    final avgSpeed = totalTime > 0.1 ? totalMb / totalTime : 0.0;
    progressCallback?.call(
      1.0,
      'Tải hoàn tất: ${totalMb.toStringAsFixed(1)} MB (${avgSpeed.toStringAsFixed(1)} MB/s)',
    );

    return totalBytes;
  }

  static Future<int> _probeFileSize(String url, Map<String, String> headers) async {
    // 1. Thử HEAD request trước (không tốn băng thông tải body)
    try {
      final headResp = await _dio.head<dynamic>(
        url,
        options: Options(
          headers: Map<String, dynamic>.from(headers),
          validateStatus: (status) => status != null && status < 400,
        ),
      );
      final cl = headResp.headers.value('content-length');
      if (cl != null) {
        final len = int.tryParse(cl);
        if (len != null && len > 512) return len;
      }
    } catch (_) {}

    // 2. Thử Range 0-0 nếu server hỗ trợ partial content
    try {
      final reqHeaders = Map<String, dynamic>.from(headers);
      reqHeaders['Range'] = 'bytes=0-0';

      final resp = await _dio.get<ResponseBody>(
        url,
        options: Options(
          headers: reqHeaders,
          responseType: ResponseType.stream,
          validateStatus: (status) => status != null && (status >= 200 && status < 300),
        ),
      );

      final cr = resp.headers.value('content-range');
      if (cr != null && cr.contains('/')) {
        final total = int.tryParse(cr.split('/').last);
        if (total != null && total > 0) return total;
      }
      final cl = resp.headers.value('content-length');
      if (cl != null) {
        final len = int.tryParse(cl);
        if (len != null && len > 512) return len;
      }
    } catch (_) {}

    return 0;
  }

  static Future<Uint8List> _fetchChunkWithRetry(
    String rawUrl,
    int start,
    int end,
    Map<String, String> headers,
    int workerId, {
    int maxRetries = 4,
  }) async {
    Object? lastEx;
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      try {
        var targetUrl = rawUrl;
        // Sharding qua 4 cụm máy chủ CDN (Tencent, Alibaba, Huawei, Bilibili) ngay từ lần đầu
        if (rawUrl.contains('upos-')) {
          final host = cdnFallbackHosts[(workerId + attempt) % cdnFallbackHosts.length];
          targetUrl = rawUrl.replaceFirst(RegExp(r'upos-[^/]+'), host);
        }

        final reqHeaders = Map<String, dynamic>.from(headers);
        reqHeaders['Range'] = 'bytes=$start-$end';

        final resp = await _dio.get<List<int>>(
          targetUrl,
          options: Options(
            headers: reqHeaders,
            responseType: ResponseType.bytes,
            validateStatus: (status) => status == 200 || status == 206,
          ),
        );

        if (resp.data != null && resp.data!.isNotEmpty) {
          return Uint8List.fromList(resp.data!);
        }
      } catch (e) {
        lastEx = e;
        await Future<void>.delayed(Duration(milliseconds: 150 * (attempt + 1)));
      }
    }
    throw lastEx ?? Exception('Không thể tải phân đoạn $start-$end');
  }

  static Future<int> _downloadSingleStream(
    String url,
    File outputFile,
    Map<String, String> headers,
    void Function(double progress, String message)? progressCallback, {
    int knownTotalBytes = 0,
  }) async {
    Object? lastEx;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (attempt > 0) {
          progressCallback?.call(
            0.05,
            'Đang thử lại kết nối tải video (lần ${attempt + 1}/3)...',
          );
          await Future<void>.delayed(Duration(seconds: attempt * 2));
        }

        final resp = await _dio.get<ResponseBody>(
          url,
          options: Options(
            headers: headers,
            responseType: ResponseType.stream,
          ),
        );

        final headerBytes = int.tryParse(resp.headers.value('content-length') ?? '0') ?? 0;
        final totalBytes = headerBytes > 0 ? headerBytes : knownTotalBytes;
        final totalMb = totalBytes > 0 ? totalBytes / (1024.0 * 1024.0) : 0.0;
        var downloaded = 0;
        final sink = outputFile.openWrite();
        final startTime = DateTime.now().millisecondsSinceEpoch;
        var lastNotifyTime = 0;

        await for (final chunk in resp.data!.stream) {
          sink.add(chunk);
          downloaded += chunk.length;
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastNotifyTime > 150 || (totalBytes > 0 && downloaded >= totalBytes)) {
            lastNotifyTime = now;
            final elapsedSec = (now - startTime) / 1000.0;
            final speedMBs = elapsedSec > 0.1
                ? (downloaded / (1024.0 * 1024.0)) / elapsedSec
                : 0.0;
            final pct = totalBytes > 0 ? (downloaded / totalBytes).clamp(0.0, 1.0) : 0.5;
            final totalMbStr = totalMb > 0 ? ' / ${totalMb.toStringAsFixed(1)} MB' : ' MB';
            progressCallback?.call(
              pct,
              'Đang tải siêu tốc: ${(downloaded / (1024 * 1024)).toStringAsFixed(1)}$totalMbStr (${speedMBs.toStringAsFixed(1)} MB/s)',
            );
          }
        }

        await sink.flush();
        await sink.close();

        final totalTime = (DateTime.now().millisecondsSinceEpoch - startTime) / 1000.0;
        final avgSpeed = totalTime > 0.1 ? (downloaded / (1024 * 1024)) / totalTime : 0.0;
        progressCallback?.call(
          1.0,
          'Tải hoàn tất: ${(downloaded / (1024 * 1024)).toStringAsFixed(1)} MB (${avgSpeed.toStringAsFixed(1)} MB/s)',
        );

        return downloaded;
      } catch (e) {
        lastEx = e;
        try {
          if (await outputFile.exists()) {
            await outputFile.delete();
          }
        } catch (_) {}
      }
    }
    throw lastEx ?? Exception('Không thể tải luồng video trực tuyến sau 3 lần thử');
  }
}

class _Chunk {
  final int index;
  final int start;
  final int end;

  const _Chunk({required this.index, required this.start, required this.end});
}
