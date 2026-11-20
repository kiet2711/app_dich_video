import 'dart:convert';

import 'package:ksub/data/repository/settings_repository.dart';
import 'package:ksub/domain/media/bilibili_resolver.dart';
import 'package:ksub/player/app_player_controller.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubBilibiliAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> playurlQueries = [];
  Map<String, dynamic> Function(Map<String, dynamic> query)? playurlResponder;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri.toString();
    if (uri.contains('/x/web-interface/nav')) {
      return ResponseBody.fromString(
        jsonEncode({
          'code': 0,
          'data': {
            'wbi_img': {
              'img_url': 'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
              'sub_url': 'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
            },
          },
        }),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    if (uri.contains('/x/player/wbi/playurl')) {
      playurlQueries.add(Map<String, dynamic>.from(options.queryParameters));
      final payload = playurlResponder?.call(options.queryParameters) ??
          const <String, dynamic>{'code': 0, 'data': <String, dynamic>{}};
      return ResponseBody.fromString(
        jsonEncode(payload),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return ResponseBody.fromString('{}', 404);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppPlayerController EDL builders', () {
    test('buildBilibiliEdlUri combines video and audio with exact UTF-8 byte lengths', () {
      const v = 'https://upos-hz-mirrorakam.akamaized.net/upgcxcode/12/34/v.m4s?a=1&b=2;x=3';
      const a = 'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/12/34/a.m4s?c=4,5';

      final edl = AppPlayerController.buildBilibiliEdlUri(
        videoUrl: v,
        audioUrl: a,
      );

      expect(
        edl,
        'edl://!no_chapters;%${utf8.encode(v).length}%$v;!new_stream;!no_chapters;%${utf8.encode(a).length}%$a',
      );
      expect(
        AppPlayerController.buildBilibiliEdlUri(videoUrl: v, audioUrl: ''),
        v,
      );
    });

    test('buildMultiPartEdlUri joins multi-part durl segments and leaves single URL plain', () {
      expect(
        AppPlayerController.buildMultiPartEdlUri([
          (url: 'https://cdn.example/part1.mp4', durationSec: 120.5),
        ]),
        'https://cdn.example/part1.mp4',
      );

      final multi = AppPlayerController.buildMultiPartEdlUri([
        (url: 'https://cdn.example/p1.flv?t=1', durationSec: 100.0),
        (url: 'https://cdn.example/p2.flv?t=2', durationSec: 85.25),
      ]);
      expect(
        multi,
        'edl://!no_chapters;%30%https://cdn.example/p1.flv?t=1,length=100.000;%30%https://cdn.example/p2.flv?t=2,length=85.250;',
      );
    });
  });

  group('BilibiliResolver CDN ranking, codec selection & quality normalization', () {
    test('normalizeQualityCode maps both pixel labels and QN codes cleanly', () {
      expect(BilibiliResolver.normalizeQualityCode('1080'), '80');
      expect(BilibiliResolver.normalizeQualityCode('1080p'), '80');
      expect(BilibiliResolver.normalizeQualityCode('720'), '64');
      expect(BilibiliResolver.normalizeQualityCode('480'), '32');
      expect(BilibiliResolver.normalizeQualityCode('360'), '16');
      expect(BilibiliResolver.normalizeQualityCode('80'), '80');
      expect(BilibiliResolver.normalizeQualityCode('invalid'), '64');
    });

    test('rankCdnUrls avoids MCDN and rewrites only non-Akamai UPOS hosts safely', () {
      const mcdn = 'https://sz-123.mcdn.bilivideo.cn:4480/v1/resource/abc.m4s?os=mcdn';
      const uposCos = 'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1/2/v.m4s?e=1';
      const akamai = 'https://upos-hz-mirrorakam.akamaized.net/upgcxcode/1/2/v.m4s?hdnts=sig';

      final autoRanked = BilibiliResolver.rankCdnUrls(
        [mcdn, akamai, uposCos],
        cdn: BilibiliCdnService.auto,
      );
      expect(autoRanked, [uposCos, akamai, mcdn]);

      final akamaiRanked = BilibiliResolver.rankCdnUrls(
        [mcdn, uposCos, akamai],
        cdn: BilibiliCdnService.akamai,
      );
      expect(akamaiRanked.first, akamai);

      final aliRanked = BilibiliResolver.rankCdnUrls(
        [uposCos, akamai],
        cdn: BilibiliCdnService.ali,
      );
      expect(
        aliRanked.first,
        'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/1/2/v.m4s?e=1',
      );
      // Akamai URL with hdnts signature must NOT have its host rewritten
      expect(aliRanked, contains(akamai));
      expect(aliRanked, contains(uposCos));

      final mcdnOnly = BilibiliResolver.rankCdnUrls([mcdn]);
      expect(mcdnOnly.first, startsWith('https://proxy-tf-all-ws.bilivideo.com/?url='));
      expect(mcdnOnly.last, mcdn);
    });

    test('selectBestVideoTrack prefers AVC over HEVC/AV1 and selectBestAudioTrack prefers AAC over Dolby/FLAC', () {
      final videos = [
        {'id': 80, 'codecs': 'av01.0.08M', 'bandwidth': 1200000},
        {'id': 80, 'codecs': 'hvc1.1.6.L150.90', 'bandwidth': 1400000},
        {'id': 80, 'codecs': 'avc1.640033', 'bandwidth': 2100000},
        {'id': 64, 'codecs': 'avc1.640028', 'bandwidth': 1000000},
      ];

      final best80 = BilibiliResolver.selectBestVideoTrack(videos, 80);
      expect(best80?['codecs'], startsWith('avc1'));

      final best720Fallback = BilibiliResolver.selectBestVideoTrack(videos, 64);
      expect(best720Fallback?['id'], 64);
      expect(best720Fallback?['codecs'], startsWith('avc1'));

      final audios = [
        {'id': 30251, 'codecs': 'fLaC', 'bandwidth': 900000},
        {'id': 30250, 'codecs': 'ec-3', 'bandwidth': 600000},
        {'id': 30280, 'codecs': 'mp4a.40.2', 'bandwidth': 192000},
        {'id': 30216, 'codecs': 'mp4a.40.2', 'bandwidth': 64000},
      ];
      final bestAudio = BilibiliResolver.selectBestAudioTrack(audios);
      expect(bestAudio?['id'], 30280);
    });
  });

  group('BilibiliResolver.resolvePlaybackPlan unified flow', () {
    const details = BilibiliVideoDetails(
      bvid: 'BV1wQYk65EYw',
      aid: 12345,
      cid: 41882815815,
      title: 'Test Bilibili Video',
      durationSeconds: 180,
      pages: [
        BilibiliPageInfo(page: 1, cid: 41882815815, part: 'P1', durationSeconds: 180),
      ],
    );

    test('requests try_look=1 when unauthenticated, ranks non-MCDN DASH pairs, and swaps out desktop UA', () async {
      final adapter = _StubBilibiliAdapter()
        ..playurlResponder = (q) => {
              'code': 0,
              'data': {
                'quality': 80,
                'timelength': 180000,
                'dash': {
                  'video': [
                    {
                      'id': 80,
                      'codecs': 'av01.0.08M',
                      'bandwidth': 1000000,
                      'baseUrl': 'https://slow.mcdn.bilivideo.cn/v1/resource/av1.m4s?os=mcdn',
                    },
                    {
                      'id': 80,
                      'codecs': 'avc1.640033',
                      'bandwidth': 2200000,
                      'baseUrl': 'https://bad.mcdn.bilivideo.cn/v1/resource/v.m4s?os=mcdn',
                      'backupUrl': [
                        'https://upos-hz-mirrorakam.akamaized.net/upgcxcode/v.m4s?hdnts=ok',
                        'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/v.m4s?e=1',
                      ],
                    },
                  ],
                  'audio': [
                    {
                      'id': 30250,
                      'codecs': 'ec-3',
                      'bandwidth': 500000,
                      'baseUrl': 'https://upos-hz-mirrorakam.akamaized.net/dolby.m4s',
                    },
                    {
                      'id': 30280,
                      'codecs': 'mp4a.40.2',
                      'bandwidth': 192000,
                      'baseUrl': 'https://upos-hz-mirrorakam.akamaized.net/audio.m4s',
                      'backupUrl': [
                        'https://upos-sz-mirrorali.bilivideo.com/audio.m4s',
                      ],
                    },
                  ],
                },
              },
            };

      final dio = Dio()..httpClientAdapter = adapter;
      final resolver = BilibiliResolver(dio: dio);

      final plan = await resolver.resolvePlaybackPlan(
        details,
        quality: '1080',
        cdn: BilibiliCdnService.auto,
      );

      expect(adapter.playurlQueries.single['qn'], '80');
      expect(adapter.playurlQueries.single['fnval'], '4048');
      expect(adapter.playurlQueries.single['try_look'], '1');
      expect(plan.hasDash, isTrue);
      expect(plan.dash!.videoCodec, startsWith('avc1'));
      expect(
        plan.dash!.videoUrl,
        'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/v.m4s?e=1',
      );
      expect(
        plan.dash!.audioUrl,
        'https://upos-sz-mirrorali.bilivideo.com/audio.m4s',
      );
      expect(
        plan.dash!.videoUrls,
        [
          'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/v.m4s?e=1',
          'https://upos-hz-mirrorakam.akamaized.net/upgcxcode/v.m4s?hdnts=ok',
          'https://bad.mcdn.bilivideo.cn/v1/resource/v.m4s?os=mcdn',
        ],
      );
      expect(plan.dash!.buildCandidatePairs().length, 3);
      expect(plan.headers['Referer'], 'https://www.bilibili.com/');
      expect(plan.headers['User-Agent'], contains('Windows NT 10.0'));

      // Authenticated call must omit try_look
      await resolver.resolvePlaybackPlan(
        details,
        cookie: 'SESSDATA=abc123',
        quality: '80',
      );
      expect(adapter.playurlQueries.last.containsKey('try_look'), isFalse);
    });

    test('falls back cleanly to multi-segment durl when server omits dash', () async {
      final adapter = _StubBilibiliAdapter()
        ..playurlResponder = (_) => {
              'code': 0,
              'data': {
                'quality': 64,
                'durl': [
                  {
                    'length': 90000,
                    'url': 'https://upos-sz-mirrorali.bilivideo.com/p1.mp4',
                  },
                  {
                    'length': 90000,
                    'url': 'https://upos-sz-mirrorali.bilivideo.com/p2.mp4',
                  },
                ],
              },
            };

      final dio = Dio()..httpClientAdapter = adapter;
      final resolver = BilibiliResolver(dio: dio);
      final plan = await resolver.resolvePlaybackPlan(details, quality: '64');

      expect(plan.hasDash, isFalse);
      expect(plan.muxedSegments, hasLength(2));
      expect(plan.muxedSegments[0].durationSec, 90.0);
      expect(plan.muxedSegments[1].urls.single, 'https://upos-sz-mirrorali.bilivideo.com/p2.mp4');
    });
  });

  group('SettingsRepository Bilibili playback preferences', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (_) async => '',
          );
      SharedPreferences.setMockInitialValues({});
    });

    test('defaults bilibiliCdnService to auto and bilibiliHardwareDecode to true', () async {
      final settings = await SettingsRepository.getInstance();
      expect(settings.bilibiliCdnService, 'auto');
      expect(settings.bilibiliHardwareDecode, isTrue);

      settings.bilibiliCdnService = 'akamai';
      settings.bilibiliHardwareDecode = false;

      expect(settings.bilibiliCdnService, 'akamai');
      expect(settings.bilibiliHardwareDecode, isFalse);
    });
  });
}
