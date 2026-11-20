import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ksub/data/model/watch_later_item.dart';
import 'package:ksub/data/repository/watch_later_repository.dart';
import 'package:ksub/domain/media/hongguo/hongguo_cloud_account_service.dart';
import 'package:ksub/domain/media/hongguo/hongguo_discovery_service.dart';
import 'package:ksub/domain/media/hongguo/hongguo_similar_engine.dart';
import 'package:ksub/domain/media/hongguo_resolver.dart';

class _FakeDiscoveryService extends HongguoDiscoveryService {
  _FakeDiscoveryService() : super.forSubclass();

  HongguoRelatedBundle relatedResult = const HongguoRelatedBundle();
  final List<HongguoDiscoverySelection> recordedSelections = [];
  Map<String, List<HongguoDramaItem>> discoveryItemsByGenre = const {};

  @override
  Future<HongguoRelatedBundle> fetchRelatedAndSimilar(
    String seriesId, {
    String? sourceCategory = '',
    List<String> categoryIds = const <String>[],
    List<String> tags = const <String>[],
  }) async {
    return relatedResult;
  }

  @override
  Future<HongguoDiscoveryPage> fetchDiscovery(
    HongguoDiscoverySelection selection, {
    HongguoDiscoveryCursor? cursor,
    Set<String>? seenIds,
    bool forceRefresh = false,
    bool useDefaultFeedSort = false,
  }) async {
    recordedSelections.add(selection);
    final items = discoveryItemsByGenre[selection.genreKind.id] ?? const [];
    return HongguoDiscoveryPage(
      items: items,
      selectorGroups:
          HongguoDiscoveryService.defaultSelectorGroups(selection.genreKind),
      hasMore: false,
    );
  }
}

void main() {
  group('HongguoResolver ecosystem inference & item map parsing', () {
    test('inferSourceCategoryFromIds distinguishes real, AI, and comic IDs', () {
      expect(
        HongguoResolver.inferSourceCategoryFromIds(['5023', '5315']),
        'category/real-drama',
      );
      expect(
        HongguoResolver.inferSourceCategoryFromIds(['5472', '4']),
        'category/ai-drama',
      );
      expect(
        HongguoResolver.inferSourceCategoryFromIds(['5888', '5416']),
        'category/comic-drama',
      );
      expect(
        HongguoResolver.inferSourceCategoryFromIds(
          [],
          tags: ['2D漫', '校园'],
        ),
        'category/comic-drama',
      );
      expect(
        HongguoResolver.inferSourceCategoryFromIds(
          [],
          tags: ['AI短剧', '爱情'],
        ),
        'category/ai-drama',
      );
    });

    test('parseDramaItemMap parses category_schema, categoryIds, read_cnt_text & first_vid', () {
      final seen = <String>{};
      final item = HongguoResolver.parseDramaItemMap(
        {
          'series_id': '7612345678901234567',
          'series_name': '夏语情深',
          'series_cover': 'https://example.com/cover.jpg',
          'episode_cnt': 48,
          'read_cnt_text': '4239万热度',
          'first_vid': '7612345678900001',
          'category_schema': jsonEncode([
            {'category_id': 5472, 'name': '青春爱情'},
            {'category_id': 4, 'name': '校园'},
          ]),
        },
        seen,
      );

      expect(item, isNotNull);
      expect(item!.seriesId, '7612345678901234567');
      expect(item.title, '夏语情深');
      expect(item.episodeCount, 48);
      expect(item.categoryIds, containsAll(['5472', '4']));
      expect(item.tags, containsAll(['青春爱情', '校园']));
      expect(item.sourceCategory, 'category/ai-drama');
      expect(item.metricText, '4239万热度');
      expect(item.vidList, contains('7612345678900001'));
    });
  });

  group('HongguoDiscoverySelection multi-axis state & serialization', () {
    test('withGenreKind clears incompatible category_dim axes while keeping sort & gender', () {
      const initial = HongguoDiscoverySelection(
        genreKind: HongguoGenreKind.realPlay,
        filters: {
          'sort': 'newest',
          'gender': '0',
          'online_time': 'time_1',
          'category_dim_epoch': 'cate_5315',
          'category_dim_theme': 'cate_5023',
        },
        tagHint: '校园',
      );

      final switched = initial.withGenreKind(HongguoGenreKind.aiSeries);
      expect(switched.genreKind, HongguoGenreKind.aiSeries);
      expect(switched.valueOf('sort'), 'newest');
      expect(switched.valueOf('gender'), '0');
      expect(switched.valueOf('online_time'), 'time_1');
      expect(switched.valueOf('category_dim_epoch'), isEmpty);
      expect(switched.valueOf('category_dim_theme'), isEmpty);
      expect(switched.tagHint, isEmpty);
    });

    test('toRequestBody switches comic art_style axis & pagination flags cleanly', () {
      const comicSel = HongguoDiscoverySelection(
        genreKind: HongguoGenreKind.comicSeries,
        filters: {
          'category_dim_art_style': 'cate_5416',
          'category_dim_epoch': 'cate_4',
          'gender': '0',
        },
      );

      final initialBody = comicSel.toRequestBody();
      final selectItems = initialBody['select_items'] as Map<String, dynamic>;
      expect(selectItems['genre'], ['comic_series']);
      expect(selectItems['category_dim_art_style'], ['cate_5416']);
      expect(selectItems['category_dim_epoch'], ['cate_4']);
      expect(selectItems['gender'], ['0']);
      expect(selectItems['sort'], ['hot_score']);
      expect(initialBody['need_selector_panel'], true);
      expect(initialBody['req_type'], 'default');
      expect(initialBody['req_scene'], 'comic_series');

      const cursor = HongguoDiscoveryCursor(
        offset: 24,
        sessionId: 'sess-xyz',
        page: 2,
      );
      final nextBody = comicSel.toRequestBody(
        cursor: cursor,
        filterIds: {'101', '102'},
      );
      expect(nextBody['offset'], 24);
      expect(nextBody['session_id'], 'sess-xyz');
      expect(nextBody['need_selector_panel'], false);
      expect(nextBody['req_type'], 'only_content');
      expect(nextBody['client_req_type'], 2);
      expect(nextBody['filter_ids'], '101,102');
    });

    test('toJsonString & fromJsonString round-trip and sanitize invalid filters', () {
      const sel = HongguoDiscoverySelection(
        genreKind: HongguoGenreKind.aiSeries,
        filters: {
          'category_dim_epoch': 'cate_4',
          'gender': '0',
          'sort': 'hot_score',
        },
        tagHint: '校园',
      );

      final decoded = HongguoDiscoverySelection.fromJsonString(sel.toJsonString());
      expect(decoded.genreKind, HongguoGenreKind.aiSeries);
      expect(decoded.valueOf('category_dim_epoch'), 'cate_4');
      expect(decoded.valueOf('gender'), '0');
      expect(decoded.tagHint, '校园');

      final sanitized = HongguoDiscoverySelection.fromJsonString(
        jsonEncode({
          'genre': 'comic_series',
          'filters': {
            'category_dim_art_style': 'cate_5416',
            'unknown_axis': 'bad',
            'gender': 'bad value with spaces!',
          },
        }),
      );
      expect(sanitized.genreKind, HongguoGenreKind.comicSeries);
      expect(sanitized.valueOf('category_dim_art_style'), 'cate_5416');
      expect(sanitized.valueOf('unknown_axis'), isEmpty);
      expect(sanitized.valueOf('gender'), isEmpty);

      final corrupt = HongguoDiscoverySelection.fromJsonString(
        '{not json',
        fallbackKind: HongguoGenreKind.aiSeries,
      );
      expect(corrupt.genreKind, HongguoGenreKind.aiSeries);
      expect(corrupt.effectiveSort, 'hot_score');
    });
  });

  group('HongguoDiscoveryService tag resolution & response parsers', () {
    final service = HongguoDiscoveryService();

    test('resolveSelectionForTag keeps AI & Comic tags locked in their ecosystem', () {
      final aiSchool = service.resolveSelectionForTag(
        '校园',
        categoryIds: const ['5472'],
        allDramaTags: const ['青春爱情', '校园'],
      );
      expect(aiSchool.genreKind, HongguoGenreKind.aiSeries);
      expect(aiSchool.valueOf('category_dim_epoch'), 'cate_4');

      final comicRomance = service.resolveSelectionForTag(
        '爱情',
        preferredSourceCategory: 'category/comic-drama',
      );
      expect(comicRomance.genreKind, HongguoGenreKind.comicSeries);
      expect(comicRomance.valueOf('gender'), '0');

      final comic2D = service.resolveSelectionForTag(
        '2D漫',
        preferredSourceCategory: 'category/comic-drama',
      );
      expect(comic2D.genreKind, HongguoGenreKind.comicSeries);
      expect(comic2D.valueOf('category_dim_art_style'), 'cate_5416');

      final realSchool = service.resolveSelectionForTag(
        '校园',
        preferredSourceCategory: 'category/real-drama',
      );
      expect(realSchool.genreKind, HongguoGenreKind.realPlay);
      expect(realSchool.valueOf('category_dim_epoch'), 'cate_5315');

      final realVillage = service.resolveSelectionForTag(
        '乡村',
        preferredSourceCategory: 'category/real-drama',
        defaultSort: '',
      );
      expect(realVillage.genreKind, HongguoGenreKind.realPlay);
      expect(realVillage.valueOf('category_dim_epoch'), 'cate_5314');
      expect(realVillage.valueOf('sort'), isEmpty);

      expect(translateHongguoTag('古言'), 'Ngôn tình cổ đại');
      expect(translateHongguoTag('现言'), 'Ngôn tình hiện đại');
      expect(translateHongguoTag('一见钟情'), 'Nhất kiến chung tình');
    });

    test('parseDiscoveryResponse extracts dramas, dynamic selectors & next cursor', () {
      final raw = jsonEncode({
        'code': 0,
        'data': {
          'has_more': true,
          'next_offset': 24,
          'session_id': 'disc-session-1',
          'video_data': [
            {
              'series_id': '9001',
              'series_name': '林深雨未眠',
              'series_cover': 'https://img.example/1.jpg',
              'episode_cnt': 60,
              'tags': ['爱情', '校园'],
              'read_cnt_text': '4270万',
            },
          ],
          'selector_rows': [
            {
              'type': 'category_dim_epoch',
              'items': [
                {'selector_item_id': 'cate_4', 'show_name': '校园'},
              ],
            },
            {
              'type': 'gender',
              'items': [
                {'selector_item_id': '0', 'show_name': '女频'},
              ],
            },
          ],
        },
      });

      final page = service.parseDiscoveryResponse(
        raw,
        selection: const HongguoDiscoverySelection(
          genreKind: HongguoGenreKind.aiSeries,
        ),
      );

      expect(page.items, hasLength(1));
      expect(page.items.first.title, '林深雨未眠');
      expect(page.items.first.sourceCategory, 'category/ai-drama');
      expect(page.hasMore, true);
      expect(page.nextCursor?.sessionId, 'disc-session-1');
      expect(page.nextCursor?.offset, 24);
      expect(page.selectorGroups.map((g) => g.type), containsAll(['category_dim_epoch', 'gender']));
    });

    test('parseBookmallTabResponse & parseBookmallCellResponse build continuation cursor', () {
      final tabRaw = jsonEncode({
        'code': 0,
        'data': {
          'tab_item': [
            {
              'tab_type': 16,
              'session_id': 'bm-sess-1',
              'bottom_unlimited': true,
              'client_template': 7,
              'bookstore_id': 'plan-888',
              'version_tag': 'v9',
              'cell_data': [
                {
                  'cell_id_str': 'cell-777',
                  'video_data': [
                    {
                      'video_detail': {
                        'series_id': '111',
                        'series_name': 'Phim đề xuất 1',
                        'episode_cnt': 30,
                      },
                    },
                  ],
                },
              ],
            },
          ],
        },
      });

      final tabPage = service.parseBookmallTabResponse(
        tabRaw,
        const HongguoOfficialFeedCursor(),
      );
      expect(tabPage.items, hasLength(1));
      expect(tabPage.items.first.seriesId, '111');
      expect(tabPage.nextCursor.hasCellContinuation, true);
      expect(tabPage.nextCursor.cellId, 'cell-777');
      expect(tabPage.nextCursor.planId, 'plan-888');
      expect(tabPage.nextCursor.versionTag, 'v9');
      expect(tabPage.nextCursor.offset, 0);

      final cellRaw = jsonEncode({
        'code': 0,
        'data': {
          'next_offset': 18,
          'session_id': 'bm-sess-2',
          'cell_view': {
            'cell_data': [
              {
                'video_data': [
                  {
                    'series_id': '222',
                    'series_name': 'Phim đề xuất 2',
                    'episode_cnt': 42,
                  },
                ],
              },
            ],
          },
        },
      });

      final nextPage = service.parseBookmallCellResponse(
        cellRaw,
        tabPage.nextCursor,
      );
      expect(nextPage.items, hasLength(1));
      expect(nextPage.items.first.seriesId, '222');
      expect(nextPage.nextCursor.offset, 18);
      expect(nextPage.nextCursor.sessionId, 'bm-sess-2');
    });

    test('parseRelatedPlanResponse parses seasons (547) & similar recommendations (506)', () {
      final raw = jsonEncode({
        'code': 0,
        'data': [
          {
            'show_type': 547,
            'cell_name': '相关作品',
            'video_data': [
              {
                'series_id': 'current-id',
                'series_name': 'Hiện tại',
                'content_type': 1004,
                'episode_cnt': 50,
                'season_index': 1,
              },
              {
                'series_id': 'season-2',
                'series_name': 'Phần 2 (Đã phát)',
                'content_type': 1004,
                'episode_cnt': 60,
                'season_index': 2,
                'tag_info': {'text': '第2季'},
              },
              {
                'series_id': 'season-3',
                'series_name': 'Phần 3 (Sắp chiếu)',
                'content_type': 1007,
                'episode_cnt': 0,
                'disable_play': true,
                'season_index': 3,
              },
              {
                'series_id': 'disabled-play',
                'series_name': 'Bị tắt',
                'content_type': 1004,
                'episode_cnt': 10,
                'disable_play': true,
                'season_index': 4,
              },
            ],
          },
          {
            'show_type': 506,
            'cell_name': '猜你喜欢',
            'cell_data': [
              {
                'video_data': [
                  {
                    'series_id': 'sim-1',
                    'series_name': '一束炀火暖流年',
                    'episode_cnt': 55,
                    'category_schema': jsonEncode([
                      {'category_id': 5472, 'name': '青春爱情'},
                    ]),
                  },
                  {
                    'series_id': 'current-id',
                    'series_name': 'Bị loại trùng',
                    'episode_cnt': 50,
                  },
                ],
              },
            ],
          },
        ],
      });

      final bundle = service.parseRelatedPlanResponse(
        raw,
        currentSeriesId: 'current-id',
        fallbackSourceCategory: 'category/ai-drama',
      );

      expect(bundle.seasons, hasLength(2));
      expect(bundle.seasons[0].drama.seriesId, 'season-2');
      expect(bundle.seasons[0].seasonLabel, '第2季');
      expect(bundle.seasons[0].upcoming, false);
      expect(bundle.seasons[1].drama.seriesId, 'season-3');
      expect(bundle.seasons[1].upcoming, true);

      expect(bundle.similarDramas, hasLength(1));
      expect(bundle.similarDramas.first.seriesId, 'sim-1');
      expect(bundle.similarDramas.first.sourceCategory, 'category/ai-drama');
    });
  });

  group('HongguoSimilarEngine ecosystem-locked bundle matching', () {
    late _FakeDiscoveryService fakeDiscovery;

    setUp(() {
      fakeDiscovery = _FakeDiscoveryService();
      HongguoSimilarEngine.instance.setDiscoveryServiceForTest(fakeDiscovery);
    });

    tearDown(() {
      HongguoSimilarEngine.instance
          .setDiscoveryServiceForTest(HongguoDiscoveryService.instance);
    });

    test('findSimilarBundle keeps AI school-romance strictly in aiSeries', () async {
      fakeDiscovery.relatedResult = HongguoRelatedBundle(
        seasons: [
          HongguoRelatedSeasonItem(
            drama: const HongguoDramaItem(
              seriesId: 's2',
              title: 'Phần 2',
              cover: '',
              episodeCount: 40,
              sourceCategory: 'category/ai-drama',
            ),
            seasonLabel: 'Phần 2',
            seasonIndex: 2,
          ),
        ],
        similarDramas: const [
          HongguoDramaItem(
            seriesId: 'official-ai-1',
            title: 'AI Học đường chính thức',
            cover: '',
            episodeCount: 60,
            tags: ['校园', '爱情'],
            sourceCategory: 'category/ai-drama',
          ),
        ],
      );

      fakeDiscovery.discoveryItemsByGenre = {
        HongguoGenreKind.aiSeries.id: const [
          HongguoDramaItem(
            seriesId: 'pad-ai-1',
            title: 'AI Thanh xuân cùng kho',
            cover: '',
            episodeCount: 45,
            tags: ['青春爱情'],
            categoryIds: ['5472'],
            sourceCategory: 'category/ai-drama',
          ),
        ],
        HongguoGenreKind.realPlay.id: const [
          HongguoDramaItem(
            seriesId: 'real-should-not-appear',
            title: 'Người thật tuyệt đối không trộn',
            cover: '',
            episodeCount: 80,
            tags: ['校园'],
            sourceCategory: 'category/real-drama',
          ),
        ],
      };

      const detail = HongguoDramaDetail(
        seriesId: 'cur-ai',
        title: 'AI Thanh xuân hiện tại',
        cover: '',
        intro: '',
        totalEpisodes: 50,
        tags: ['校园', '爱情'],
        sourceCategory: 'category/ai-drama',
        categoryIds: ['5472', '4'],
      );

      final result = await HongguoSimilarEngine.instance.findSimilarBundle(
        detail: detail,
        maxResults: 12,
      );

      expect(result.seasons, hasLength(1));
      expect(result.seasons.first.drama.seriesId, 's2');

      expect(
        result.similar.map((e) => e.drama.seriesId),
        containsAll(['official-ai-1', 'pad-ai-1']),
      );
      expect(
        result.similar.map((e) => e.drama.seriesId),
        isNot(contains('real-should-not-appear')),
      );
      expect(result.similar.first.fromOfficialRelated, true);

      expect(fakeDiscovery.recordedSelections, isNotEmpty);
      for (final sel in fakeDiscovery.recordedSelections) {
        expect(sel.genreKind, HongguoGenreKind.aiSeries);
      }
      // First combined discovery call combines epoch=cate_4 (校园) + gender=0 (爱情)
      expect(
        fakeDiscovery.recordedSelections.first.valueOf('category_dim_epoch'),
        'cate_4',
      );
      expect(fakeDiscovery.recordedSelections.first.valueOf('gender'), '0');
    });

    test('Feed channel request uses default empty sort while library uses hot_score', () {
      const comicSel = HongguoDiscoverySelection(
        genreKind: HongguoGenreKind.comicSeries,
      );
      final feedBody = comicSel.toRequestBody(useDefaultFeedSort: true);
      expect(feedBody['req_scene'], 'comic_series');
      expect((feedBody['select_items'] as Map)['sort'], isEmpty);

      final libraryBody = comicSel.toRequestBody(useDefaultFeedSort: false);
      expect((libraryBody['select_items'] as Map)['sort'], ['hot_score']);

      const realSel = HongguoDiscoverySelection(
        genreKind: HongguoGenreKind.realPlay,
      );
      final realFeedBody = realSel.toRequestBody(useDefaultFeedSort: true);
      expect(realFeedBody['req_scene'], 'default');
      expect((realFeedBody['select_items'] as Map)['genre'], ['short_play']);
      expect((realFeedBody['select_items'] as Map)['sort'], isEmpty);
    });

    test('getFollowFeedList merges Hongguo watch-later seeds and related recommendations', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      HongguoCloudAccountService.instance.resetForTesting();

      final repo = await WatchLaterRepository.getInstance();
      await repo.addItem(
        const WatchLaterItem(
          id: 'hg_777001',
          title: 'Bộ đang theo dõi',
          source: 'hongguo',
          targetUrl: '777001',
          seriesId: '777001',
          totalEpisodes: 50,
          addedAt: 1000,
        ),
      );
      await repo.addItem(
        const WatchLaterItem(
          id: 'bili_BV1xx',
          title: 'Bilibili ignore',
          source: 'bilibili',
          targetUrl: 'https://www.bilibili.com/video/BV1xx',
          addedAt: 2000,
        ),
      );

      final fakeDiscovery = _FakeDiscoveryService();
      HongguoSimilarEngine.instance.setDiscoveryServiceForTest(fakeDiscovery);
      fakeDiscovery.relatedResult = const HongguoRelatedBundle(
        similarDramas: [
          HongguoDramaItem(
            seriesId: '888001',
            title: 'Liên quan theo dõi',
            cover: '',
            episodeCount: 60,
          ),
        ],
      );

      final followRes = await HongguoSimilarEngine.instance.getFollowFeedList();
      final ids = followRes.items.map((e) => e.seriesId).toList();
      expect(followRes.directFollowCount, 1);
      expect(ids, containsAll(['777001', '888001']));
      expect(ids, isNot(contains('bili_BV1xx')));
    });
  });
}
