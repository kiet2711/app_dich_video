import 'dart:convert';

import 'package:ksub/domain/media/douyin_resolver.dart';
import 'package:ksub/domain/media/network_header_helper.dart';
import 'package:ksub/domain/media/video_cache_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DouyinResolver URL parsing', () {
    test('extracts clean URL from noisy Android/iOS Douyin share copy', () {
      const shareWithSpaces =
          '4.89 10/19 c@N.DH Kjc:/ 让你在几秒钟之内记住我 https://v.douyin.com/L4NpDJ6/ 复制此链接，打开Dou音搜索，直接观看视频！';
      expect(
        DouyinResolver.extractDouyinUrl(shareWithSpaces),
        'https://v.douyin.com/L4NpDJ6/',
      );
      expect(
        NetworkHeaderHelper.extractCleanUrl(shareWithSpaces),
        'https://v.douyin.com/L4NpDJ6/',
      );

      const shareWithoutSpaceBeforeChinese =
          '看视频https://v.douyin.com/L4NpDJ6/复制此链接，打开Dou音搜索';
      expect(
        DouyinResolver.extractDouyinUrl(shareWithoutSpaceBeforeChinese),
        'https://v.douyin.com/L4NpDJ6/',
      );
      expect(
        NetworkHeaderHelper.extractCleanUrl(shareWithoutSpaceBeforeChinese),
        'https://v.douyin.com/L4NpDJ6/',
      );

      const bareShortLink = 'v.douyin.com/iY8aBcD/ 复制此链接';
      expect(
        DouyinResolver.extractDouyinUrl(bareShortLink),
        'https://v.douyin.com/iY8aBcD/',
      );
      expect(
        NetworkHeaderHelper.extractCleanUrl(bareShortLink),
        'https://v.douyin.com/iY8aBcD/',
      );
    });

    test('distinguishes Douyin page URLs from direct CDN MP4 URLs', () {
      expect(
        DouyinResolver.isDouyinPageUrl('https://v.douyin.com/L4NpDJ6/'),
        isTrue,
      );
      expect(
        DouyinResolver.isDouyinPageUrl(
          'https://www.douyin.com/video/7707260940349181247',
        ),
        isTrue,
      );
      expect(
        DouyinResolver.isDouyinPageUrl(
          'https://www.douyin.com/jingxuan?modal_id=7707182483482026481',
        ),
        isTrue,
      );
      expect(
        DouyinResolver.isDouyinPageUrl(
          'https://www.iesdouyin.com/share/video/6914948781100338440/?region=CN',
        ),
        isTrue,
      );

      const cdnMp4 =
          'https://v3-dy-o.zjcdn.com/abc/video/tos/cn/tos-cn-ve-15/item.mp4';
      expect(DouyinResolver.isDouyinPageUrl(cdnMp4), isFalse);
      expect(DouyinResolver.isDouyinUrl(cdnMp4), isTrue);

      expect(
        DouyinResolver.isDouyinPageUrl('https://www.bilibili.com/video/BV1xx'),
        isFalse,
      );
      expect(
        DouyinResolver.isDouyinUrl('https://www.bilibili.com/video/BV1xx'),
        isFalse,
      );
    });

    test('extracts aweme_id from video, note, share, and modal_id URLs', () {
      expect(
        DouyinResolver.extractAwemeId(
          'https://www.douyin.com/video/7707260940349181247',
        ),
        '7707260940349181247',
      );
      expect(
        DouyinResolver.extractAwemeId(
          'https://www.douyin.com/discover?modal_id=7707182483482026481',
        ),
        '7707182483482026481',
      );
      expect(
        DouyinResolver.extractAwemeId(
          'https://www.iesdouyin.com/share/video/6914948781100338440/?region=CN',
        ),
        '6914948781100338440',
      );
      expect(
        DouyinResolver.extractAwemeId('https://www.douyin.com/note/7707147544519067251'),
        '7707147544519067251',
      );
      expect(
        DouyinResolver.extractAwemeId('https://v.douyin.com/L4NpDJ6/'),
        isNull,
      );
    });

    test('generates stable dy_<awemeId>.mp4 cache key and Douyin headers', () {
      expect(
        VideoCacheManager.getCacheKey(
          url: 'https://www.douyin.com/video/7707260940349181247',
        ),
        'dy_7707260940349181247.mp4',
      );
      expect(
        VideoCacheManager.getCacheKey(
          url: 'https://www.iesdouyin.com/share/video/7707260940349181247/',
        ),
        'dy_7707260940349181247.mp4',
      );
      final headers = NetworkHeaderHelper.getHeadersForUrl(
        'https://v3-dy-o.zjcdn.com/test/video.mp4',
      );
      expect(headers['Referer'], 'https://www.douyin.com/');
    });
  });

  group('DouyinResolver response parsing', () {
    test('ignores generic feed responses without matching aweme_id', () {
      final parsed = DouyinResolver.parseFeedResponseJson(
        {
          'aweme_list': [
            {
              'aweme_id': '9999999999999999999',
              'desc': 'unrelated feed video',
              'video': {
                'play_addr': {
                  'url_list': ['https://v3-dy-o.zjcdn.com/other.mp4'],
                },
              },
            },
          ],
        },
        expectedAwemeId: '7707260940349181247',
      );
      expect(parsed, isNull);
    });

    test('extracts matched item, prioritizes H.264, strips watermark playwm', () {
      final details = DouyinResolver.parseFeedResponseJson(
        {
          'aweme_list': [
            {
              'aweme_id': '7707260940349181247',
              'desc': 'Test Douyin Clip #subtitle',
              'duration': 15200,
              'author': {'nickname': 'CreatorA'},
              'video': {
                'width': 1080,
                'height': 1920,
                'is_h265': 0,
                'cover': {
                  'url_list': ['https://p9-sign.douyinpic.com/cover.jpeg'],
                },
                'play_addr_h264': {
                  'url_list': [
                    'https://api-hl.amemv.com/aweme/v1/playwm/?video_id=h264',
                  ],
                },
                'play_addr': {
                  'url_list': [
                    'https://v3-dy-o.zjcdn.com/primary_720.mp4',
                  ],
                },
                'bit_rate': [
                  {
                    'gear_name': 'normal_540',
                    'bit_rate': 500000,
                    'is_h265': 0,
                    'play_addr': {
                      'width': 576,
                      'height': 1024,
                      'data_size': 1024 * 1024,
                      'url_list': ['https://v3-dy-o.zjcdn.com/540_h264.mp4'],
                    },
                  },
                  {
                    'gear_name': 'normal_1080_hevc',
                    'bit_rate': 1800000,
                    'is_h265': 1,
                    'play_addr': {
                      'width': 1080,
                      'height': 1920,
                      'data_size': 3 * 1024 * 1024,
                      'url_list': ['https://v3-dy-o.zjcdn.com/1080_hevc.mp4'],
                    },
                  },
                  {
                    'gear_name': 'normal_720',
                    'bit_rate': 950000,
                    'is_h265': 0,
                    'play_addr': {
                      'width': 720,
                      'height': 1280,
                      'data_size': 2 * 1024 * 1024,
                      'url_list': ['https://v3-dy-o.zjcdn.com/720_h264.mp4'],
                    },
                  },
                ],
              },
            },
          ],
        },
        expectedAwemeId: '7707260940349181247',
      );

      expect(details, isNotNull);
      expect(details!.title, 'Test Douyin Clip #subtitle');
      expect(details.author, 'CreatorA');
      expect(details.durationMs, 15200);
      expect(details.coverUrl, 'https://p9-sign.douyinpic.com/cover.jpeg');
      expect(details.canonicalUrl, 'https://www.douyin.com/video/7707260940349181247');
      expect(
        details.playUrls.first,
        'https://api-hl.amemv.com/aweme/v1/play/?video_id=h264',
      );
      expect(details.playUrls, contains('https://v3-dy-o.zjcdn.com/primary_720.mp4'));
      expect(details.qualityOptions.length, 3);
      // H.264 720p ranked ahead of H.264 540p and HEVC 1080p
      expect(details.qualityOptions.first.label, contains('720p'));
      expect(details.qualityOptions.last.isH265, isTrue);
      expect(
        details.urlsForQuality(details.qualityOptions[1].id).first,
        'https://v3-dy-o.zjcdn.com/540_h264.mp4',
      );
    });

    test('parses _ROUTER_DATA HTML fallback', () {
      const html = '''
<html><head><script>
window._ROUTER_DATA = {"loaderData":{"video_(id)/page":{"videoInfoRes":{"item_list":[{"aweme_id":"6914948781100338440","desc":"SSR Title","author":{"nickname":"SSRUser"},"video":{"duration":7500,"width":720,"height":1280,"play_addr":{"url_list":["https://www.iesdouyin.com/aweme/v1/playwm/?video_id=ssr1"]},"cover":{"url_list":["https://p9.douyinpic.com/c.jpg"]}}}]}}}};
</script></head></html>
''';
      final details = DouyinResolver.parseShareRouterDataHtml(
        html,
        expectedAwemeId: '6914948781100338440',
      );
      expect(details, isNotNull);
      expect(details!.title, 'SSR Title');
      expect(details.playUrls.first, 'https://www.iesdouyin.com/aweme/v1/play/?video_id=ssr1');
    });

    test('throws descriptive StateError for photo-only album post', () {
      expect(
        () => DouyinResolver.parseAwemeItem(
          {
            'aweme_id': '7707000000000000001',
            'aweme_type': 68,
            'desc': 'Photo slideshow',
            'images': [
              {
                'url_list': ['https://p3.douyinpic.com/img1.jpeg'],
              },
            ],
          },
          expectedAwemeId: '7707000000000000001',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('DouyinResolver mocked network resolution', () {
    test('resolves v.douyin.com redirect and falls back across feed mirrors', () async {
      final dio = Dio(BaseOptions(validateStatus: (_) => true));
      final visitedHosts = <String>[];

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final uri = options.uri;
            visitedHosts.add(uri.host);
            if (uri.host == 'v.douyin.com') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 302,
                  headers: Headers.fromMap({
                    'location': [
                      'https://www.iesdouyin.com/share/video/6914948781100338440/?region=CN',
                    ],
                  }),
                  data: '',
                ),
              );
              return;
            }
            if (uri.host == 'api5-normal-c-hl.amemv.com') {
              // Simulate transient failure on first mirror host
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 502,
                  data: '',
                ),
              );
              return;
            }
            if (uri.host == 'api3-normal-c-hl.amemv.com') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: jsonEncode({
                    'aweme_list': [
                      {
                        'aweme_id': '6914948781100338440',
                        'desc': 'Live Redirected Clip',
                        'duration': 7569,
                        'author': {'nickname': 'MirrorAuthor'},
                        'video': {
                          'width': 720,
                          'height': 1280,
                          'play_addr': {
                            'url_list': [
                              'https://v3-dy-o.zjcdn.com/final.mp4',
                            ],
                          },
                        },
                      },
                    ],
                  }),
                ),
              );
              return;
            }
            handler.resolve(
              Response(requestOptions: options, statusCode: 404, data: ''),
            );
          },
        ),
      );

      final resolver = DouyinResolver(dio: dio);
      final details = await resolver.resolveVideo(
        '8.12 https://v.douyin.com/L4NpDJ6/ 复制打开抖音',
      );

      expect(details.awemeId, '6914948781100338440');
      expect(details.title, 'Live Redirected Clip');
      expect(details.author, 'MirrorAuthor');
      expect(details.durationMs, 7569);
      expect(details.playUrls, ['https://v3-dy-o.zjcdn.com/final.mp4']);
      expect(visitedHosts, [
        'v.douyin.com',
        'api5-normal-c-hl.amemv.com',
        'api3-normal-c-hl.amemv.com',
      ]);
    });
  });
}

