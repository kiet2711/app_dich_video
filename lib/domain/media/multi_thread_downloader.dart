import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

class MultiThreadDownloader {
  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 25),
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
    final effectiveConcurrency = concurrency.clamp(8, 32);
    progressCallback?.call(0.02, 'Đang kết nối và kiểm tra kích thước...');

    if (!await outputFile.parent.exists()) {
      await outputFile.parent.create(recursive: true);
    }

    final totalBytes = await _probeFileSize(cleanUrl, headers);
    if (totalBytes <= 0) {
      return _downloadSingleStream(cleanUrl, outputFile, headers, progressCallback);
    }

    final totalMb = totalBytes / (1024.0 * 1024.0);
    const chunkSize = 3 * 1024 * 1024; // 3MB per chunk
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

        await raf.setPosition(chunk.start);
        await raf.writeFrom(buffer);

        downloadedBytes += buffer.length;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastNotifyTime > 250 || downloadedBytes >= totalBytes) {
          lastNotifyTime = now;
          final elapsedSec = (now - startTime) / 1000.0;
          final speedMBs = elapsedSec > 0.1
              ? (downloadedBytes / (1024.0 * 1024.0)) / elapsedSec
              : 0.0;
          final pct = (downloadedBytes / totalBytes).clamp(0.0, 1.0);
          final msg =
              'Đang tải đa luồng ($effectiveConcurrency luồng): ${(downloadedBytes / (1024 * 1024)).toStringAsFixed(1)} / ${totalMb.toStringAsFixed(1)} MB (${speedMBs.toStringAsFixed(1)} MB/s)';
          progressCallback?.call(pct, msg);
        }
      }
    }

    try {
      final futures = List.generate(effectiveConcurrency, (id) => worker(id));
      await Future.wait(futures);
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
    try {
      final reqHeaders = Map<String, dynamic>.from(headers);
      reqHeaders['Range'] = 'bytes=0-1023';

      final resp = await _dio.get<dynamic>(
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
        if (len != null && len > 1024) return len;
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
        if (attempt > 0 && rawUrl.contains('upos-')) {
          final host = cdnFallbackHosts[(workerId + attempt - 1) % cdnFallbackHosts.length];
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
    void Function(double progress, String message)? progressCallback,
  ) async {
    final resp = await _dio.get<ResponseBody>(
      url,
      options: Options(
        headers: headers,
        responseType: ResponseType.stream,
      ),
    );

    final totalBytes = int.tryParse(resp.headers.value('content-length') ?? '0') ?? 0;
    final totalMb = totalBytes > 0 ? totalBytes / (1024.0 * 1024.0) : 0.0;
    var downloaded = 0;
    final sink = outputFile.openWrite();

    await for (final chunk in resp.data!.stream) {
      sink.add(chunk);
      downloaded += chunk.length;
      if (totalBytes > 0) {
        final pct = (downloaded / totalBytes).clamp(0.0, 1.0);
        progressCallback?.call(
          pct,
          'Đang tải trực tiếp: ${(downloaded / (1024 * 1024)).toStringAsFixed(1)} / ${totalMb.toStringAsFixed(1)} MB',
        );
      }
    }

    await sink.flush();
    await sink.close();
    return downloaded;
  }
}

class _Chunk {
  final int index;
  final int start;
  final int end;

  const _Chunk({required this.index, required this.start, required this.end});
}
