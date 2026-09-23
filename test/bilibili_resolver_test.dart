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
}
