import 'package:ksub/domain/media/bilibili_resolver.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extracts primary and backup Bilibili playback URLs', () {
    final urls = BilibiliResolver.extractMuxedVideoUrls({
      'durl': [
        {
          'url': 'https://primary.example/video.mp4',
          'backup_url': [
            'https://backup-1.example/video.mp4',
            'https://primary.example/video.mp4',
          ],
          'backupUrl': ['https://backup-2.example/video.mp4'],
        },
      ],
    });

    expect(urls, [
      'https://primary.example/video.mp4',
      'https://backup-1.example/video.mp4',
      'https://backup-2.example/video.mp4',
    ]);
  });

  test('extracts UPOS muxed URLs preserving official order without fake mirror hosts', () {
    final urls = BilibiliResolver.extractMuxedVideoUrls({
      'durl': [
        {
          'url': 'https://cn-gdfs-cm-01-08.bilivideo.com/upos/media/video.mp4?deadline=1',
          'backup_url': [
            'https://upos-sz-mirror01.bilivideo.com/upos/media/video.mp4?deadline=1',
          ],
        },
      ],
    });

    expect(urls, [
      'https://cn-gdfs-cm-01-08.bilivideo.com/upos/media/video.mp4?deadline=1',
      'https://upos-sz-mirror01.bilivideo.com/upos/media/video.mp4?deadline=1',
    ]);
  });

  test('ignores missing and invalid playback URLs', () {
    expect(BilibiliResolver.extractMuxedVideoUrls(const {}), isEmpty);
    expect(
      BilibiliResolver.extractMuxedVideoUrls({
        'durl': [
          {
            'url': '',
            'backup_url': ['file:///tmp/video.mp4'],
          },
        ],
      }),
      isEmpty,
    );
  });

  test('reports when Bilibili hides subtitles until login', () {
    expect(
      () => BilibiliResolver.parseSubtitles({
        'need_login_subtitle': true,
        'subtitle': {'subtitles': <dynamic>[]},
      }),
      throwsA(isA<BilibiliSubtitleLoginRequiredException>()),
    );
  });

  test('parses subtitle metadata and protocol-relative URLs', () {
    final subtitles = BilibiliResolver.parseSubtitles({
      'subtitle': {
        'subtitles': [
          {
            'lan': 'ai-zh',
            'lan_doc': '中文（自动生成）',
            'ai_type': 1,
            'subtitle_url': '//aisubtitle.hdslb.com/subtitle.json',
          },
        ],
      },
    });

    expect(subtitles, hasLength(1));
    expect(subtitles.single.isAi, isTrue);
    expect(subtitles.single.url, 'https://aisubtitle.hdslb.com/subtitle.json');
  });

  test('does not throw when throwOnLoginRequired is false', () {
    final subtitles = BilibiliResolver.parseSubtitles({
      'need_login_subtitle': true,
      'subtitle': {'subtitles': <dynamic>[]},
    }, throwOnLoginRequired: false);

    expect(subtitles, isEmpty);
  });

  test('parses dm/view style subtitles with type 1 as AI', () {
    final subtitles = BilibiliResolver.parseSubtitles({
      'subtitle': {
        'subtitles': [
          {
            'lan': 'zh-CN',
            'lan_doc': '中文（简体）',
            'type': 1,
            'ai_type': 0,
            'subtitle_url': 'http://aisubtitle.hdslb.com/subtitle.json',
          },
        ],
      },
    });

    expect(subtitles, hasLength(1));
    expect(subtitles.single.isAi, isTrue);
    expect(subtitles.single.url, 'http://aisubtitle.hdslb.com/subtitle.json');
  });

  test('resolveUrl parses page indices correctly', () async {
    final resolver = BilibiliResolver();

    final t1 = await resolver.resolveUrl('https://www.bilibili.com/video/BV1wQYk65EYw');
    expect(t1.pageIndex, 1);

    final t2 = await resolver.resolveUrl('https://www.bilibili.com/video/BV1wQYk65EYw?p=2');
    expect(t2.pageIndex, 2);

    final t3 = await resolver.resolveUrl('https://www.bilibili.com/video/BV1wQYk65EYw/?share_source=copy_web&vd_source=8d2a59b4568abb295a3b9f775b17ee0a&p=2');
    expect(t3.pageIndex, 2);

    final t4 = await resolver.resolveUrl('https://www.bilibili.com/video/BV1wQYk65EYw/index_2.html');
    expect(t4.pageIndex, 2);

    final t5 = await resolver.resolveUrl('https://www.bilibili.com/video/BV1wQYk65EYw?p=2#reply123');
    expect(t5.pageIndex, 2);
  });

  test('BV1wQYk65EYw multi-part page 1 and page 2 details', () async {
    try {
      final resolver = BilibiliResolver();
      const rawUrl = 'https://www.bilibili.com/video/BV1wQYk65EYw/?share_source=copy_web&vd_source=8d2a59b4568abb295a3b9f775b17ee0a';

      final t1 = await resolver.resolveUrl(rawUrl);
      final d1 = await resolver.getVideoDetails(t1);
      expect(d1.selectedPageIndex, 1);
      expect(d1.cid, 41882815815);
      expect(d1.pages.length, greaterThanOrEqualTo(2));

      final uri = Uri.parse(rawUrl);
      final params = Map<String, String>.from(uri.queryParameters);
      params['p'] = '2';
      final p2Url = uri.replace(queryParameters: params).toString();

      final t2 = await resolver.resolveUrl(p2Url);
      final d2 = await resolver.getVideoDetails(t2);
      expect(d2.selectedPageIndex, 2);
      expect(d2.cid, 41882880663);
      expect(d2.title, contains('P2'));
    } on DioException catch (e) {
      // Bilibili WAF chặn IP datacenter CI (GitHub Actions/Azure) bằng HTTP 412 Precondition Failed
      if (e.response?.statusCode == 412 ||
          e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout) {
        return;
      }
      rethrow;
    }
  });

  test('getDashStream extracts valid video and audio stream URLs', () async {
    try {
      final resolver = BilibiliResolver();
      final target = await resolver.resolveUrl('https://www.bilibili.com/video/BV1wQYk65EYw');
      final details = await resolver.getVideoDetails(target);
      final dash = await resolver.getDashStream(details);

      expect(dash.videoUrl, isNotEmpty);
      expect(dash.videoUrl, startsWith('http'));
      expect(dash.audioUrl, isNotEmpty);
      expect(dash.audioUrl, startsWith('http'));
      expect(dash.headers, containsPair('Referer', 'https://www.bilibili.com/'));
    } on DioException catch (e) {
      // Bilibili WAF chặn IP datacenter CI (GitHub Actions/Azure) bằng HTTP 412 Precondition Failed
      if (e.response?.statusCode == 412 ||
          e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout) {
        return;
      }
      rethrow;
    }
  });

  test('getWatchHistoryPage returns empty page when cookie is empty', () async {
    final resolver = BilibiliResolver();
    final page = await resolver.getWatchHistoryPage(cookie: '   ');
    expect(page.items, isEmpty);
    expect(page.hasMore, isFalse);
  });

  test('getWatchHistoryPage parses archive & pgc history with cursor and resume progress', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          expect(options.uri.path, '/x/web-interface/history/cursor');
          expect(options.queryParameters['type'], 'all');
          expect(options.queryParameters['ps'], '2');
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'code': 0,
                'data': <String, dynamic>{
                  'cursor': <String, dynamic>{
                    'max': 170000111,
                    'view_at': 170000222,
                  },
                  'list': [
                    <String, dynamic>{
                      'title': '<em>First</em> Anime',
                      'cover': '//i0.hdslb.com/bfs/archive/a.jpg',
                      'duration': 600,
                      'progress': 125,
                      'view_at': 170000900,
                      'author_name': 'UP_One',
                      'author_face': '//i0.hdslb.com/bfs/face/up.jpg',
                      'tag_name': 'Anime',
                      'history': <String, dynamic>{
                        'business': 'archive',
                        'bvid': 'BV1TEST0001',
                        'oid': 1001,
                      },
                    },
                    <String, dynamic>{
                      'title': 'Bangumi Series',
                      'covers': ['https://i0.hdslb.com/bfs/bangumi/b.jpg'],
                      'show_title': '第3话 决战',
                      'duration': 1440,
                      'progress': -1,
                      'view_at': 170000800,
                      'badge': '番剧',
                      'history': <String, dynamic>{
                        'business': 'pgc',
                        'epid': 555666,
                        'oid': 9988,
                      },
                    },
                  ],
                },
              },
            ),
          );
        },
      ),
    );

    final resolver = BilibiliResolver(dio: dio);
    final page = await resolver.getWatchHistoryPage(
      pageSize: 2,
      cookie: 'SESSDATA=fake_cookie',
    );

    expect(page.hasMore, isTrue);
    expect(page.nextMax, 170000111);
    expect(page.nextViewAt, 170000222);
    expect(page.items, hasLength(2));

    final first = page.items[0];
    expect(first.business, 'archive');
    expect(first.item.title, 'First Anime');
    expect(first.item.bvid, 'BV1TEST0001');
    expect(first.item.cover, 'https://i0.hdslb.com/bfs/archive/a.jpg');
    expect(first.progressSeconds, 125);
    expect(first.resumePositionMs, 125000);
    expect(first.isCompleted, isFalse);
    expect(first.progressFraction, closeTo(125 / 600, 0.001));

    final second = page.items[1];
    expect(second.business, 'pgc');
    expect(second.item.epId, 555666);
    expect(second.item.seasonId, 9988);
    expect(second.showTitle, '第3话 决战');
    expect(second.isCompleted, isTrue);
    expect(second.resumePositionMs, 0);
    expect(second.progressFraction, 1.0);
  });
}

