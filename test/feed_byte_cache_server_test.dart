import 'dart:io';
import 'dart:typed_data';

import 'package:capsub_flutter/domain/media/hongguo/feed_byte_cache_server.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer upstreamServer;
  late Directory tempDir;
  late Uint8List payload;
  var upstreamRangeHits = 0;

  setUp(() async {
    upstreamRangeHits = 0;
    // 2.2 MB deterministic pseudo-random bytes (covers 5 chunks of 512KB).
    payload = Uint8List(2200 * 1024);
    for (var i = 0; i < payload.length; i++) {
      payload[i] = (i * 31 + 17) & 0xFF;
    }

    tempDir = await Directory.systemTemp.createTemp('feed_byte_cache_test_');
    FeedByteCacheServer.instance.testCacheDirectoryOverride = tempDir;
    FeedByteCacheServer.instance.allowLoopbackUpstreamForTesting = true;

    upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstreamServer.listen((HttpRequest req) async {
      final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        upstreamRangeHits++;
        final parts = rangeHeader.substring(6).split('-');
        final start = int.parse(parts[0]);
        final end = parts[1].isNotEmpty
            ? int.parse(parts[1]).clamp(start, payload.length - 1)
            : payload.length - 1;
        final slice = payload.sublist(start, end + 1);
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        req.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${payload.length}',
        );
        req.response.headers.set(
          HttpHeaders.contentLengthHeader,
          slice.length.toString(),
        );
        req.response.add(slice);
        await req.response.close();
      } else {
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.set(
          HttpHeaders.contentLengthHeader,
          payload.length.toString(),
        );
        req.response.add(payload);
        await req.response.close();
      }
    });
  });

  tearDown(() async {
    await FeedByteCacheServer.instance.stopForTesting();
    FeedByteCacheServer.instance.testCacheDirectoryOverride = null;
    FeedByteCacheServer.instance.allowLoopbackUpstreamForTesting = false;
    await upstreamServer.close(force: true);
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'preloads 1.5MB cleanly, serves cached ranges with 0 extra upstream hits, and streams tail identically',
    () async {
      final upstreamUrl =
          'http://127.0.0.1:${upstreamServer.port}/video/ep1_1080p.mp4?sign=abc';
      final server = FeedByteCacheServer.instance;
      await server.ensureStarted();

      // 1. Preload first 1.5MB (3 chunks x 512KB)
      await server.preloadFirstBytes(
        url: upstreamUrl,
        cacheKeyHint: 'series1_1_vid1',
      );
      expect(upstreamRangeHits, 3);

      // 2. Same rendition with rotated query signature reuses exact cached chunks!
      final rotatedUrl =
          'http://127.0.0.1:${upstreamServer.port}/video/ep1_1080p.mp4?sign=xyz_new';
      final localUrl = server.registerStream(
        url: rotatedUrl,
        cacheKeyHint: 'series1_1_vid1',
      );

      final client = HttpClient();
      try {
        // Request a middle range inside preloaded 1.5MB -> 0 extra upstream requests!
        final req1 = await client.getUrl(Uri.parse(localUrl));
        req1.headers.set(HttpHeaders.rangeHeader, 'bytes=400000-1200000');
        final res1 = await req1.close();
        expect(res1.statusCode, HttpStatus.partialContent);
        final bytes1 = await res1.fold<List<int>>([], (a, b) => a..addAll(b));
        expect(bytes1, equals(payload.sublist(400000, 1200001)));
        expect(upstreamRangeHits, 3);

        // Request full stream 0..EOF -> fetches only remaining 2 tail chunks (hits 3 -> 5)
        final req2 = await client.getUrl(Uri.parse(localUrl));
        final res2 = await req2.close();
        expect(res2.statusCode, HttpStatus.ok);
        final bytes2 = await res2.fold<List<int>>([], (a, b) => a..addAll(b));
        expect(bytes2.length, payload.length);
        expect(bytes2, equals(payload));
        expect(upstreamRangeHits, 5);

        // Wait briefly for async disk flush, then clear RAM cache -> verify Disk cache hit!
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await server.clearRamCache();
        final req3 = await client.getUrl(Uri.parse(localUrl));
        req3.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1048575');
        final res3 = await req3.close();
        expect(res3.statusCode, HttpStatus.partialContent);
        final bytes3 = await res3.fold<List<int>>([], (a, b) => a..addAll(b));
        expect(bytes3, equals(payload.sublist(0, 1048576)));
        expect(upstreamRangeHits, 5);
      } finally {
        client.close(force: true);
      }
    },
  );

  test(
    'distinct renditions for same series/episode do not collide and cancelled preload stops early',
    () async {
      final id1080 = FeedByteCacheServer.buildStreamId(
        url: 'https://cdn.example.com/v/1080p.mp4?token=1',
        cacheKeyHint: 's1_1_v1',
      );
      final id720 = FeedByteCacheServer.buildStreamId(
        url: 'https://cdn.example.com/v/720p.mp4?token=1',
        cacheKeyHint: 's1_1_v1',
      );
      expect(id1080, isNot(equals(id720)));

      final cancelToken = CancelToken()..cancel('user scrolled');
      await FeedByteCacheServer.instance.preloadFirstBytes(
        url: 'http://127.0.0.1:${upstreamServer.port}/video/cancel.mp4',
        cancelToken: cancelToken,
      );
      expect(upstreamRangeHits, 0);
    },
  );
}
