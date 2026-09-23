import 'package:capsub_flutter/domain/media/bilibili_resolver.dart';
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
  });
}
