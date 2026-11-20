import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ksub/domain/media/hongguo/hongguo_codec_capabilities.dart';
import 'package:ksub/domain/media/hongguo/hongguo_device_service.dart';
import 'package:ksub/domain/media/hongguo/hongguo_local_engine.dart';
import 'package:ksub/domain/media/hongguo/hongguo_playback_routes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    HongguoPlaybackRoutes.instance.reset();
    HongguoLocalEngine.setDioForTesting(null);
    HongguoDeviceService.instance.resetForTesting();
    await HongguoCodecCapabilities.instance.lessons.clearAll();
    HongguoCodecCapabilities.instance.setSupportForTesting(
      const HongguoCodecSupport(avcSupported: true, hevcSupported: true),
    );
  });

  tearDown(() {
    HongguoLocalEngine.setDioForTesting(null);
    HongguoCodecCapabilities.instance.setSupportForTesting(null);
  });

  group('HongguoPlaybackRoutes', () {
    test('puts healthy hosts before cooled hosts and tracks recovery', () {
      const mainUrl = 'https://cdn-a.example.com/v1.mp4';
      const backupUrl = 'https://cdn-b.example.com/v1.mp4';

      expect(
        HongguoPlaybackRoutes.instance.orderUrls(<String>[mainUrl, backupUrl]),
        <String>[mainUrl, backupUrl],
      );

      HongguoPlaybackRoutes.instance.markFailed(mainUrl);
      expect(
        HongguoPlaybackRoutes.instance.orderUrls(<String>[mainUrl, backupUrl]),
        <String>[backupUrl, mainUrl],
      );

      HongguoPlaybackRoutes.instance.markHealthy(mainUrl);
      expect(
        HongguoPlaybackRoutes.instance.orderUrls(<String>[mainUrl, backupUrl]),
        <String>[mainUrl, backupUrl],
      );
    });
  });

  group('HongguoStreamLadder & DecoderLessons', () {
    final ladder = HongguoStreamLadder(
      durationMs: 118000,
      renditions: const <HongguoRendition>[
        HongguoRendition(
          vid: 'v1',
          definition: '1080p',
          codec: 'bytevc2',
          mainUrl: 'https://cdn.example.com/1080_bvc2.mp4',
          height: 1920,
          width: 1080,
          bitrate: 2000000,
        ),
        HongguoRendition(
          vid: 'v1',
          definition: '1080p',
          codec: 'bytevc1',
          mainUrl: 'https://cdn.example.com/1080_hevc.mp4',
          height: 1920,
          width: 1080,
          bitrate: 1500000,
        ),
        HongguoRendition(
          vid: 'v1',
          definition: '1080p',
          codec: 'h264',
          mainUrl: 'https://cdn.example.com/1080_h264.mp4',
          height: 1920,
          width: 1080,
          bitrate: 1800000,
        ),
        HongguoRendition(
          vid: 'v1',
          definition: '720p',
          codec: 'h264',
          mainUrl: 'https://cdn.example.com/720_h264.mp4',
          height: 1280,
          width: 720,
          bitrate: 1100000,
        ),
        HongguoRendition(
          vid: 'v1',
          definition: '480p',
          codec: 'h264',
          mainUrl: 'https://cdn.example.com/480_h264.mp4',
          height: 854,
          width: 480,
          bitrate: 600000,
        ),
      ],
    );

    test('filters out bytevc2 and picks requested tier', () {
      expect(ladder.availableQualityTiers, <String>['1080', '720', '480']);

      final best720 = ladder.selectBest(preferredQuality: '720');
      expect(best720?.qualityTier, 720);
      expect(best720?.normalizedCodec, 'h264');

      // HEVC supported -> picks bytevc1 1080p, NOT bytevc2!
      final best1080 = ladder.selectBest(preferredQuality: '1080');
      expect(best1080?.normalizedCodec, 'bytevc1');
      expect(best1080?.qualityTier, 1080);

      // When HEVC is unsupported, prefers H.264 1080p.
      final bestNoHevc = ladder.selectBest(
        preferredQuality: '1080',
        hardwareSupport: const HongguoCodecSupport(
          avcSupported: true,
          hevcSupported: false,
        ),
      );
      expect(bestNoHevc?.normalizedCodec, 'h264');
      expect(bestNoHevc?.qualityTier, 1080);
    });

    test('selectDowngrade steps HEVC -> H.264 at same tier before dropping resolution', () async {
      final first = ladder.selectBest(preferredQuality: '1080')!;
      expect(first.normalizedCodec, 'bytevc1');

      final second = ladder.selectDowngrade(first)!;
      expect(second.normalizedCodec, 'h264');
      expect(second.qualityTier, 1080);

      final third = ladder.selectDowngrade(
        second,
        excludedKeys: <String>{first.uniqueKey},
      )!;
      expect(third.normalizedCodec, 'h264');
      expect(third.qualityTier, 720);

      // Persist lesson and verify next selectBest skips blocked (bytevc1, 1080).
      final lessons = HongguoCodecCapabilities.instance.lessons;
      await lessons.learnFailure(first.normalizedCodec, first.qualityTier);
      expect(lessons.isBlocked('bytevc1', 1080), isTrue);

      final afterLesson = ladder.selectBest(
        preferredQuality: '1080',
        lessons: lessons,
      );
      expect(afterLesson?.normalizedCodec, 'h264');
    });
  });

  group('HongguoLocalEngine v5 resolution & duration normalization', () {
    test('normalizes seconds vs milliseconds correctly', () async {
      expect(HongguoLocalEngine.normalizeDurationMs(95), 95000);
      expect(HongguoLocalEngine.normalizeDurationMs('132.5'), 132500);
      expect(HongguoLocalEngine.normalizeDurationMs(125000), 125000);
      expect(HongguoLocalEngine.normalizeDurationMs(0), 0);

      final probed = await HongguoLocalEngine.resolveEffectiveDurationMs(
        localFilePath: '${Directory.systemTemp.path}/nonexistent_file.mp4',
        apiDurationRaw: 88,
        probeAudioFn: (_) async => 0,
      );
      expect(probed, 88000);
    });

    test('falls back from v5 failure to v3 and builds complete StreamLadder', () async {
      // Mock registered device so no live device_register call is made.
      final devDio = Dio();
      devDio.httpClientAdapter = _FakeAdapter((options) async {
        return ResponseBody.fromString(
          jsonEncode(<String, dynamic>{
            'device_id_str': '7491111111111111111',
            'install_id_str': '7492222222222222222',
          }),
          200,
        );
      });
      HongguoDeviceService.instance.setDioForTesting(devDio);

      var sawV5 = false;
      var sawV3 = false;
      final apiDio = Dio();
      apiDio.httpClientAdapter = _FakeAdapter((options) async {
        if (options.uri.path.contains('/player/v1')) {
          sawV5 = true;
          return ResponseBody.fromString('{"code":100103}', 200);
        }
        sawV3 = true;
        final model = <String, dynamic>{
          'video_duration': 104,
          'video_list': <String, dynamic>{
            'video_1': <String, dynamic>{
              'definition': '720p',
              'codec_type': 'h264',
              'main_url': base64Encode(utf8.encode('https://cdn.example.com/720.mp4')),
              'backup_url_1': base64Encode(utf8.encode('https://cdn-b.example.com/720.mp4')),
              'spade_a': '',
              'vwidth': 720,
              'vheight': 1280,
              'bitrate': 900000,
            },
            'video_2': <String, dynamic>{
              'definition': '1080p',
              'codec_type': 'bytevc1',
              'main_url': base64Encode(utf8.encode('https://cdn.example.com/1080.mp4')),
              'spade_a': '',
              'vwidth': 1080,
              'vheight': 1920,
              'bitrate': 1600000,
            },
          },
        };
        return ResponseBody.fromString(
          jsonEncode(<String, dynamic>{
            'code': 0,
            'data': <String, dynamic>{
              '1004': <String, dynamic>{
                '987654321': <String, dynamic>{'video_model': model},
              },
            },
          }),
          200,
        );
      });
      HongguoLocalEngine.setDioForTesting(apiDio);

      final info = await HongguoLocalEngine.resolveVideoInfo(
        '987654321',
        preferredQuality: '720',
      );
      expect(sawV5, isTrue);
      expect(sawV3, isTrue);
      expect(info.durationMs, 104000);
      expect(info.realMainUrl, 'https://cdn.example.com/720.mp4');
      expect(info.ladder?.availableQualityTiers, <String>['1080', '720']);
      expect(HongguoLocalEngine.getCachedDurationMs('987654321'), 104000);
    });

    test('parses v5 list renditions with nested video_meta and selects 1080p over 360p', () async {
      final devDio = Dio();
      devDio.httpClientAdapter = _FakeAdapter((options) async {
        return ResponseBody.fromString(
          jsonEncode(<String, dynamic>{
            'device_id_str': '7491111111111111111',
            'install_id_str': '7492222222222222222',
          }),
          200,
        );
      });
      HongguoDeviceService.instance.setDioForTesting(devDio);

      final apiDio = Dio();
      apiDio.httpClientAdapter = _FakeAdapter((options) async {
        final model = <String, dynamic>{
          'video_duration': 178.8,
          'video_list': <Map<String, dynamic>>[
            <String, dynamic>{
              'main_url': 'https://cdn.example.com/360.mp4',
              'backup_url': 'https://cdn-b.example.com/360.mp4',
              'video_meta': <String, dynamic>{
                'definition': '360p',
                'vtype': 'mp4',
                'vwidth': 360,
                'vheight': 640,
                'bitrate': 185604,
                'codec_type': 'bytevc1',
                'size': 4246436,
                'fps': 25,
              },
            },
            <String, dynamic>{
              'main_url': 'https://cdn.example.com/480.mp4',
              'video_meta': <String, dynamic>{
                'definition': '480p',
                'vtype': 'mp4',
                'vwidth': 480,
                'vheight': 854,
                'bitrate': 254713,
                'codec_type': 'bytevc1',
              },
            },
            <String, dynamic>{
              'main_url': 'https://cdn.example.com/720.mp4',
              'video_meta': <String, dynamic>{
                'definition': '720p',
                'vtype': 'mp4',
                'vwidth': 720,
                'vheight': 1280,
                'bitrate': 322842,
                'codec_type': 'bytevc1',
              },
            },
            <String, dynamic>{
              'main_url': 'https://cdn.example.com/1080.mp4',
              'video_meta': <String, dynamic>{
                'definition': '1080p',
                'vtype': 'mp4',
                'vwidth': 1080,
                'vheight': 1920,
                'bitrate': 576221,
                'codec_type': 'bytevc1',
              },
            },
          ],
        };
        return ResponseBody.fromString(
          jsonEncode(<String, dynamic>{
            'code': 0,
            'data': <String, dynamic>{
              '1004': <String, dynamic>{
                '7699685725448457241': <String, dynamic>{'video_model': model},
              },
            },
          }),
          200,
        );
      });
      HongguoLocalEngine.setDioForTesting(apiDio);

      final infoAuto = await HongguoLocalEngine.resolveVideoInfo(
        '7699685725448457241',
        preferredQuality: 'auto',
      );
      expect(
        infoAuto.ladder?.availableQualityTiers,
        <String>['1080', '720', '480', '360'],
      );
      expect(infoAuto.selectedRendition?.qualityTier, 1080);
      expect(infoAuto.selectedRendition?.normalizedCodec, 'bytevc1');
      expect(infoAuto.selectedRendition?.width, 1080);
      expect(infoAuto.selectedRendition?.height, 1920);
      expect(infoAuto.realMainUrl, 'https://cdn.example.com/1080.mp4');
    });
  });
}

class _FakeAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) fn;

  _FakeAdapter(this.fn);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      fn(options);
}

