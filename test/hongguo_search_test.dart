import 'dart:convert';
import 'dart:typed_data';

import 'package:capsub_flutter/domain/media/hongguo_resolver.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubHttpClientAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) handler;

  _StubHttpClientAdapter(this.handler);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return handler(options);
  }
}

void main() {
  group('HongguoResolver search API', () {
    test('parseSearchApiJson parses video_data, actor video_list, and pagination', () {
      final result = HongguoResolver.parseSearchApiJson({
        'searchList': [
          {
            'doc_type': 46,
            'name': '',
            'video_list': [
              {
                'series_id': '1001',
                'series_title': 'Actor Drama One',
                'series_cover': '//p3-novel.byteimg.com/cover1.jpg',
                'episode_cnt': 80,
                'series_intro': 'Intro 1',
                'vid_list': ['111', '222'],
                'category_list': [
                  {'category_id': '1', 'name': '都市'},
                ],
              },
            ],
          },
          {
            'doc_type': 23,
            'name': 'Fallback Title',
            'video_data': {
              'series_id': '1002',
              'series_title': 'Drama Two',
              'series_cover': 'http://p6-novel.byteimg.com/cover2.jpg',
              'episode_cnt': 95,
              'series_intro': 'Intro 2',
              'vid_list': ['333'],
              'category_list': [
                {'category_id': '2', 'name': '恋爱'},
                {'category_id': '3', 'name': '职场'},
              ],
            },
          },
          // Duplicate series_id should be ignored
          {
            'doc_type': 23,
            'video_data': {
              'series_id': '1001',
              'series_title': 'Duplicate Actor Drama One',
            },
          },
        ],
        'pageNum': 1,
        'totalPages': 12,
        'totalCount': 120,
        'hasMore': true,
      });

      expect(result.items.length, 2);
      expect(result.items[0].seriesId, '1001');
      expect(result.items[0].title, 'Actor Drama One');
      expect(result.items[0].cover, 'https://p3-novel.byteimg.com/cover1.jpg');
      expect(result.items[0].episodeCount, 80);
      expect(result.items[0].vidList, ['111', '222']);
      expect(result.items[0].tags, ['都市']);

      expect(result.items[1].seriesId, '1002');
      expect(result.items[1].title, 'Drama Two');
      expect(result.items[1].cover, 'https://p6-novel.byteimg.com/cover2.jpg');
      expect(result.items[1].tags, ['恋爱', '职场']);

      expect(result.currentPage, 1);
      expect(result.totalPages, 12);
      expect(result.totalItems, 120);
    });

    test('searchList queries /api/search/result with query and page', () async {
      final requestedUris = <Uri>[];
      final dio = Dio();
      dio.httpClientAdapter = _StubHttpClientAdapter((options) async {
        requestedUris.add(options.uri);
        return ResponseBody.fromString(
          jsonEncode({
            'searchList': [
              {
                'doc_type': 23,
                'video_data': {
                  'series_id': '7688352674999176254',
                  'series_title': '总裁是我前女友',
                  'series_cover': 'https://p6-novel.byteimg.com/cover.jpg',
                  'episode_cnt': 95,
                  'vid_list': ['7688396347107445822'],
                },
              },
            ],
            'pageNum': 2,
            'totalPages': 5,
            'totalCount': 45,
          }),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json; charset=utf-8'],
          },
        );
      });

      final resolver = HongguoResolver(dio: dio);
      final res = await resolver.searchList('总裁', page: 2);

      expect(requestedUris.length, 1);
      expect(requestedUris.first.path, '/api/search/result');
      expect(requestedUris.first.queryParameters['query'], '总裁');
      expect(requestedUris.first.queryParameters['page'], '2');
      expect(res.items.length, 1);
      expect(res.items.first.title, '总裁是我前女友');
      expect(res.currentPage, 2);
      expect(res.totalPages, 5);
    });

    test('search falls back to /api/search/suggestion when /api/search/result returns 403', () async {
      final requestedPaths = <String>[];
      final dio = Dio();
      dio.httpClientAdapter = _StubHttpClientAdapter((options) async {
        requestedPaths.add(options.uri.path);
        if (options.uri.path == '/api/search/result') {
          return ResponseBody.fromString(
            jsonEncode({'code': 'search_verification_required'}),
            403,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        }
        return ResponseBody.fromString(
          jsonEncode({
            'suggestionList': [
              {
                'name': '总裁是我前女友',
                'video_data': {
                  'series_id': '7688352674999176254',
                  'series_title': '总裁是我前女友',
                  'episode_cnt': 95,
                },
              },
            ],
          }),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      });

      final resolver = HongguoResolver(dio: dio);
      final items = await resolver.search('总裁');

      expect(requestedPaths, ['/api/search/result', '/api/search/suggestion']);
      expect(items.length, 1);
      expect(items.first.seriesId, '7688352674999176254');
    });

    test('metadata coverage exposes 24 real genres, 8 comic genres, 8 AI genres (+drama) and 10 rank boards', () {
      expect(HongguoResolver.realDramaGenres.length, 25); // '' + 24
      expect(HongguoResolver.comicDramaGenres.length, 9); // '' + 8
      expect(HongguoResolver.aiDramaGenres.length, 9); // '' + 8
      expect(
        HongguoResolver.aiDramaGenres.any((g) => g.slug == 'drama'),
        isTrue,
      );
      expect(HongguoResolver.rankBoards.length, 10);
      expect(
        HongguoResolver.rankBoards.map((r) => r.slug),
        containsAll([
          'rank/hot-drama',
          'rank/hot-real-drama',
          'rank/hot-comic-drama',
          'rank/hot-ai-drama',
          'rank/prestige-drama',
          'rank/subscribe-drama',
        ]),
      );
    });

    test('parseDramaListHtml parses camelCase rankList and recommendList with sourceCategory', () {
      final routerPayload = {
        'loaderData': {
          'routes/rank/page': {
            'rankList': [
              {
                'seriesId': '990011223344',
                'seriesName': 'AI觉醒纪元',
                'cover': '//p3-novel.byteimg.com/ai-rank.jpg',
                'episodeCount': 60,
                'description': 'AI科幻逆袭剧',
                'primaryMetricText': '9.8分 · 1200万热度',
                'rank': 1,
                'statusTags': ['已完结', 'AI剧'],
                'tags': ['科幻', 'AI剧'],
              },
            ],
            'recommendList': [
              {
                'series_id': '990011223355',
                'series_title': '校园女强日记',
                'episode_cnt': 75,
                'tags': ['青春', '逆袭'],
              },
            ],
            'pagination': {'totalPages': 4, 'total': 80, 'pageNum': 1},
          },
        },
      };
      final html =
          '<html><script>window._ROUTER_DATA = ${jsonEncode(routerPayload)};</script></html>';

      final res = HongguoResolver.parseDramaListHtml(
        html,
        1,
        inferredSourceCategory: 'category/ai-drama',
      );

      expect(res.totalPages, 4);
      expect(res.totalItems, 80);
      expect(res.items.length, 2);
      final byId = {for (final item in res.items) item.seriesId: item};
      final rankItem = byId['990011223344']!;
      expect(rankItem.title, 'AI觉醒纪元');
      expect(rankItem.rank, 1);
      expect(rankItem.metricText, '9.8分 · 1200万热度');
      expect(rankItem.statusTags, ['已完结', 'AI剧']);
      expect(rankItem.sourceCategory, 'category/ai-drama');
      final recItem = byId['990011223355']!;
      expect(recItem.title, '校园女强日记');
      expect(recItem.sourceCategory, 'category/ai-drama');
    });

    test('getRandomRecommendations uses valid category & genre slugs', () async {
      final requestedPaths = <String>[];
      final dio = Dio();
      dio.httpClientAdapter = _StubHttpClientAdapter((options) async {
        requestedPaths.add(options.uri.path);
        final payload = {
          'loaderData': {
            'routes/category/page': {
              'dramaList': [
                {
                  'series_id': '8811223344',
                  'series_title': '青春甜宠时光',
                  'episode_cnt': 50,
                  'tags': ['青春', '甜宠'],
                },
              ],
              'pagination': {'totalPages': 2, 'total': 20, 'pageNum': 1},
            },
          },
        };
        return ResponseBody.fromString(
          '<script>window._ROUTER_DATA = ${jsonEncode(payload)};</script>',
          200,
          headers: {
            Headers.contentTypeHeader: ['text/html; charset=utf-8'],
          },
        );
      });

      final resolver = HongguoResolver(dio: dio);
      final validRealSlugs = HongguoResolver.realDramaGenres
          .map((g) => g.slug)
          .where((s) => s.isNotEmpty)
          .toSet();
      final res = await resolver.getRandomRecommendations(
        preferredCategory: 'category/real-drama',
        genre: 'youth',
      );

      expect(res.items.length, 1);
      expect(requestedPaths.first, contains('/category/real-drama'));
      expect(requestedPaths.first, contains('/youth'));
      expect(validRealSlugs.contains('youth'), isTrue);
    });
  });
}

