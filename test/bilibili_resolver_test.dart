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
}
