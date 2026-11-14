import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:capsub_flutter/data/model/history_item.dart';
import 'package:capsub_flutter/data/model/subtitle_document.dart';
import 'package:capsub_flutter/data/model/subtitle_item.dart';
import 'package:capsub_flutter/data/model/watch_later_item.dart';
import 'package:capsub_flutter/domain/ai/live/gemini_live_client.dart';
import 'package:capsub_flutter/domain/ai/live/live_audio_io.dart';
import 'package:capsub_flutter/domain/ai/live/live_reply_title_sync.dart';
import 'package:capsub_flutter/domain/media/bilibili/bilibili_assistant_engine.dart';
import 'package:capsub_flutter/domain/media/bilibili/bilibili_srt_service.dart';
import 'package:capsub_flutter/domain/media/bilibili/bilibili_taste_service.dart';
import 'package:capsub_flutter/domain/media/bilibili_resolver.dart';
import 'package:capsub_flutter/domain/media/chinese_title_suggestion.dart';
import 'package:capsub_flutter/ui/bilibili/bilibili_assistant_controller.dart';

typedef _MockResponseBuilder =
    Map<String, dynamic> Function(RequestOptions options);

class _FakeHttpAdapter implements HttpClientAdapter {
  final _MockResponseBuilder builder;
  final List<RequestOptions> requests = [];

  _FakeHttpAdapter(this.builder);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final payload = builder(options);
    return ResponseBody.fromString(
      jsonEncode(payload),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FakeLiveClient extends GeminiLiveClient {
  final List<String> sentTexts = [];
  bool connected = true;

  @override
  bool get isConnected => connected;

  @override
  String get activeModelId => 'gemini-3.8-live';

  @override
  String get activeApiVersion => 'v1beta';

  @override
  String get activeApiKey => 'AIzaSyFakeTestKey1234';

  @override
  void sendClientText(String text, {bool turnComplete = true}) {
    sentTexts.add(text);
  }

  @override
  Future<void> disconnect({bool intentional = true}) async {
    connected = false;
  }
}

class _FakeMicRecorder extends LiveMicRecorder {
  @override
  Future<bool> hasPermission() async => false;

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

class _FakeAudioOutput extends LivePcmAudioOutput {
  @override
  Future<void> interrupt() async {}

  @override
  Future<void> flushTurn() async {}

  @override
  Future<void> dispose() async {}
}

BilibiliVideoDetails _makeDetails({
  String bvid = 'BV1xx411c7mD',
  int aid = 10001,
  int cid = 20001,
  String title = '【教程】10分钟入门 Python 异步编程',
  int durationSeconds = 600,
}) {
  return BilibiliVideoDetails(
    bvid: bvid,
    aid: aid,
    cid: cid,
    title: title,
    durationSeconds: durationSeconds,
    author: '技术UP',
    ownerMid: 8888,
    viewCountText: '12.5万',
    danmakuText: '320',
    desc: '深入浅出讲解 asyncio 事件循环与协程并发。',
    pages: const [
      BilibiliPageInfo(page: 1, cid: 20001, part: '基础篇', durationSeconds: 300),
      BilibiliPageInfo(page: 2, cid: 20002, part: '实战篇', durationSeconds: 300),
    ],
  );
}

SubtitleDocument _makeLongDoc({
  int count = 45,
  int lineLength = 150,
  int stepMs = 15000,
}) {
  final filler = 'A' * lineLength;
  final items = <SubtitleItem>[];
  for (var i = 0; i < count; i++) {
    final start = i * stepMs;
    final topic = i == 25 ? 'ASYNCIO_TARGET_TOPIC ' : '';
    items.add(
      SubtitleItem(
        id: i + 1,
        startMs: start,
        endMs: start + 4000,
        originalText: '$topic第${i + 1}句内容：$filler',
      ),
    );
  }
  return SubtitleDocument(items);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BilibiliPartition catalog & lookup', () {
    test('byTid and resolve map names, numbers, and aliases accurately', () {
      expect(BilibiliPartition.byTid(36)?.zhName, '知识');
      expect(BilibiliPartition.byTid(36)?.viLabel, 'Kiến thức / Học tập');
      expect(BilibiliPartition.byTid(999999), isNull);

      expect(BilibiliPartition.resolve('tech').tid, 188);
      expect(BilibiliPartition.resolve('tai lieu').tid, 177);
      expect(BilibiliPartition.resolve('giai tri').tid, 5);
      expect(BilibiliPartition.resolve('Kiến thức').tid, 36);
      expect(BilibiliPartition.resolve('donghua').tid, 167);
      expect(BilibiliPartition.resolve('188').tid, 188);
      expect(BilibiliPartition.resolve(4).tid, 4);
      expect(BilibiliPartition.resolve('khong_ton_tai').tid, 0);
    });
  });

  group('BilibiliResolver discovery & search APIs (mocked Dio)', () {
    late BilibiliResolver resolver;
    late _FakeHttpAdapter adapter;

    setUp(() {
      resolver = BilibiliResolver();
      adapter = _FakeHttpAdapter((options) {
        final path = options.uri.path;
        final q = options.uri.queryParameters;

        if (path == '/x/web-interface/nav') {
          return {
            'code': 0,
            'data': {
              'wbi_img': {
                'img_url':
                    'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
                'sub_url':
                    'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
              },
            },
          };
        }

        if (path.endsWith('/search/type')) {
          final searchType = q['search_type'];
          if (searchType == 'video') {
            return {
              'code': 0,
              'data': {
                'result': [
                  {
                    'bvid': 'BV1PyAsync01',
                    'title': '<em class="keyword">Python</em> 异步协程深度解析',
                    'pic': '//i0.hdslb.com/bfs/archive/py.jpg',
                    'author': '代码匠',
                    'upic': '//i0.hdslb.com/bfs/face/up.jpg',
                    'duration': '15:20',
                    'play': 125000,
                    'danmaku': 640,
                    'typename': '科技',
                    'description': '事件循环原理与实战示例',
                  },
                ],
              },
            };
          }
          if (searchType == 'bili_user') {
            return {
              'code': 0,
              'data': {
                'result': [
                  {
                    'mid': 546195,
                    'uname': '老番茄',
                    'upic': '//i0.hdslb.com/bfs/face/laofanqie.jpg',
                    'usign': '知名游戏UP主',
                    'fans': 19500000,
                    'videos': 420,
                    'official_verify': {'type': 0, 'desc': 'bilibili 知名UP主'},
                  },
                ],
              },
            };
          }
          if (searchType == 'media_ft' || searchType == 'media_bangumi') {
            return {
              'code': 0,
              'data': {
                'result': [
                  {
                    'season_id': 28561,
                    'media_id': 99812,
                    'title': '<em class="keyword">历史</em>纪录片：河西走廊',
                    'cover': '//i0.hdslb.com/bfs/bangumi/hxzl.jpg',
                    'areas': '中国大陆',
                    'styles': '历史 / 人文',
                    'index_show': '全10集',
                    'media_score': {'score': 9.8},
                    'desc': '横跨千年的丝绸之路故事',
                    'season_type': 3,
                    'eps': [
                      {'id': 312001},
                    ],
                  },
                ],
              },
            };
          }
        }

        if (path == '/x/web-interface/ranking/v2') {
          return {
            'code': 0,
            'data': {
              'list': [
                {
                  'bvid': 'BV1Rank36Key1',
                  'title': '为什么现代芯片离不开光刻机？',
                  'pic': '//i0.hdslb.com/bfs/archive/chip.jpg',
                  'duration': 905,
                  'owner': {'name': '硬件茶谈', 'face': '//i0.hdslb.com/f1.jpg'},
                  'stat': {'view': 890000, 'danmaku': 4100},
                  'tname': '知识',
                  'desc': 'ASML极紫外光刻技术图解',
                },
              ],
            },
          };
        }

        return {'code': 0, 'data': {}};
      });
      resolver.dio.httpClientAdapter = adapter;
    });

    test('searchVideos forwards tid, duration, order and strips HTML tags', () async {
      final items = await resolver.searchVideos(
        'Python 异步',
        tid: 188,
        duration: 2,
        order: 'click',
      );

      expect(items, hasLength(1));
      expect(items.first.bvid, 'BV1PyAsync01');
      expect(items.first.title, 'Python 异步协程深度解析');
      expect(items.first.durationSeconds, 15 * 60 + 20);
      expect(items.first.cover, 'https://i0.hdslb.com/bfs/archive/py.jpg');

      final searchReq = adapter.requests.lastWhere(
        (r) => r.uri.path.endsWith('/search/type'),
      );
      expect(searchReq.uri.queryParameters['tids'], '188');
      expect(searchReq.uri.queryParameters['duration'], '2');
      expect(searchReq.uri.queryParameters['order'], 'click');
    });

    test('searchUsers parses bili_user results and official badge', () async {
      final users = await resolver.searchUsers('老番茄');
      expect(users, hasLength(1));
      expect(users.first.mid, 546195);
      expect(users.first.uname, '老番茄');
      expect(users.first.isOfficial, isTrue);
      expect(users.first.videos, 420);
      expect(users.first.upic, 'https://i0.hdslb.com/bfs/face/laofanqie.jpg');
    });

    test('searchPgc parses media_ft documentary season details', () async {
      final pgcs = await resolver.searchPgc('河西走廊', searchType: 'media_ft');
      expect(pgcs, hasLength(1));
      expect(pgcs.first.seasonId, 28561);
      expect(pgcs.first.firstEpId, 312001);
      expect(pgcs.first.title, '历史纪录片：河西走廊');
      expect(pgcs.first.score, '9.8');
      expect(pgcs.first.areas, '中国大陆');
    });

    test('getZoneRanking parses ranking/v2 feed with rid', () async {
      final items = await resolver.getZoneRanking(rid: 36);
      expect(items, hasLength(1));
      expect(items.first.bvid, 'BV1Rank36Key1');
      expect(items.first.author, '硬件茶谈');
      final req = adapter.requests.last;
      expect(req.uri.queryParameters['rid'], '36');
    });
  });

  group('BilibiliSrtChunker & BilibiliSrtService (Phương án A)', () {
    test('short SRT fits <= 2 chunks and sends all chunks upfront', () {
      final doc = SubtitleDocument([
        SubtitleItem(id: 1, startMs: 0, endMs: 3000, originalText: '大家好'),
        SubtitleItem(id: 2, startMs: 3000, endMs: 8000, originalText: '欢迎来到频道'),
      ]);
      final service = BilibiliSrtService();
      final session = service.buildAndCacheSession(
        details: _makeDetails(),
        document: doc,
        sourceKind: BilibiliSrtSourceKind.bilibiliCc,
        languageLabel: 'zh-CN',
      );

      expect(session.isLongVideo, isFalse);
      final overview = session.buildOverviewPayload();
      expect(overview['hasSrt'], isTrue);
      expect(overview['sentAllChunks'], isTrue);
      expect(overview['chunks'], hasLength(1));
      expect((overview['chunks'] as List).first['transcript'], contains('[00:00] 大家好'));
    });

    test('long SRT chunks cleanly, pages readChunkPayload, and searches topic', () {
      final doc = _makeLongDoc(count: 45, lineLength: 160, stepMs: 15000);
      final service = BilibiliSrtService();
      final session = service.buildAndCacheSession(
        details: _makeDetails(durationSeconds: 900),
        document: doc,
        sourceKind: BilibiliSrtSourceKind.bilibiliCc,
        languageLabel: 'zh-Hans',
      );

      expect(session.totalChunks, greaterThan(2));
      expect(session.isLongVideo, isTrue);

      final overview = session.buildOverviewPayload();
      expect(overview['sentAllChunks'], isFalse);
      expect((overview['chunkMap'] as List).length, session.totalChunks);
      expect(overview['currentChunk']['chunkNumber'], 1);

      final page2 = session.readChunkPayload(2);
      expect(page2['ok'], isTrue);
      expect(page2['chunkNumber'], 2);
      expect(page2['hasPrev'], isTrue);

      final invalidPage = session.readChunkPayload(999);
      expect(invalidPage['ok'], isFalse);

      final topicHit = session.searchTopicPayload(['ASYNCIO_TARGET_TOPIC']);
      expect(topicHit['ok'], isTrue);
      expect(topicHit['matchCount'], 1);
      final matches = topicHit['matches'] as List;
      expect(matches, hasLength(1));
      expect(matches.first['excerpt'], contains('ASYNCIO_TARGET_TOPIC'));
    });

    test('loadFastSrt checks history tier without calling CC or STT', () async {
      var sttCalls = 0;
      final resolver = BilibiliResolver();
      resolver.dio.httpClientAdapter = _FakeHttpAdapter((_) {
        throw StateError('Network should not be called when history hits');
      });

      final service = BilibiliSrtService(
        resolver: resolver,
        historyDocLoader: (bvid, page) async {
          return SubtitleDocument([
            SubtitleItem(
              id: 1,
              startMs: 1000,
              endMs: 4000,
              originalText: '历史缓存字幕内容',
            ),
          ]);
        },
        sttDocExtractor: (_, {required cookie, required sourceLanguage, onProgress}) async {
          sttCalls++;
          return null;
        },
      );

      final result = await service.loadFastSrt(_makeDetails());
      expect(result.session, isNotNull);
      expect(result.session!.sourceKind, BilibiliSrtSourceKind.historyCache);
      expect(sttCalls, 0);

      // Subsequent call hits in-memory RAM cache
      final second = await service.loadFastSrt(_makeDetails());
      expect(second.session, same(result.session));
    });

    test('loadFastSrt fetches CC subtitle via Dio and caches session', () async {
      final resolver = BilibiliResolver();
      resolver.dio.httpClientAdapter = _FakeHttpAdapter((options) {
        if (options.uri.path == '/x/player/wbi/v2') {
          return {
            'code': 0,
            'data': {
              'subtitle': {
                'subtitles': [
                  {
                    'lan': 'zh-CN',
                    'lan_doc': '中文（自动生成）',
                    'type': 1,
                    'subtitle_url': '//aisubtitle.hdslb.com/bfs/subtitle/test.json',
                  },
                ],
              },
            },
          };
        }
        if (options.uri.host == 'aisubtitle.hdslb.com') {
          return {
            'body': [
              {'from': 0.0, 'to': 2.5, 'content': '第一句字幕'},
              {'from': 2.5, 'to': 6.0, 'content': '第二句字幕'},
            ],
          };
        }
        return {'code': 0, 'data': {}};
      });

      final service = BilibiliSrtService(
        resolver: resolver,
        historyDocLoader: (_, _) async => null,
      );
      final result = await service.loadFastSrt(_makeDetails());
      expect(result.session, isNotNull);
      expect(result.session!.sourceKind, BilibiliSrtSourceKind.bilibiliCc);
      expect(result.session!.document.size, 2);
    });

    test('Phương án A: login-locked CC does NOT auto-trigger CapCut STT until explicitly requested', () async {
      var sttCalls = 0;
      final resolver = BilibiliResolver();
      resolver.dio.httpClientAdapter = _FakeHttpAdapter((options) {
        if (options.uri.path.contains('/x/player/')) {
          return {
            'code': 0,
            'data': {
              'need_login_subtitle': true,
              'subtitle': {'subtitles': []},
            },
          };
        }
        return {'code': 0, 'data': {}};
      });

      final service = BilibiliSrtService(
        resolver: resolver,
        historyDocLoader: (_, _) async => null,
        sttDocExtractor: (_, {required cookie, required sourceLanguage, onProgress}) async {
          sttCalls++;
          onProgress?.call(0.5, 'Đang nhận dạng');
          return SubtitleDocument([
            SubtitleItem(
              id: 1,
              startMs: 0,
              endMs: 4000,
              originalText: 'CapCut STT generated line',
            ),
          ]);
        },
      );

      final fastRes = await service.loadFastSrt(_makeDetails());
      expect(fastRes.session, isNull);
      expect(fastRes.loginRequiredForCc, isTrue);
      expect(fastRes.sttAvailable, isTrue);
      expect(sttCalls, 0);

      // Now explicitly extract via CapCut STT
      final sttRes = await service.extractSrtWithCapCutStt(_makeDetails());
      expect(sttCalls, 1);
      expect(sttRes.session, isNotNull);
      expect(sttRes.session!.sourceKind, BilibiliSrtSourceKind.capcutStt);
    });
  });

  group('BilibiliAssistantEngine tool orchestration, Phương án A & Title sync', () {
    late BilibiliResolver resolver;
    late int sttCalls;
    late bool ccAvailable;

    BilibiliAssistantEngine createEngine({
      List<SubtitleItem>? customCcLines,
    }) {
      sttCalls = 0;
      resolver = BilibiliResolver();
      resolver.dio.httpClientAdapter = _FakeHttpAdapter((options) {
        final path = options.uri.path;
        final q = options.uri.queryParameters;

        if (path == '/x/web-interface/nav') {
          return {
            'code': 0,
            'data': {
              'wbi_img': {
                'img_url':
                    'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
                'sub_url':
                    'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
              },
            },
          };
        }

        if (path.endsWith('/search/type')) {
          final st = q['search_type'];
          final kw = q['keyword'] ?? '';
          if (st == 'video') {
            // Simulate narrow query with strict tid+duration failing, then loosening succeeding!
            if (kw == '窄词Python' && (q['duration'] ?? '0') != '0') {
              return {'code': 0, 'data': {'result': []}};
            }
            return {
              'code': 0,
              'data': {
                'result': [
                  {
                    'bvid': 'BV1BiliTest01',
                    'title': '万字解析 Python 异步事件循环',
                    'pic': '//i0.hdslb.com/1.jpg',
                    'author': '技术UP',
                    'duration': '22:10',
                    'play': 340000,
                    'danmaku': 900,
                    'typename': '科技',
                  },
                  {
                    'bvid': 'BV1BiliTest02',
                    'title': '修仙漫剧：炼气期一层逆袭',
                    'pic': '//i0.hdslb.com/2.jpg',
                    'author': '漫剧社',
                    'duration': '15:30',
                    'play': 180000,
                    'danmaku': 450,
                    'typename': '国创',
                  },
                  {
                    'bvid': 'BV1BiliShortLeak',
                    'title': 'Python 快速片段（5分钟不应漏入10-30分筛选）',
                    'pic': '//i0.hdslb.com/3.jpg',
                    'author': '短视频UP',
                    'duration': '05:20',
                    'play': 500000,
                    'danmaku': 1200,
                    'typename': '科技',
                  },
                ],
              },
            };
          }
          if (st == 'bili_user') {
            return {
              'code': 0,
              'data': {
                'result': [
                  {
                    'mid': 123456,
                    'uname': '极客湾Geekerwan',
                    'upic': '//i0.hdslb.com/gkw.jpg',
                    'usign': '硬核数码评测',
                    'fans': 5200000,
                    'videos': 210,
                    'official_verify': {'type': 0, 'desc': '知名科技UP'},
                  },
                ],
              },
            };
          }
        }

        if (path.endsWith('/arc/search')) {
          return {
            'code': 0,
            'data': {
              'list': {
                'vlist': [
                  {
                    'bvid': 'BV1CreatorVid1',
                    'title': 'RTX 5090 深度实测报告',
                    'pic': '//i0.hdslb.com/rtx.jpg',
                    'author': '极客湾Geekerwan',
                    'play': 2100000,
                    'video_review': 8200,
                    'length': '18:45',
                  },
                ],
              },
            },
          };
        }

        if (path == '/x/web-interface/ranking/v2') {
          return {
            'code': 0,
            'data': {
              'list': [
                {
                  'bvid': 'BV1RankTech01',
                  'title': '2026 AI 开源模型横评',
                  'pic': '//i0.hdslb.com/ai.jpg',
                  'duration': 740,
                  'owner': {'name': 'AI前线', 'face': ''},
                  'stat': {'view': 410000, 'danmaku': 1200},
                  'tname': '科技',
                },
              ],
            },
          };
        }

        if (path == '/x/web-interface/search/square') {
          return {
            'code': 0,
            'data': {
              'trending': {
                'list': [
                  {'show_name': 'AI编程助手'},
                  {'show_name': '物理诺贝尔奖'},
                ],
              },
            },
          };
        }

        if (path == '/x/web-interface/wbi/view') {
          return {
            'code': 0,
            'data': {
              'bvid': q['bvid'] ?? 'BV1BiliTest01',
              'aid': 99001,
              'cid': 88001,
              'title': '万字解析 Python 异步事件循环',
              'desc': '系统讲解 Python asyncio Coroutine 与 Task 调度机制。',
              'pic': '//i0.hdslb.com/1.jpg',
              'duration': 1330,
              'owner': {'mid': 8888, 'name': '技术UP', 'face': '//i0.hdslb.com/f.jpg'},
              'stat': {'view': 340000, 'danmaku': 900},
              'pages': [
                {'page': 1, 'cid': 88001, 'part': '原理篇', 'duration': 600},
                {'page': 2, 'cid': 88002, 'part': '实战篇', 'duration': 730},
              ],
            },
          };
        }

        if (path == '/x/v2/reply') {
          return {
            'code': 0,
            'data': {
              'page': {'count': 1},
              'replies': [
                {
                  'rpid': 701,
                  'oid': 99001,
                  'mid': 555,
                  'like': 1520,
                  'member': {'uname': '课代表', 'avatar': ''},
                  'content': {'message': '省流：05:20 开始讲核心事件循环源码！'},
                },
              ],
            },
          };
        }

        if (path == '/x/player/wbi/v2') {
          if (!ccAvailable) {
            return {
              'code': 0,
              'data': {
                'need_login_subtitle': true,
                'subtitle': {'subtitles': []},
              },
            };
          }
          return {
            'code': 0,
            'data': {
              'subtitle': {
                'subtitles': [
                  {
                    'lan': 'zh-CN',
                    'lan_doc': '中文',
                    'type': 1,
                    'subtitle_url': '//aisubtitle.hdslb.com/bfs/sub/v1.json',
                  },
                ],
              },
            },
          };
        }

        if (options.uri.host == 'aisubtitle.hdslb.com') {
          final lines = customCcLines ??
              [
                SubtitleItem(
                  id: 1,
                  startMs: 0,
                  endMs: 3000,
                  originalText: '大家好，今天讲事件循环',
                ),
                SubtitleItem(
                  id: 2,
                  startMs: 5000,
                  endMs: 10000,
                  originalText: '关键知识点在这里：TASK_QUEUE',
                ),
              ];
          return {
            'body': [
              for (final s in lines)
                {
                  'from': s.startMs / 1000.0,
                  'to': s.endMs / 1000.0,
                  'content': s.originalText,
                },
            ],
          };
        }

        return {'code': 0, 'data': {}};
      });

      final srtService = BilibiliSrtService(
        resolver: resolver,
        historyDocLoader: (_, _) async => null,
        sttDocExtractor: (_, {required cookie, required sourceLanguage, onProgress}) async {
          sttCalls++;
          onProgress?.call(0.8, 'Đang tạo SRT');
          return SubtitleDocument([
            SubtitleItem(
              id: 1,
              startMs: 0,
              endMs: 4000,
              originalText: 'CapCut STT transcript line',
            ),
          ]);
        },
      );

      return BilibiliAssistantEngine(
        resolver: resolver,
        srtService: srtService,
      );
    }

    test('search_bilibili_videos runs narrow->broad + auto-loosening & syncs Hán Việt titles', () async {
      ccAvailable = true;
      final engine = createEngine();
      BilibiliSearchReport? pushedReport;

      final res = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'call_search_1',
          name: 'search_bilibili_videos',
          args: {
            'queries_narrow_to_broad': ['窄词Python', 'Python 异步'],
            'target_keywords': ['事件循环'],
            'partition_tid': 188,
            'duration_bucket': 2,
          },
        ),
        onSearchResultsUpdated: (r) => pushedReport = r,
      );

      expect(res.response['ok'], isTrue);
      expect(pushedReport, isNotNull);
      expect(pushedReport!.candidates, hasLength(2));
      expect(engine.lastDisplayedCandidates, hasLength(2));

      // Simulate Live model returning Vietnamese + Hán Việt titles (#1..#N)
      final parsedTitles = LiveReplyTitleSync.extractAiTitlesFromLiveReply(
        '#1. Phân Tích Chuyên Sâu Vòng Lặp Sự Kiện Python — rất chi tiết.\n'
        '#2. Luyện Khí Tầng Một Nghịch Tập — phim hệ thống tu tiên.',
        isFinal: true,
      );
      final synced = engine.applyAiTranslatedTitlesToReport(
        pushedReport!,
        parsedTitles,
      );
      expect(synced, isNotNull);
      expect(
        synced!.candidates.first.viTitle,
        'Phân Tích Chuyên Sâu Vòng Lặp Sự Kiện Python',
      );
      expect(synced.candidates[1].viTitle, 'Luyện Khí Tầng Một Nghịch Tập');
      expect(engine.lastDisplayedCandidates[1].viTitle, 'Luyện Khí Tầng Một Nghịch Tập');
    });

    test('explore_bilibili_discovery and search_bilibili_creators handle ranking, hot keywords & creators', () async {
      ccAvailable = true;
      final engine = createEngine();

      final hotRes = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'c_hot',
          name: 'explore_bilibili_discovery',
          args: {'mode': 'hot_keywords'},
        ),
      );
      expect(hotRes.response['ok'], isTrue);
      expect(hotRes.response['hotKeywords'], contains('AI编程助手'));

      final rankRes = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'c_rank',
          name: 'explore_bilibili_discovery',
          args: {'mode': 'ranking', 'partition_tid': 'tech', 'limit': 3},
        ),
      );
      expect(rankRes.response['ok'], isTrue);
      expect((rankRes.response['candidates'] as List).first['bvid'], 'BV1RankTech01');

      final creatorRes = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'c_up',
          name: 'search_bilibili_creators',
          args: {'keyword': '极客湾'},
        ),
      );
      expect(creatorRes.response['ok'], isTrue);
      expect(engine.lastDisplayedCandidates.first.kind, BilibiliCandidateKind.upChannel);
      expect(engine.lastDisplayedCandidates.first.userResult?.mid, 123456);
    });

    test('inspect_video_overview loads CC + HotComments + pages and updates card SRT badge', () async {
      ccAvailable = true;
      final longDoc = _makeLongDoc(count: 45, lineLength: 160, stepMs: 15000);
      final engine = createEngine(customCcLines: longDoc.items);

      // Seed candidates list via search first
      await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'c_s',
          name: 'search_bilibili_videos',
          args: {
            'queries_narrow_to_broad': ['Python 异步'],
          },
        ),
      );

      BilibiliSearchReport? updatedReport;
      final inspectRes = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'c_i',
          name: 'inspect_video_overview',
          args: {'index': 1},
        ),
        onSearchResultsUpdated: (r) => updatedReport = r,
      );

      expect(inspectRes.response['ok'], isTrue);
      final srtMap = inspectRes.response['srt'] as Map<String, dynamic>;
      expect(srtMap['hasSrt'], isTrue);
      expect(srtMap['totalChunks'], greaterThan(2));
      expect(inspectRes.response['hotCommentsCount'], 1);
      expect((inspectRes.response['video'] as Map)['pagesCount'], 2);
      expect(sttCalls, 0);

      // Card #1 must now reflect SRT loaded in memory
      expect(updatedReport, isNotNull);
      expect(updatedReport!.candidates.first.hasSrtInMemory, isTrue);
      expect(updatedReport!.candidates.first.srtChunkCount, greaterThan(2));

      // Test chunk pagination & topic jump on active SRT session
      final chunk2 = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'c_c2',
          name: 'read_srt_chunk',
          args: {'chunk_number': 2},
        ),
      );
      expect(chunk2.response['ok'], isTrue);
      expect(chunk2.response['chunkNumber'], 2);

      final topic = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'c_topic',
          name: 'search_srt_topic',
          args: {
            'keywords': ['ASYNCIO_TARGET_TOPIC'],
          },
        ),
      );
      expect(topic.response['ok'], isTrue);
      expect(topic.response['matchCount'], 1);
    });

    test('Phương án A: inspect_video_overview without CC summarizes metadata/comments and never auto-triggers STT', () async {
      ccAvailable = false;
      final engine = createEngine();

      final inspectRes = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'c_nocc',
          name: 'inspect_video_overview',
          args: {'bvid': 'BV1BiliTest01'},
        ),
      );

      expect(inspectRes.response['ok'], isTrue);
      final srtMap = inspectRes.response['srt'] as Map<String, dynamic>;
      expect(srtMap['hasSrt'], isFalse);
      expect(srtMap['loginRequiredForCc'], isTrue);
      expect(srtMap['sttAvailable'], isTrue);
      expect(inspectRes.response['hotComments'], hasLength(1));
      expect(sttCalls, 0);

      // Now simulate explicit `extract_video_srt_stt` call after user consents
      final sttRes = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'c_stt',
          name: 'extract_video_srt_stt',
          args: {'bvid': 'BV1BiliTest01'},
        ),
      );
      expect(sttCalls, 1);
      expect(sttRes.response['ok'], isTrue);
      expect((sttRes.response['srt'] as Map)['hasSrt'], isTrue);
    });

    test('buildCompressedSnapshotTurns preserves UI locks, displayed cards, active SRT and <=6 turns', () async {
      ccAvailable = true;
      final engine = createEngine();
      engine.updateUiLocks(
        const BilibiliUiLocks(
          partitionTid: 188,
          durationBucket: 2,
          sortOrder: 'click',
        ),
      );
      await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'c_s',
          name: 'search_bilibili_videos',
          args: {'queries_narrow_to_broad': ['Python 异步']},
        ),
      );
      await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'c_i',
          name: 'inspect_video_overview',
          args: {'index': 1},
        ),
      );

      final history = List.generate(
        10,
        (i) => (isUser: i.isEven, text: 'Tin nhắn hội thoại #$i'),
      );
      final turns = engine.buildCompressedSnapshotTurns(history);

      // 2 snapshot turns + last 6 dialogue turns = 8
      expect(turns, hasLength(8));
      final snapshotText = (turns.first['parts'] as List).first['text'] as String;
      expect(snapshotText, contains('tid=188'));
      expect(snapshotText, contains('BV1BiliTest01'));
      expect(snapshotText, contains('SRT đang mở: BV1BiliTest01'));
    });
  });

  group('BilibiliAssistantController manual CapCut STT & summarize', () {
    test('runManualCapCutSttAndSummarize extracts SRT with progress and dispatches prompt to LiveClient', () async {
      SharedPreferences.setMockInitialValues({});
      final fakeLive = _FakeLiveClient();
      final resolver = BilibiliResolver();
      resolver.dio.httpClientAdapter = _FakeHttpAdapter((options) {
        final path = options.uri.path;
        if (path == '/x/web-interface/nav') {
          return {
            'code': 0,
            'data': {
              'wbi_img': {
                'img_url':
                    'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
                'sub_url':
                    'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
              },
            },
          };
        }
        if (path == '/x/web-interface/wbi/view') {
          return {
            'code': 0,
            'data': {
              'bvid': 'BV1ManualStt1',
              'aid': 55501,
              'cid': 66601,
              'title': '手工创建 SRT 测试视频',
              'duration': 420,
              'owner': {'mid': 123, 'name': 'UP主'},
              'stat': {'view': 1000, 'danmaku': 20},
              'pages': [
                {'page': 1, 'cid': 66601, 'part': 'P1', 'duration': 420},
              ],
            },
          };
        }
        if (path == '/x/player/wbi/v2') {
          return {
            'code': 0,
            'data': {'subtitle': {'subtitles': []}},
          };
        }
        return {'code': 0, 'data': {}};
      });

      final srtService = BilibiliSrtService(
        resolver: resolver,
        historyDocLoader: (_, _) async => null,
        sttDocExtractor: (_, {required cookie, required sourceLanguage, onProgress}) async {
          onProgress?.call(0.4, 'Đang tải audio...');
          onProgress?.call(0.9, 'Đang nhận dạng lời thoại...');
          return SubtitleDocument([
            SubtitleItem(
              id: 1,
              startMs: 0,
              endMs: 3500,
              originalText: 'Đoạn thoại được trích từ CapCut STT',
            ),
          ]);
        },
      );

      final controller = BilibiliAssistantController(
        resolver: resolver,
        srtService: srtService,
        liveClient: fakeLive,
        micRecorder: _FakeMicRecorder(),
        audioOutput: _FakeAudioOutput(),
      );

      const candidate = BilibiliAssistantCandidate(
        displayIndex: 1,
        kind: BilibiliCandidateKind.video,
        item: BilibiliAnimeItem(
          title: '手工创建 SRT 测试视频',
          cover: '',
          bvid: 'BV1ManualStt1',
        ),
        viTitle: 'Video test tạo SRT thủ công',
        matchReason: 'Test',
        sourceBadge: 'Bilibili',
        score: 99,
      );

      await controller.runManualCapCutSttAndSummarize(candidate);

      expect(controller.isRunningManualStt, isFalse);
      expect(controller.sttProgress, isNull);
      expect(controller.activeSrtSession, isNotNull);
      expect(
        controller.activeSrtSession!.sourceKind,
        BilibiliSrtSourceKind.capcutStt,
      );
      expect(fakeLive.sentTexts, hasLength(1));
      expect(fakeLive.sentTexts.first, contains('BV1ManualStt1'));

      controller.dispose();
    });
  });

  group('Bilibili upgrade: Taste, Duration>60m, Exact vs Discover, Recency & Story vs Structured', () {
    test('BilibiliAnimeItem.formatPubdate formats recent & date labels accurately', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(BilibiliAnimeItem.formatPubdate(now - 300), '5 phút trước');
      expect(BilibiliAnimeItem.formatPubdate(now - 3600), '1 giờ trước');
      expect(BilibiliAnimeItem.formatPubdate(now - 86400), '1 ngày trước');
      expect(BilibiliAnimeItem.formatPubdate(now - 5 * 86400), '5 ngày trước');
      expect(BilibiliAnimeItem.formatPubdate(now - 45 * 86400), contains('/'));
      expect(BilibiliAnimeItem.formatPubdate(0), isEmpty);
    });

    test('BilibiliResolver.searchVideos forwards pubtime bounds and getWatchHistory parses history items', () async {
      final resolver = BilibiliResolver();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final capturedParams = <Map<String, dynamic>>[];

      resolver.dio.httpClientAdapter = _FakeHttpAdapter((options) {
        final path = options.uri.path;
        if (path == '/x/web-interface/nav') {
          return {
            'code': 0,
            'data': {
              'wbi_img': {
                'img_url':
                    'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
                'sub_url':
                    'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
              },
            },
          };
        }
        if (path.endsWith('/search/type')) {
          capturedParams.add(Map<String, dynamic>.from(options.uri.queryParameters));
          return {
            'code': 0,
            'data': {
              'result': [
                {
                  'bvid': 'BV1NewPub01',
                  'title': 'AI 最新动态',
                  'pic': '//i0.hdslb.com/new.jpg',
                  'author': '前沿社',
                  'duration': '12:30',
                  'play': 50000,
                  'danmaku': 200,
                  'pubdate': now - 3600,
                },
              ],
            },
          };
        }
        if (path == '/x/web-interface/history/cursor') {
          return {
            'code': 0,
            'data': {
              'list': [
                {
                  'title': '凡人修仙传 第120集 解说',
                  'cover': '//i0.hdslb.com/hist1.jpg',
                  'author_name': '仙侠漫解',
                  'tag_name': '国创',
                  'duration': 2400,
                  'view_at': now - 7200,
                  'history': {'bvid': 'BV1HistFanren'},
                },
              ],
            },
          };
        }
        return {'code': 0, 'data': {}};
      });

      final vids = await resolver.searchVideos(
        'AI',
        pubtimeBeginSec: now - 7 * 86400,
        pubtimeEndSec: now,
      );
      expect(vids, hasLength(1));
      expect(vids.first.pubdate, now - 3600);
      expect(vids.first.publishedAtText, '1 giờ trước');
      expect(capturedParams.last['pubtime_begin_s'], (now - 7 * 86400).toString());
      expect(capturedParams.last['pubtime_end_s'], now.toString());

      final hist = await resolver.getWatchHistory(cookie: 'SESSDATA=fake_cookie');
      expect(hist, hasLength(1));
      expect(hist.first.bvid, 'BV1HistFanren');
      expect(hist.first.badge, '国创');
      expect(hist.first.author, '仙侠漫解');
    });

    test('BilibiliTasteService aggregates local + Bilibili history + rcmd & caches 5 minutes', () async {
      var remoteCalls = 0;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final resolver = BilibiliResolver();
      resolver.dio.httpClientAdapter = _FakeHttpAdapter((options) {
        final path = options.uri.path;
        if (path == '/x/web-interface/nav') {
          return {
            'code': 0,
            'data': {
              'wbi_img': {
                'img_url':
                    'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
                'sub_url':
                    'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
              },
            },
          };
        }
        if (path == '/x/web-interface/history/cursor') {
          remoteCalls++;
          return {
            'code': 0,
            'data': {
              'list': [
                {
                  'title': 'AI漫剧 重生之都市修仙 合集',
                  'author_name': '玄幻漫剧社',
                  'tag_name': '国创',
                  'duration': 4200,
                  'view_at': now - 300,
                  'history': {'bvid': 'BV1HistAI1'},
                },
              ],
            },
          };
        }
        if (path == '/x/web-interface/wbi/index/top/feed/rcmd') {
          remoteCalls++;
          return {
            'code': 0,
            'data': {
              'item': [
                {
                  'bvid': 'BV1Rcmd1',
                  'title': '修仙 系统流 高燃解说',
                  'pic': '//i0.hdslb.com/r.jpg',
                  'duration': 3800,
                  'pubdate': now - 1000,
                  'owner': {'name': '漫剧老王'},
                  'stat': {'view': 80000},
                },
              ],
            },
          };
        }
        return {'code': 0, 'data': {}};
      });

      final tasteService = BilibiliTasteService(
        resolver: resolver,
        localHistoryLoader: () async => [
          HistoryItem(
            id: 'h1',
            title: 'Phàm Nhân Tu Tiên',
            originalTitle: '凡人修仙传',
            translatedTitle: 'Phàm Nhân Tu Tiên',
            videoPath: 'https://www.bilibili.com/video/BV1Local1',
            srtPath: '',
            timestamp: now * 1000,
            durationMs: 3600000,
          ),
        ],
        watchLaterLoader: () async => [
          WatchLaterItem(
            id: 'w1',
            title: 'AI漫剧：炼气十万年',
            translatedTitle: 'Luyện Khí Mười Vạn Năm',
            source: 'bilibili',
            targetUrl: 'https://www.bilibili.com/video/BV1WL1',
            author: '玄幻漫剧社',
            addedAt: now * 1000,
          ),
        ],
      );

      final profile = await tasteService.getTasteProfile(cookie: 'SESSDATA=abc');
      expect(profile.hasSignals, isTrue);
      expect(profile.hasBilibiliCookie, isTrue);
      expect(profile.topAuthors, contains('玄幻漫剧社'));
      expect(profile.affinityTerms, contains('修仙'));
      expect(profile.promptSummary, isNotEmpty);
      final callsAfterFirst = remoteCalls;
      expect(callsAfterFirst, 2);

      // Second call within 5 min hits cache cleanly
      final cached = await tasteService.getTasteProfile(cookie: 'SESSDATA=abc');
      expect(identical(cached, profile), isTrue);
      expect(remoteCalls, callsAfterFirst);
    });

    test('Engine get_user_taste_profile & discover mode rank affinity matches higher', () async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final resolver = BilibiliResolver();
      resolver.dio.httpClientAdapter = _FakeHttpAdapter((options) {
        final path = options.uri.path;
        if (path == '/x/web-interface/nav') {
          return {
            'code': 0,
            'data': {
              'wbi_img': {
                'img_url':
                    'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
                'sub_url':
                    'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
              },
            },
          };
        }
        if (path.endsWith('/search/type')) {
          return {
            'code': 0,
            'data': {
              'result': [
                {
                  'bvid': 'BV1GenericHighView',
                  'title': '日常美食 Vlog 探店合集',
                  'pic': '//i0.hdslb.com/g.jpg',
                  'author': '路人甲',
                  'duration': '15:00',
                  'play': 800000,
                  'danmaku': 2000,
                  'pubdate': now - 3600,
                },
                {
                  'bvid': 'BV1TasteMatched',
                  'title': 'AI漫剧 修仙 重生合集',
                  'pic': '//i0.hdslb.com/t.jpg',
                  'author': '玄幻漫剧社',
                  'duration': '20:00',
                  'play': 150000,
                  'danmaku': 500,
                  'pubdate': now - 3600,
                },
              ],
            },
          };
        }
        return {'code': 0, 'data': {}};
      });

      final tasteService = BilibiliTasteService(
        resolver: resolver,
        localHistoryLoader: () async => [],
        watchLaterLoader: () async => [
          WatchLaterItem(
            id: 'w1',
            title: 'AI漫剧 修仙 合集',
            source: 'bilibili',
            targetUrl: 'https://www.bilibili.com/video/BV1WL99',
            author: '玄幻漫剧社',
            addedAt: now * 1000,
          ),
        ],
      );

      final engine = BilibiliAssistantEngine(
        resolver: resolver,
        srtService: BilibiliSrtService(
          resolver: resolver,
          historyDocLoader: (_, _) async => null,
        ),
        tasteService: tasteService,
      );

      final tasteRes = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'taste_call',
          name: 'get_user_taste_profile',
          args: {},
        ),
      );
      expect(tasteRes.response['ok'], isTrue);
      expect(tasteRes.response['hasSignals'], isTrue);
      expect(
        tasteRes.response['topAuthors'],
        contains('玄幻漫剧社'),
      );

      final discoverRes = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'discover_call',
          name: 'search_bilibili_videos',
          args: {
            'search_mode': 'discover',
            'queries_narrow_to_broad': ['合集'],
          },
        ),
      );
      final cands = discoverRes.response['candidates'] as List<dynamic>;
      expect(cands, hasLength(2));
      expect((cands.first as Map)['bvid'], 'BV1TasteMatched');
    });

    test('Strict duration filter (>60m) excludes 5-6 min leaks & warns honestly when unmet', () async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final resolver = BilibiliResolver();
      resolver.dio.httpClientAdapter = _FakeHttpAdapter((options) {
        final path = options.uri.path;
        if (path == '/x/web-interface/nav') {
          return {
            'code': 0,
            'data': {
              'wbi_img': {
                'img_url':
                    'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
                'sub_url':
                    'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
              },
            },
          };
        }
        if (path.endsWith('/search/type')) {
          return {
            'code': 0,
            'data': {
              'result': [
                {
                  'bvid': 'BV1Short5m',
                  'title': 'AI漫剧 修仙 精彩片段',
                  'pic': '//i0.hdslb.com/s.jpg',
                  'author': 'UP1',
                  'duration': '05:40',
                  'play': 900000,
                  'danmaku': 2000,
                  'pubdate': now - 3600,
                },
                {
                  'bvid': 'BV1Med35m',
                  'title': 'AI漫剧 修仙 中篇合集',
                  'pic': '//i0.hdslb.com/m.jpg',
                  'author': 'UP2',
                  'duration': '35:10',
                  'play': 300000,
                  'danmaku': 700,
                  'pubdate': now - 7200,
                },
                {
                  'bvid': 'BV1Long75m',
                  'title': 'AI漫剧 修仙 大合集 完整版',
                  'pic': '//i0.hdslb.com/l1.jpg',
                  'author': 'UP3',
                  'duration': '75:20',
                  'play': 120000,
                  'danmaku': 500,
                  'pubdate': now - 86400,
                },
              ],
            },
          };
        }
        return {'code': 0, 'data': {}};
      });

      final engine = BilibiliAssistantEngine(
        resolver: resolver,
        srtService: BilibiliSrtService(
          resolver: resolver,
          historyDocLoader: (_, _) async => null,
        ),
      );

      // 1) min_duration_minutes: 60 strictly keeps ONLY 75m video
      final resStrict = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'dur_60',
          name: 'search_bilibili_videos',
          args: {
            'queries_narrow_to_broad': ['AI漫剧 修仙'],
            'min_duration_minutes': 60,
          },
        ),
      );
      expect(resStrict.response['durationFilterSatisfied'], isTrue);
      final strictCands = resStrict.response['candidates'] as List<dynamic>;
      expect(strictCands, hasLength(1));
      expect((strictCands.first as Map)['bvid'], 'BV1Long75m');

      // 2) min_duration_minutes: 120 cannot be satisfied -> honest warning + longest-first!
      final resImpossible = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'dur_120',
          name: 'search_bilibili_videos',
          args: {
            'queries_narrow_to_broad': ['AI漫剧 修仙'],
            'min_duration_minutes': 120,
          },
        ),
      );
      expect(resImpossible.response['durationFilterSatisfied'], isFalse);
      expect(resImpossible.response['filterWarning'], isNotNull);
      final fallbackCands = resImpossible.response['candidates'] as List<dynamic>;
      expect((fallbackCands.first as Map)['bvid'], 'BV1Long75m');
      expect((fallbackCands.last as Map)['bvid'], 'BV1Short5m');
    });

    test('search_mode exact preserves Tier-1 top hits & falls back to PGC; recency 7d excludes old videos', () async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final resolver = BilibiliResolver();
      var popularCalls = 0;

      resolver.dio.httpClientAdapter = _FakeHttpAdapter((options) {
        final path = options.uri.path;
        final q = options.uri.queryParameters;
        if (path == '/x/web-interface/nav') {
          return {
            'code': 0,
            'data': {
              'wbi_img': {
                'img_url':
                    'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
                'sub_url':
                    'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
              },
            },
          };
        }
        if (path.endsWith('/search/type')) {
          final st = q['search_type'];
          final kw = q['keyword'] ?? '';
          if (st == 'video' && kw == '凡人修仙传') {
            return {
              'code': 0,
              'data': {
                'result': [
                  {
                    'bvid': 'BV1ExactFirst',
                    'title': '凡人修仙传 新年番 第1集',
                    'pic': '//i0.hdslb.com/e1.jpg',
                    'author': 'B站番剧',
                    'duration': '24:00',
                    'play': 100000,
                    'danmaku': 500,
                    'pubdate': now - 2 * 86400,
                  },
                  {
                    'bvid': 'BV1ExactOld',
                    'title': '凡人修仙传 2020老集',
                    'pic': '//i0.hdslb.com/e2.jpg',
                    'author': 'UP主',
                    'duration': '24:00',
                    'play': 9900000,
                    'danmaku': 9000,
                    'pubdate': now - 180 * 86400,
                  },
                ],
              },
            };
          }
          if (st == 'media_ft' && kw == '不存在的视频') {
            return {
              'code': 0,
              'data': {
                'result': [
                  {
                    'season_id': 44556,
                    'title': '<em class="keyword">不存在的视频</em> 电影正片',
                    'cover': '//i0.hdslb.com/pgc.jpg',
                    'areas': '中国',
                    'index_show': 'HD 正片',
                    'url': 'https://www.bilibili.com/bangumi/play/ss44556',
                  },
                ],
              },
            };
          }
          return {'code': 0, 'data': {'result': []}};
        }
        if (path == '/x/web-interface/popular') {
          popularCalls++;
          return {'code': 0, 'data': {'list': []}};
        }
        return {'code': 0, 'data': {}};
      });

      final engine = BilibiliAssistantEngine(
        resolver: resolver,
        srtService: BilibiliSrtService(
          resolver: resolver,
          historyDocLoader: (_, _) async => null,
        ),
      );

      // Exact + recency 7d -> keeps Tier-1 newest exact hit and excludes 180d old video
      final resExact = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'exact_1',
          name: 'search_bilibili_videos',
          args: {
            'search_mode': 'exact',
            'queries_narrow_to_broad': ['凡人修仙传'],
            'recency': '7d',
          },
        ),
      );
      expect(resExact.response['searchMode'], 'exact');
      expect(resExact.response['recencyFilterSatisfied'], isTrue);
      final cands = resExact.response['candidates'] as List<dynamic>;
      expect(cands, hasLength(1));
      final first = cands.first as Map;
      expect(first['bvid'], 'BV1ExactFirst');
      expect(first['published'], '2 ngày trước');

      // Exact when archive is empty tries PGC official library instead of popular videos
      final resPgcFallback = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'exact_pgc',
          name: 'search_bilibili_videos',
          args: {
            'search_mode': 'exact',
            'queries_narrow_to_broad': ['不存在的视频'],
          },
        ),
      );
      expect(popularCalls, 0);
      final pgcCands = resPgcFallback.response['candidates'] as List<dynamic>;
      expect(pgcCands, hasLength(1));
      expect((pgcCands.first as Map)['kind'], 'pgc');
    });

    test('summary_style separates story plot (no timestamps) vs structured bullet takeaways ([mm:ss])', () async {
      final resolver = BilibiliResolver();
      resolver.dio.httpClientAdapter = _FakeHttpAdapter((options) {
        final path = options.uri.path;
        if (path == '/x/web-interface/nav') {
          return {
            'code': 0,
            'data': {
              'wbi_img': {
                'img_url':
                    'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
                'sub_url':
                    'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
              },
            },
          };
        }
        if (path == '/x/web-interface/wbi/view') {
          return {
            'code': 0,
            'data': {
              'bvid': 'BV1StyleTest',
              'aid': 77701,
              'cid': 88801,
              'title': '修仙漫剧：主角重生逆袭宗门',
              'duration': 900,
              'owner': {'mid': 9, 'name': '漫剧社'},
              'stat': {'view': 10000, 'danmaku': 90},
              'pages': [
                {'page': 1, 'cid': 88801, 'part': '全集', 'duration': 900},
              ],
            },
          };
        }
        if (path == '/x/v2/reply') {
          return {'code': 0, 'data': {'replies': []}};
        }
        if (path == '/x/player/wbi/v2') {
          return {
            'code': 0,
            'data': {
              'subtitle': {
                'subtitles': [
                  {
                    'lan': 'zh-CN',
                    'lan_doc': '中文',
                    'subtitle_url': '//aisubtitle.hdslb.com/style.json',
                  },
                ],
              },
            },
          };
        }
        if (options.uri.host == 'aisubtitle.hdslb.com') {
          return {
            'body': [
              {'from': 0.0, 'to': 5.0, 'content': '萧炎在乌坦城受尽屈辱，今日重回巅峰。'},
            ],
          };
        }
        return {'code': 0, 'data': {}};
      });

      final engine = BilibiliAssistantEngine(
        resolver: resolver,
        srtService: BilibiliSrtService(
          resolver: resolver,
          historyDocLoader: (_, _) async => null,
        ),
      );

      final storyRes = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'ov_story',
          name: 'inspect_video_overview',
          args: {'bvid': 'BV1StyleTest', 'summary_style': 'story'},
        ),
      );
      expect(storyRes.response['summaryStyle'], 'story');
      expect(
        storyRes.response['summaryInstruction'],
        contains('TUYỆT ĐỐI KHÔNG chèn mốc thời gian'),
      );
      expect(
        (storyRes.response['srt'] as Map)['summaryStyle'],
        'story',
      );

      final structuredRes = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'ov_struct',
          name: 'inspect_video_overview',
          args: {'bvid': 'BV1StyleTest', 'summary_style': 'structured'},
        ),
      );
      expect(structuredRes.response['summaryStyle'], 'structured');
      expect(
        structuredRes.response['summaryInstruction'],
        contains('[mm:ss]'),
      );
    });

    test('Controller recencyBucket, resetFilters, extractAndExportSrtOnly & story STT summarize', () async {
      SharedPreferences.setMockInitialValues({});
      final fakeLive = _FakeLiveClient();
      final resolver = BilibiliResolver();
      resolver.dio.httpClientAdapter = _FakeHttpAdapter((options) {
        final path = options.uri.path;
        if (path == '/x/web-interface/wbi/view') {
          return {
            'code': 0,
            'data': {
              'bvid': 'BV1CtrlSrt',
              'aid': 55509,
              'cid': 66609,
              'title': 'AI漫剧 测试导出',
              'duration': 600,
              'owner': {'mid': 1, 'name': 'UP'},
              'stat': {'view': 100, 'danmaku': 5},
              'pages': [
                {'page': 1, 'cid': 66609, 'part': 'P1', 'duration': 600},
              ],
            },
          };
        }
        if (path == '/x/player/wbi/v2') {
          return {'code': 0, 'data': {'subtitle': {'subtitles': []}}};
        }
        return {'code': 0, 'data': {}};
      });

      final tempDir = await Directory.systemTemp.createTemp('bili_srt_test_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final srtService = _TempExportableSrtService(
        exportDir: tempDir,
        resolver: resolver,
        historyDocLoader: (_, _) async => null,
        sttDocExtractor: (_, {required cookie, required sourceLanguage, onProgress}) async {
          return SubtitleDocument([
            SubtitleItem(
              id: 1,
              startMs: 0,
              endMs: 3000,
              originalText: 'Hàn Lập rời khỏi Thất Huyền Môn.',
            ),
          ]);
        },
      );

      final controller = BilibiliAssistantController(
        resolver: resolver,
        srtService: srtService,
        liveClient: fakeLive,
        micRecorder: _FakeMicRecorder(),
        audioOutput: _FakeAudioOutput(),
      );

      controller.setRecencyBucket('7d');
      expect(controller.recencyBucket, '7d');
      expect(controller.engine.currentLocks.recencyBucket, '7d');
      expect(
        controller.engine.buildUiContextHeader(),
        contains('NGÀY ĐĂNG: 7 ngày qua'),
      );

      controller.resetFilters();
      expect(controller.recencyBucket, 'any');
      expect(controller.partitionTid, 0);
      expect(controller.durationBucket, 0);
      expect(controller.sortOrder, 'totalrank');

      const candidate = BilibiliAssistantCandidate(
        displayIndex: 1,
        kind: BilibiliCandidateKind.video,
        item: BilibiliAnimeItem(
          title: 'AI漫剧 测试导出',
          cover: '',
          bvid: 'BV1CtrlSrt',
        ),
        viTitle: 'Phim AI Tu Tiên',
        matchReason: 'Test',
        sourceBadge: 'Bilibili',
        score: 99,
      );

      // 1) extractAndExportSrtOnly exports .srt WITHOUT sending prompt to Gemini Live!
      final exportedFile = await controller.extractAndExportSrtOnly(candidate);
      expect(exportedFile, isNotNull);
      expect(await exportedFile!.exists(), isTrue);
      expect(await exportedFile.readAsString(), contains('Thất Huyền Môn'));
      expect(fakeLive.sentTexts, isEmpty);

      // 2) runManualCapCutSttAndSummarize(..., summaryStyle: 'story') dispatches story prompt
      await controller.runManualCapCutSttAndSummarize(
        candidate,
        summaryStyle: 'story',
      );
      expect(fakeLive.sentTexts, hasLength(1));
      expect(fakeLive.sentTexts.first, contains('summary_style: "story"'));
      expect(fakeLive.sentTexts.first, contains('TUYỆT ĐỐI KHÔNG chèn mốc'));

      // 3) buildSummarizePrompt separates story vs structured clearly
      final storyPrompt = controller.buildSummarizePrompt(
        candidate,
        summaryStyle: 'story',
      );
      final structPrompt = controller.buildSummarizePrompt(
        candidate,
        summaryStyle: 'structured',
      );
      expect(storyPrompt, contains('summary_style: "story"'));
      expect(structPrompt, contains('summary_style: "structured"'));

      controller.dispose();
    });
  });

  group('AI Anime focus & noise exclusion (Tutorials / Live-action / Audio novels)', () {
    test('searchVideos parses tag + typeid and BilibiliContentClassifier separates watchable AI anime from noise', () async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final resolver = BilibiliResolver();
      resolver.dio.httpClientAdapter = _FakeHttpAdapter((options) {
        final path = options.uri.path;
        if (path == '/x/web-interface/nav') {
          return {
            'code': 0,
            'data': {
              'wbi_img': {
                'img_url':
                    'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
                'sub_url':
                    'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
              },
            },
          };
        }
        if (path.endsWith('/search/type')) {
          return {
            'code': 0,
            'data': {
              'result': [
                {
                  'bvid': 'BV1TutComfy',
                  'title': '2026最新AI漫剧全流程教学 ComfyUI即梦变现',
                  'pic': '//i0.hdslb.com/tut.jpg',
                  'author': 'AI教培号',
                  'duration': '45:00',
                  'play': 500000,
                  'danmaku': 900,
                  'typename': '知识',
                  'typeid': 36,
                  'tag': 'AI漫剧,教程,ComfyUI,变现',
                  'pubdate': now - 3600,
                },
                {
                  'bvid': 'BV1AudioBook',
                  'title': '【有声小说】重生修仙AI漫剧听书纯享',
                  'pic': '//i0.hdslb.com/audio.jpg',
                  'author': '听书阁',
                  'duration': '90:00',
                  'play': 300000,
                  'danmaku': 400,
                  'typename': '动态漫·广播剧',
                  'typeid': 195,
                  'tag': '有声小说,听书,AI漫剧',
                  'pubdate': now - 7200,
                },
                {
                  'bvid': 'BV1LiveAction',
                  'title': 'AI真人短剧：霸总重生归来',
                  'pic': '//i0.hdslb.com/live.jpg',
                  'author': '短剧社',
                  'duration': '25:00',
                  'play': 200000,
                  'danmaku': 300,
                  'typename': '短剧',
                  'typeid': 181,
                  'tag': '真人短剧,实拍',
                  'pubdate': now - 7200,
                },
                {
                  'bvid': 'BV1RealAiAni1',
                  'title': '【AI动画】我用即梦重做了凡人修仙打斗片段',
                  'pic': '//i0.hdslb.com/ai1.jpg',
                  'author': '二次元AI君',
                  'duration': '12:30',
                  'play': 80000,
                  'danmaku': 250,
                  'typename': '短片·手书',
                  'typeid': 47,
                  'tag': 'AI动画,修仙,国漫',
                  'pubdate': now - 3600,
                },
                {
                  'bvid': 'BV1RealAiAni2',
                  'title': 'AI漫剧一口气看完：炼气十万年完整版',
                  'pic': '//i0.hdslb.com/ai2.jpg',
                  'author': '漫剧剧场',
                  'duration': '65:00',
                  'play': 110000,
                  'danmaku': 600,
                  'typename': '国产动画',
                  'typeid': 153,
                  'tag': 'AI漫剧,一口气看完,动画',
                  'pubdate': now - 86400,
                },
              ],
            },
          };
        }
        return {'code': 0, 'data': {}};
      });

      final raw = await resolver.searchVideos('AI漫剧');
      expect(raw, hasLength(5));
      expect(raw.first.typeId, 36);
      expect(raw.first.styles, contains('ComfyUI'));

      expect(BilibiliContentClassifier.isTutorialOrCourse(raw[0]), isTrue);
      expect(BilibiliContentClassifier.isAudioNovelOrPodcast(raw[1]), isTrue);
      expect(BilibiliContentClassifier.isLiveAction(raw[2]), isTrue);
      expect(BilibiliContentClassifier.isCleanWatchableAiAnime(raw[3]), isTrue);
      expect(BilibiliContentClassifier.isCleanWatchableAiAnime(raw[4]), isTrue);

      final cleanFeed = await resolver.getAiManhuaVideos(keyword: 'AI漫剧');
      expect(
        cleanFeed.map((e) => e.bvid).toList(),
        unorderedEquals(['BV1RealAiAni1', 'BV1RealAiAni2']),
      );
    });

    test('Engine content_focus=ai_anime expands queries, scans tid=1 & tid=167, excludes noise & auto-detects from Vietnamese prompt', () async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final queriedTids = <String>[];
      final queriedKeywords = <String>[];

      final resolver = BilibiliResolver();
      resolver.dio.httpClientAdapter = _FakeHttpAdapter((options) {
        final path = options.uri.path;
        final q = options.uri.queryParameters;
        if (path == '/x/web-interface/nav') {
          return {
            'code': 0,
            'data': {
              'wbi_img': {
                'img_url':
                    'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
                'sub_url':
                    'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
              },
            },
          };
        }
        if (path.endsWith('/search/type')) {
          queriedTids.add(q['tids'] ?? '0');
          queriedKeywords.add(q['keyword'] ?? '');
          return {
            'code': 0,
            'data': {
              'result': [
                {
                  'bvid': 'BV1NoiseTut',
                  'title': 'AI漫剧保姆级教程 从零学会',
                  'pic': '//i0.hdslb.com/t.jpg',
                  'author': '教程UP',
                  'duration': '30:00',
                  'play': 990000,
                  'danmaku': 3000,
                  'typename': '知识',
                  'typeid': 36,
                  'tag': '教程,AI漫剧',
                  'pubdate': now - 3600,
                },
                {
                  'bvid': 'BV1NoiseAudio',
                  'title': '有声小说推文：AI漫剧末日求生听书',
                  'pic': '//i0.hdslb.com/a.jpg',
                  'author': '听书UP',
                  'duration': '65:00',
                  'play': 600000,
                  'danmaku': 900,
                  'typename': '生活',
                  'typeid': 160,
                  'tag': '有声小说,推文',
                  'pubdate': now - 3600,
                },
                {
                  'bvid': 'BV1NoiseReal',
                  'title': 'AI真人版修仙微电影',
                  'pic': '//i0.hdslb.com/r.jpg',
                  'author': '影视UP',
                  'duration': '22:00',
                  'play': 400000,
                  'danmaku': 700,
                  'typename': '影视剪辑',
                  'typeid': 183,
                  'tag': '真人版,AI真人',
                  'pubdate': now - 3600,
                },
                {
                  'bvid': 'BV1CleanAiAnime',
                  'title': 'AI动画：修仙大佬重回都市 一口气看完',
                  'pic': '//i0.hdslb.com/clean.jpg',
                  'author': '动画工坊',
                  'duration': '68:00',
                  'play': 120000,
                  'danmaku': 500,
                  'typename': '短片·手书',
                  'typeid': 47,
                  'tag': 'AI动画,一口气看完,修仙',
                  'pubdate': now - 3600,
                },
              ],
            },
          };
        }
        return {'code': 0, 'data': {}};
      });

      final engine = BilibiliAssistantEngine(
        resolver: resolver,
        srtService: BilibiliSrtService(
          resolver: resolver,
          historyDocLoader: (_, _) async => null,
        ),
      );

      final res = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'ai_anime_1',
          name: 'search_bilibili_videos',
          args: {
            'queries_narrow_to_broad': ['AI漫剧 修仙'],
            'content_focus': 'ai_anime',
            'min_duration_minutes': 60,
          },
        ),
      );

      expect(res.response['contentFocus'], 'ai_anime');
      expect(res.response['contentFilterSatisfied'], isTrue);
      expect(res.response['durationFilterSatisfied'], isTrue);
      expect(queriedTids, containsAll(['1', '167']));
      expect(queriedKeywords.any((k) => k.contains('AI动画')), isTrue);

      final cands = res.response['candidates'] as List<dynamic>;
      expect(cands, hasLength(1));
      final onlyCand = cands.first as Map;
      expect(onlyCand['bvid'], 'BV1CleanAiAnime');
      expect(onlyCand['tags'], contains('AI动画'));

      // Fallback prompt in Vietnamese also activates clean AI anime focus
      final fbReport = await engine.autoSearchFallbackFromPrompt(
        'Tìm phim hoạt hình AI tu tiên dài trên 1 tiếng',
      );
      expect(fbReport, isNotNull);
      expect(fbReport!.candidates.map((c) => c.bvid), ['BV1CleanAiAnime']);

      // Controller aiAnimeOnly lock updates engine locks, header & resetFilters
      SharedPreferences.setMockInitialValues({});
      final controller = BilibiliAssistantController(
        resolver: resolver,
        liveClient: _FakeLiveClient(),
        micRecorder: _FakeMicRecorder(),
        audioOutput: _FakeAudioOutput(),
      );
      controller.setAiAnimeOnly(true);
      expect(controller.aiAnimeOnly, isTrue);
      expect(controller.engine.currentLocks.aiAnimeOnly, isTrue);
      expect(
        controller.engine.buildUiContextHeader(),
        contains('Chỉ Phim Hoạt Hình AI'),
      );
      controller.resetFilters();
      expect(controller.aiAnimeOnly, isFalse);
      controller.dispose();
    });

    test('content_focus=ai_anime reports honest contentFilterSatisfied=false instead of returning noise when none pass', () async {
      final resolver = BilibiliResolver();
      resolver.dio.httpClientAdapter = _FakeHttpAdapter((options) {
        final path = options.uri.path;
        if (path == '/x/web-interface/nav') {
          return {
            'code': 0,
            'data': {
              'wbi_img': {
                'img_url':
                    'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
                'sub_url':
                    'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
              },
            },
          };
        }
        if (path.endsWith('/search/type')) {
          return {
            'code': 0,
            'data': {
              'result': [
                {
                  'bvid': 'BV1OnlyTut',
                  'title': 'AI漫剧制作教学 ComfyUI全流程',
                  'pic': '//i0.hdslb.com/t.jpg',
                  'author': 'UP',
                  'duration': '20:00',
                  'play': 10000,
                  'danmaku': 50,
                  'typename': '知识',
                  'typeid': 36,
                  'tag': '教程',
                },
              ],
            },
          };
        }
        return {'code': 0, 'data': {}};
      });

      final engine = BilibiliAssistantEngine(
        resolver: resolver,
        srtService: BilibiliSrtService(
          resolver: resolver,
          historyDocLoader: (_, _) async => null,
        ),
      );

      final res = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'ai_anime_empty',
          name: 'search_bilibili_videos',
          args: {
            'queries_narrow_to_broad': ['AI漫剧'],
            'content_focus': 'ai_anime',
          },
        ),
      );

      expect(res.response['contentFilterSatisfied'], isFalse);
      expect(res.response['returnedCount'], 0);
      expect(
        res.response['filterWarning'].toString(),
        contains('loại bỏ video kiến thức/hướng dẫn'),
      );
    });
  });

  group('Vietnamese -> Chinese title translation mode (Bilibili)', () {
    test('detects translate-only intents without false-positive on exact catalog search', () {
      expect(
        ChineseTitleSuggestionHelper.looksLikeChineseTitleOnlyRequest(
          'Mình mô tả phim nam chính trọng sinh báo thù, hãy gợi ý vài tên tiếng Trung để mình tự copy tìm, không đề xuất phim',
        ),
        isTrue,
      );
      expect(
        ChineseTitleSuggestionHelper.looksLikeChineseTitleOnlyRequest(
          'Chuyển đổi tên "Phàm nhân tu tiên" sang tiếng Trung để tự search',
        ),
        isTrue,
      );
      expect(
        ChineseTitleSuggestionHelper.looksLikeChineseTitleOnlyRequest(
          'Tìm đúng phim Phàm Nhân Tu Tiên bản gốc tiếng Trung mới nhất',
        ),
        isFalse,
      );
      expect(
        ChineseTitleSuggestionHelper.looksLikeChineseTitleOnlyRequest(
          'Đề xuất video Bilibili hợp gu hay xem',
        ),
        isFalse,
      );
    });

    test('engine exposes suggest_chinese_search_terms, executes locally with 0 HTTP calls, and blocks search when locked', () async {
      final declNames = BilibiliAssistantEngine.buildFunctionDeclarations()
          .map((d) => d['name'])
          .toList();
      expect(declNames, contains('suggest_chinese_search_terms'));

      final dio = Dio();
      final adapter = _FakeHttpAdapter((_) => {'code': 0, 'data': {}});
      dio.httpClientAdapter = adapter;
      final resolver = BilibiliResolver(dio: dio);
      final engine = BilibiliAssistantEngine(
        resolver: resolver,
        srtService: BilibiliSrtService(
          resolver: resolver,
          historyDocLoader: (_, _) async => null,
        ),
      );

      ChineseTitleSuggestionBatch? capturedBatch;
      final suggestRes = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'cn_1',
          name: 'suggest_chinese_search_terms',
          args: {
            'vi_input_summary': 'nam chính trọng sinh giả làm ăn mày báo thù',
            'suggestions': [
              {
                'zh_title': '重生乞丐复仇记',
                'han_viet_meaning': 'Trọng Sinh Khất Cái Phục Thù Ký',
                'match_type': 'literal_han_viet',
                'note': 'Dùng khi tìm bản dựng cốt truyện',
              },
              {
                'zh_title': '重生之乞丐逆袭',
                'han_viet_meaning': 'Trọng Sinh Chi Khất Cái Nghịch Tập',
                'match_type': 'synonym_variant',
              },
            ],
          },
        ),
        onSuggestionsUpdated: (b) => capturedBatch = b,
      );

      expect(suggestRes.response['ok'], isTrue);
      expect(suggestRes.response['count'], 2);
      expect(capturedBatch, isNotNull);
      expect(capturedBatch!.suggestions.first.zhTitle, '重生乞丐复仇记');
      expect(adapter.requests, isEmpty);

      // Natural request should suppress looksLikeDiscoveryQuery & autoSearchFallbackFromPrompt
      const naturalPrompt =
          'Mình mô tả phim: "tiên tôn trọng sinh về làm rể", chỉ xin tên tiếng Trung để tự copy tìm, không cần đề xuất phim.';
      expect(
        BilibiliAssistantEngine.looksLikeDiscoveryQuery(naturalPrompt),
        isFalse,
      );
      expect(
        await engine.autoSearchFallbackFromPrompt(naturalPrompt),
        isNull,
      );
      expect(engine.decorateUserInput(naturalPrompt), contains('suggest_chinese_search_terms'));

      // Explicit lock blocks search tools and returns null from fallback
      engine.updateUiLocks(const BilibiliUiLocks(titleTranslateOnly: true));
      expect(engine.buildUiContextHeader(), contains('Chỉ chuyển tên Việt -> Trung'));
      expect(
        await engine.autoSearchFallbackFromPrompt('Đề xuất phim hoạt hình AI'),
        isNull,
      );
      final blockedRes = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'blk_1',
          name: 'search_bilibili_videos',
          args: {'queries_narrow_to_broad': ['AI动画']},
        ),
      );
      expect(blockedRes.response['ok'], isFalse);
      expect(blockedRes.response['blocked'], isTrue);
      expect(adapter.requests, isEmpty);
    });

    test('controller attaches copyable titleSuggestions without forcing video cards on turn completion', () async {
      SharedPreferences.setMockInitialValues({
        'gemini_api_keys': ['AIzaSyFakeKeyBiliTranslateTest'],
      });
      final dio = Dio();
      final adapter = _FakeHttpAdapter((_) => {'code': 0, 'data': {}});
      dio.httpClientAdapter = adapter;
      final resolver = BilibiliResolver(dio: dio);
      final liveClient = _EventFakeBiliLiveClient();

      final controller = BilibiliAssistantController(
        resolver: resolver,
        srtService: BilibiliSrtService(
          resolver: resolver,
          historyDocLoader: (_, _) async => null,
        ),
        liveClient: liveClient,
        micRecorder: _FakeMicRecorder(),
        audioOutput: _FakeAudioOutput(),
      );
      await controller.initialize();
      controller.setTitleTranslateOnly(true);
      expect(controller.engine.currentLocks.titleTranslateOnly, isTrue);

      await controller.sendTextMessage(
        'Nam chính trọng sinh giả làm ăn mày để báo thù gia tộc',
      );
      expect(
        liveClient.sentTexts.last,
        contains('CHỈ CHUYỂN TÊN VIỆT → TRUNG'),
      );

      liveClient.emit(
        const LiveToolCallEvent([
          LiveFunctionCall(
            id: 'call_cn_bili',
            name: 'suggest_chinese_search_terms',
            args: {
              'vi_input_summary': 'nam chính trọng sinh giả làm ăn mày báo thù',
              'suggestions': [
                {
                  'zh_title': '重生当乞丐复仇',
                  'han_viet_meaning': 'Trọng Sinh Đương Khất Cái Phục Thù',
                  'match_type': 'exact_title',
                },
              ],
            },
          ),
        ]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));

      liveClient.emit(
        const LiveOutputTextEvent(
          'Bạn có thể copy cụm `重生当乞丐复仇` để tự tìm trên Bilibili.',
        ),
      );
      liveClient.emit(
        const LiveTurnCompleteEvent(interactionStatus: 'IDLE'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final assistantMsgs = controller.messages
          .where((m) => !m.isUser && !m.isSystemNotice)
          .toList();
      expect(assistantMsgs.length, 1);
      expect(assistantMsgs.single.searchReport, isNull);
      expect(assistantMsgs.single.titleSuggestions, isNotNull);
      expect(
        assistantMsgs.single.titleSuggestions!.suggestions.single.zhTitle,
        '重生当乞丐复仇',
      );
      expect(adapter.requests, isEmpty);

      controller.dispose();
    });
  });
}

class _EventFakeBiliLiveClient extends _FakeLiveClient {
  final StreamController<GeminiLiveEvent> _controller =
      StreamController<GeminiLiveEvent>.broadcast();
  final List<List<LiveFunctionResponse>> sentResponses = [];

  @override
  Stream<GeminiLiveEvent> get events => _controller.stream;

  void emit(GeminiLiveEvent event) => _controller.add(event);

  @override
  Future<LiveConnectionDiagnostics> connect({
    required List<String> apiKeys,
    required String modelId,
    required String systemPrompt,
    required List<Map<String, dynamic>> functionDeclarations,
    String? resumptionHandle,
    String voiceName = 'Aoede',
    bool forceRefreshModelDiscovery = false,
  }) async {
    connected = true;
    final diag = LiveConnectionDiagnostics(
      success: true,
      requestedModelId: modelId,
      resolvedModelId: modelId,
      apiVersion: 'v1beta',
      setupProfile: LiveSetupProfile.full,
      maskedKey: 'AIza...test',
      apiKeyCount: apiKeys.length,
      latencyMs: 12,
      availableBidiModels: [modelId],
      summaryMessage: 'OK',
      attemptLogs: const ['OK'],
      checkedAt: DateTime.now(),
    );
    _controller.add(LiveSetupCompleteEvent(modelId, apiVersion: 'v1beta'));
    return diag;
  }

  @override
  void sendToolResponses(List<LiveFunctionResponse> responses) {
    sentResponses.add(responses);
  }

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}

class _TempExportableSrtService extends BilibiliSrtService {
  final Directory exportDir;

  _TempExportableSrtService({
    required this.exportDir,
    required super.resolver,
    super.historyDocLoader,
    super.sttDocExtractor,
  });

  @override
  Future<File> exportSrtFile(BilibiliSrtSession session) async {
    final file = File(
      '${exportDir.path}${Platform.pathSeparator}bili_${session.bvid}_p${session.pageIndex}.srt',
    );
    await file.writeAsString(
      session.document.toSrtString('original'),
      flush: true,
    );
    return file;
  }
}
