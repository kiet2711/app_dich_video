import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:capsub_flutter/domain/ai/live/gemini_live_client.dart';
import 'package:capsub_flutter/domain/ai/live/live_audio_io.dart';
import 'package:capsub_flutter/domain/media/chinese_title_suggestion.dart';
import 'package:capsub_flutter/domain/media/hongguo/hongguo_assistant_engine.dart';
import 'package:capsub_flutter/domain/media/hongguo_resolver.dart';
import 'package:capsub_flutter/ui/hongguo/hongguo_assistant_controller.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) handler;

  _MockAdapter(this.handler);

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
  group('LiveAudioIo buildWavFromPcmBytes', () {
    test('builds valid 44-byte RIFF/WAVE header + PCM data', () {
      final pcm = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);
      final wav = buildWavFromPcmBytes(pcm, sampleRate: 24000);

      expect(wav.length, 48);
      expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
      expect(ascii.decode(wav.sublist(8, 12)), 'WAVE');
      expect(ascii.decode(wav.sublist(12, 16)), 'fmt ');
      expect(ascii.decode(wav.sublist(36, 40)), 'data');

      final bd = ByteData.sublistView(wav);
      expect(bd.getUint32(24, Endian.little), 24000);
      expect(bd.getUint32(40, Endian.little), 4);
      expect(wav.sublist(44), [0x01, 0x02, 0x03, 0x04]);
    });
  });

  group('GeminiLiveClient', () {
    test('matchPreferredBidiModel selects actual bidiGenerateContent model IDs', () {
      expect(
        GeminiLiveClient.matchPreferredBidiModel(
          'gemini-3.8-live',
          ['gemini-2.5-flash', 'gemini-3.8-live-preview'],
        ),
        'gemini-3.8-live-preview',
      );
      expect(
        GeminiLiveClient.matchPreferredBidiModel(
          'gemini-3.8-live-extended-thinking',
          ['gemini-3.8-live', 'gemini-3.8-live-extended-thinking-preview'],
        ),
        'gemini-3.8-live-extended-thinking-preview',
      );
      expect(
        GeminiLiveClient.matchPreferredBidiModel(
          'gemini-3.1-flash-live-preview',
          ['gemini-3.9-flash-live-exp'],
        ),
        'gemini-3.9-flash-live-exp',
      );
    });

    test('buildSetupPayload sets AUDIO modality, dual transcription, compression & resumption', () {
      final payload = GeminiLiveClient.buildSetupPayload(
        modelId: 'gemini-3.8-live',
        systemPrompt: 'System',
        functionDeclarations: [
          {'name': 'progressive_search'},
        ],
        resumptionHandle: 'handle-abc',
      );

      final setup = payload['setup'] as Map<String, dynamic>;
      expect(setup['model'], 'models/gemini-3.8-live');
      expect(
        (setup['generationConfig'] as Map)['responseModalities'],
        ['AUDIO'],
      );
      expect(setup.containsKey('inputAudioTranscription'), isTrue);
      expect(setup.containsKey('outputAudioTranscription'), isTrue);
      expect(setup.containsKey('contextWindowCompression'), isTrue);
      expect((setup['sessionResumption'] as Map)['handle'], 'handle-abc');
    });

    test('handleDecodedServerJson emits events and skips thought=true parts', () async {
      final client = GeminiLiveClient();
      final emitted = <GeminiLiveEvent>[];
      final sub = client.events.listen(emitted.add);

      client.handleDecodedServerJson({'setupComplete': {}}, modelId: 'gemini-3.8-live');
      client.handleDecodedServerJson({
        'sessionResumptionUpdate': {'newHandle': 'resume-999', 'resumable': true},
      });
      client.handleDecodedServerJson({
        'goAway': {'timeLeft': '30s'},
      });
      client.handleDecodedServerJson({
        'toolCall': {
          'functionCalls': [
            {
              'id': 'call-1',
              'name': 'get_rankings',
              'args': {'board': 'prestige-drama', 'limit': 5},
            },
          ],
        },
      });
      client.handleDecodedServerJson({
        'serverContent': {
          'outputTranscription': {'text': 'Mình tìm thấy 5 phim', 'finished': true},
          'modelTurn': {
            'parts': [
              {'text': 'Internal thinking steps...', 'thought': true},
              {'text': 'Gợi ý xong rồi.'},
              {
                'inlineData': {
                  'mimeType': 'audio/pcm;rate=24000',
                  'data': base64Encode([10, 20, 30]),
                },
              },
            ],
          },
          'turnComplete': true,
        },
      });

      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      await client.dispose();

      expect(emitted.whereType<LiveSetupCompleteEvent>().single.resolvedModelId, 'gemini-3.8-live');
      expect(emitted.whereType<LiveSessionResumptionEvent>().single.handle, 'resume-999');
      expect(emitted.whereType<LiveGoAwayEvent>().single.timeLeft, '30s');
      expect(emitted.whereType<LiveToolCallEvent>().single.calls.first.name, 'get_rankings');
      expect(emitted.whereType<LiveOutputTranscriptEvent>().single.text, 'Mình tìm thấy 5 phim');
      // thought: true bị bỏ qua, chỉ nhận text thật "Gợi ý xong rồi."
      final textEvents = emitted.whereType<LiveOutputTextEvent>().toList();
      expect(textEvents.length, 1);
      expect(textEvents.first.text, 'Gợi ý xong rồi.');
      expect(emitted.whereType<LiveOutputAudioEvent>().single.pcmBytes, [10, 20, 30]);
      expect(emitted.whereType<LiveTurnCompleteEvent>(), isNotEmpty);
    });
  });

  group('HongguoAssistantEngine Tool Guard & Hybrid Ranking', () {
    test('Tool Guard repairs slugs across real/comic/AI sources accurately', () {
      final aiYouth = HongguoAssistantEngine.guardGenreForSource(
        'youth',
        'category/ai-drama',
      );
      expect(aiYouth.validSlug, 'drama');
      expect(aiYouth.fallbackKeywordZh, '校园');
      expect(aiYouth.guardNote, isNotNull);

      final realWealthy = HongguoAssistantEngine.guardGenreForSource(
        'wealthy-family',
        'category/real-drama',
      );
      expect(realWealthy.validSlug, 'clan');

      final aiClan = HongguoAssistantEngine.guardGenreForSource(
        'clan',
        'category/ai-drama',
      );
      expect(aiClan.validSlug, 'wealthy-family');

      expect(
        HongguoAssistantEngine.normalizeRankBoard('Điểm cao uy tín'),
        'rank/prestige-drama',
      );
      expect(
        HongguoAssistantEngine.normalizeRankBoard('hot-ai-drama'),
        'rank/hot-ai-drama',
      );
    });

    test('rankHybridPool rewards Narrow hits + intersection and filters conflicting sources (Option A)', () {
      const narrowConfirmed = HongguoDramaItem(
        seriesId: '101',
        title: '校园甜宠大女主',
        cover: '',
        episodeCount: 80,
        tags: ['青春', '甜宠'],
        intro: 'Học đường nữ cường ngọt ngào',
        sourceCategory: 'category/real-drama',
      );
      const broadUnverified = HongguoDramaItem(
        seriesId: '102',
        title: '甜宠微短剧',
        cover: '',
        episodeCount: 60,
        tags: ['甜宠'],
      );
      const conflictingAi = HongguoDramaItem(
        seriesId: '103',
        title: '校园AI恋人',
        cover: '',
        episodeCount: 40,
        tags: ['AI剧', '科幻'],
        sourceCategory: 'category/ai-drama',
      );

      final ranked = HongguoAssistantEngine.rankHybridPool(
        searchTiers: [
          (tier: 0, query: '校园 甜宠', items: [narrowConfirmed]),
          (tier: 2, query: '甜宠', items: [narrowConfirmed, broadUnverified, conflictingAi]),
        ],
        browseItems: [narrowConfirmed],
        verifiedSourceIds: {'101'},
        expectedSourceCategory: 'category/real-drama',
        targetKeywords: ['校园', '甜宠'],
      );

      // Conflicting AI item must be excluded when real-drama is requested
      expect(ranked.map((e) => e.seriesId), ['101', '102']);
      expect(ranked.first.sourceConfidence, HongguoSourceConfidence.confirmed);
      expect(ranked[1].sourceConfidence, HongguoSourceConfidence.keywordHybrid);
      expect(ranked[1].sourceBadge, '🔍 Từ khóa (chưa rõ nguồn)');
      expect(ranked.first.displayIndex, 1);
      expect(ranked[1].displayIndex, 2);
    });

    test('progressive_search, get_rankings & analyze_candidate_plots execute end-to-end with stub Dio', () async {
      const id1 = '7688352674999155001';
      const id2 = '7688352674999155002';
      const idAi = '7688352674999166001';
      final requestedPaths = <String>[];
      final dio = Dio();
      dio.httpClientAdapter = _MockAdapter((options) async {
        requestedPaths.add('${options.uri.path}?${options.uri.query}');
        if (options.uri.path == '/api/search/result') {
          final q = options.uri.queryParameters['query'] ?? '';
          final list = q.contains('校园 甜宠')
              ? [
                  {
                    'video_data': {
                      'series_id': id1,
                      'series_title': '校园最强甜宠',
                      'episode_cnt': 70,
                      'series_intro': 'Nữ chính học đường mạnh mẽ.',
                      'tags': ['青春', '甜宠'],
                    },
                  },
                ]
              : [
                  {
                    'video_data': {
                      'series_id': id1,
                      'series_title': '校园最强甜宠',
                      'episode_cnt': 70,
                      'series_intro': 'Nữ chính học đường mạnh mẽ.',
                      'tags': ['青春', '甜宠'],
                    },
                  },
                  {
                    'video_data': {
                      'series_id': id2,
                      'series_title': '校园日常',
                      'episode_cnt': 50,
                      'tags': ['青春'],
                    },
                  },
                ];
          return ResponseBody.fromString(
            jsonEncode({'searchList': list, 'pageNum': 1, 'totalPages': 1}),
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        }

        if (options.uri.path.startsWith('/player/')) {
          final playerPayload = {
            'loaderData': {
              'routes/player/page': {
                'seriesInfo': {
                  'seriesId': id2,
                  'seriesName': '校园日常',
                  'description': 'Cốt truyện chi tiết: Nữ chính quay về trường cũ đảo ngược số phận và yêu ngọt ngào.',
                  'episodeCount': 50,
                  'tags': ['青春'],
                },
                'episodeList': [
                  {'index': 1, 'vid': '9001', 'title': 'Tập 1'},
                ],
              },
            },
          };
          return ResponseBody.fromString(
            '<script>window._ROUTER_DATA = ${jsonEncode(playerPayload)};</script>',
            200,
            headers: {
              Headers.contentTypeHeader: ['text/html; charset=utf-8'],
            },
          );
        }

        if (options.uri.path.contains('/rank/hot-ai-drama')) {
          final rankPayload = {
            'loaderData': {
              'routes/rank/page': {
                'rankList': [
                  {
                    'seriesId': idAi,
                    'seriesName': 'AI星际霸主',
                    'episodeCount': 88,
                    'rank': 1,
                    'primaryMetricText': '9000万热度',
                    'tags': ['AI剧', '科幻'],
                  },
                ],
              },
            },
          };
          return ResponseBody.fromString(
            '<script>window._ROUTER_DATA = ${jsonEncode(rankPayload)};</script>',
            200,
            headers: {
              Headers.contentTypeHeader: ['text/html; charset=utf-8'],
            },
          );
        }

        final htmlPayload = {
          'loaderData': {
            'routes/page': {
              'dramaList': [
                {
                  'seriesId': id1,
                  'seriesName': '校园最强甜宠',
                  'episodeCount': 70,
                  'tags': ['青春', '甜宠'],
                },
              ],
            },
          },
        };
        return ResponseBody.fromString(
          '<script>window._ROUTER_DATA = ${jsonEncode(htmlPayload)};</script>',
          200,
          headers: {
            Headers.contentTypeHeader: ['text/html; charset=utf-8'],
          },
        );
      });

      final engine = HongguoAssistantEngine(
        resolver: HongguoResolver(dio: dio),
        translateTitle: (zh) async => 'VI($zh)',
      );

      engine.updateUiLocks(
        const HongguoUiLocks(
          sourceCategory: 'category/real-drama',
          lockedCount: 2,
        ),
      );

      final searchResp = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 't1',
          name: 'progressive_search',
          args: {
            'queries_narrow_to_broad': ['校园 甜宠', '校园'],
            'target_zh_keywords': ['校园', '甜宠'],
            'source_type': 'real-drama',
            'genre_slug': 'youth',
            'limit': 10,
          },
        ),
      );

      // UI lock = 2 phải giữ số lượng trả về <= 2
      expect(searchResp.response['returnedCount'], 2);
      expect(engine.lastDisplayedCandidates.first.viTitle, 'VI(校园最强甜宠)');
      expect(engine.lastSearchReport?.traceSummary, contains('校园 甜宠'));

      // Pin candidate #1 và kiểm tra decorateUserInput + analyze_candidate_plots
      engine.updateUiLocks(
        const HongguoUiLocks(
          sourceCategory: 'category/ai-drama',
          lockedCount: 1,
          pinnedSeriesIds: [id1],
        ),
      );

      final decorated = engine.decorateUserInput('tổng hợp phim đang ghim');
      expect(decorated, contains('seriesId=$id1'));
      expect(decorated, contains('VI(校园最强甜宠)'));

      final analyzeResp = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 't2',
          name: 'analyze_candidate_plots',
          args: {
            'user_criteria': 'nữ chính học đường mạnh mẽ',
            'indices': [1, 2],
          },
        ),
      );
      expect(analyzeResp.response['analyzedCount'], 2);
      final candidatesJson = (analyzeResp.response['candidates'] as List)
          .cast<Map<dynamic, dynamic>>();
      final byId = {
        for (final c in candidatesJson) c['seriesId'].toString(): c,
      };
      // #1 đã có sẵn intro từ search -> giữ nguyên không cần gọi lại /player/
      expect(byId[id1]?['intro'], 'Nữ chính học đường mạnh mẽ.');
      // #2 chưa có intro từ search -> tự enrich qua /player/7688352674999155002
      expect(byId[id2]?['intro'], contains('Cốt truyện chi tiết'));
      expect(requestedPaths.any((p) => p.contains('/player/$id2')), isTrue);
      expect(requestedPaths.any((p) => p.contains('/player/$id1')), isFalse);

      // get_rankings với UI khóa AI trên board 'hot-drama' tự chuyển sang 'rank/hot-ai-drama'
      final rankResp = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 't3',
          name: 'get_rankings',
          args: {'board': 'hot-drama', 'limit': 5},
        ),
      );
      expect(rankResp.response['board'], 'rank/hot-ai-drama');
      expect(rankResp.response['returnedCount'], 1);

      // Snapshot context preservation
      final snapshot = engine.buildCompressedSnapshotTurns([
        (isUser: true, text: 'Tìm phim AI'),
        (isUser: false, text: '#1 VI(AI星际霸主)'),
      ]);
      expect(snapshot.length, 4);
      expect(
        (snapshot.first['parts'] as List).first['text'],
        contains('id=$idAi'),
      );
    });

    test('empty search falls back to Hongguo browse catalog & caps slow translation timeout', () async {
      final dio = Dio();
      dio.httpClientAdapter = _MockAdapter((options) async {
        if (options.uri.path.contains('/api/search/result')) {
          return ResponseBody.fromString(
            jsonEncode({'searchList': <dynamic>[], 'pageNum': 1, 'totalPages': 0}),
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        }
        final htmlPayload = {
          'loaderData': {
            'routes/page': {
              'dramaList': [
                {
                  'seriesId': '7688352674999159991',
                  'seriesName': '热播宫廷甜宠',
                  'cover': 'https://p6-novel.byteimg.com/novel-pic/fallback_cover.jpeg',
                  'episodeCount': 66,
                  'tags': ['古装', '甜宠'],
                },
              ],
            },
          },
        };
        return ResponseBody.fromString(
          '<script>window._ROUTER_DATA = ${jsonEncode(htmlPayload)};</script>',
          200,
          headers: {
            Headers.contentTypeHeader: ['text/html; charset=utf-8'],
          },
        );
      });

      final engine = HongguoAssistantEngine(
        resolver: HongguoResolver(dio: dio),
        // Mô phỏng MLKit treo 5 giây -> engine phải cắt timeout <= 1.8s để hiện thẻ + ảnh bìa ngay
        translateTitle: (zh) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return 'NEVER';
        },
      );

      final sw = Stopwatch()..start();
      final resp = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 't-empty',
          name: 'progressive_search',
          args: {
            'queries_narrow_to_broad': ['不存在的电影'],
            'source_type': 'all',
            'limit': 5,
          },
        ),
      );
      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(3500));
      expect(resp.response['returnedCount'], 1);
      expect(engine.lastDisplayedCandidates.single.item.cover, contains('fallback_cover.jpeg'));
      expect(engine.lastDisplayedCandidates.single.viTitle, '热播宫廷甜宠');
    });

    test('looksLikeMovieDiscoveryQuery distinguishes new searches from #N follow-ups & autoSearchFallbackFromPrompt populates covers', () async {
      expect(HongguoAssistantEngine.looksLikeMovieDiscoveryQuery('Tìm phim học đường ngọt sủng'), isTrue);
      expect(HongguoAssistantEngine.looksLikeMovieDiscoveryQuery('Gợi ý cho mình vài bộ hay'), isTrue);
      expect(HongguoAssistantEngine.looksLikeMovieDiscoveryQuery('Tóm tắt phim số 2'), isFalse);
      expect(
        HongguoAssistantEngine.looksLikeMovieDiscoveryQuery(
          'Hãy tổng hợp và so sánh hết cốt truyện của toàn bộ danh sách phim vừa rồi',
        ),
        isFalse,
      );

      final dio = Dio();
      dio.httpClientAdapter = _MockAdapter((options) async {
        if (options.uri.path.contains('/api/search/result')) {
          return ResponseBody.fromString(
            jsonEncode({
              'searchList': [
                {
                  'video_data': {
                    'series_id': '7688352674999158881',
                    'series_title': '校园微甜恋爱',
                    'series_cover': 'https://p6-novel.byteimg.com/novel-pic/fb_search_cover.jpeg',
                    'episode_cnt': 60,
                    'tags': ['校园', '甜宠'],
                  },
                },
              ],
              'pageNum': 1,
              'totalPages': 1,
            }),
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        }
        final htmlPayload = {
          'loaderData': {
            'routes/page': {'dramaList': <dynamic>[]},
          },
        };
        return ResponseBody.fromString(
          '<script>window._ROUTER_DATA = ${jsonEncode(htmlPayload)};</script>',
          200,
          headers: {
            Headers.contentTypeHeader: ['text/html; charset=utf-8'],
          },
        );
      });

      final engine = HongguoAssistantEngine(
        resolver: HongguoResolver(dio: dio),
        translateTitle: (zh) async => 'Yêu Ngọt Học Đường',
      );

      final report = await engine.autoSearchFallbackFromPrompt('Tìm giúp mình phim học đường ngọt sủng');
      expect(report, isNotNull);
      expect(report!.candidates.length, 1);
      expect(report.candidates.single.viTitle, 'Yêu Ngọt Học Đường');
      expect(report.candidates.single.item.cover, contains('fb_search_cover.jpeg'));
    });

    test('extractAiTitlesFromLiveReply parses #N Hán Việt titles cleanly and enforces Hán Việt prompt rules', () {
      final prompt = HongguoAssistantEngine.buildSystemPrompt();
      expect(prompt, contains('HÁN VIỆT'));
      expect(prompt, contains('CẤM'));
      expect(prompt.toLowerCase(), contains('pinyin'));

      const sampleReply = '''
Đây là 4 phim khớp nhất:
#1. Hoa Khôi Học Đường Bá Đạo (Tên gốc: 校园最强甜宠) — Cô nàng Lâm Vãn âm thầm bảo vệ bạn thân.
**#2: Tổng Tài Thẩm Yến Xin Tự Trọng** — Cuộc hôn nhân hợp đồng giữa Cố Thanh và Thẩm Yến.
Phim số ba: Trọng Sinh Báo Thù Nhà Họ Lục — Tô Khê quay lại lật ngược ván cờ.
Số 4: Ngọt Sủng Trường Học — Câu chuyện thanh xuân nhẹ nhàng.
''';
      final extracted = HongguoAssistantEngine.extractAiTitlesFromLiveReply(
        sampleReply,
        isFinal: true,
      );
      expect(extracted[1], 'Hoa Khôi Học Đường Bá Đạo');
      expect(extracted[2], 'Tổng Tài Thẩm Yến Xin Tự Trọng');
      expect(extracted[3], 'Trọng Sinh Báo Thù Nhà Họ Lục');
      expect(extracted[4], 'Ngọt Sủng Trường Học');

      // Khi đang stream dở chưa có dấu ngắt câu/dấu gạch ngang thì không vội chốt #5 cụt
      final streamingPartial = HongguoAssistantEngine.extractAiTitlesFromLiveReply(
        '#1. Hoa Khôi Học Đường — hay\n#5. Đang gõ dở',
        isFinal: false,
      );
      expect(streamingPartial[1], 'Hoa Khôi Học Đường');
      expect(streamingPartial.containsKey(5), isFalse);
    });
  });

  group('GeminiLiveClient setup profiles, URLs & pre-setup guard', () {
    test('wsUrlForVersion and maskApiKey work cleanly', () {
      expect(
        GeminiLiveClient.wsUrlForVersion('v1alpha'),
        GeminiLiveClient.wsAlphaBaseUrl,
      );
      expect(
        GeminiLiveClient.wsUrlForVersion('v1beta'),
        GeminiLiveClient.wsBetaBaseUrl,
      );
      expect(
        GeminiLiveClient.maskApiKey('AIzaSyAbCdEfGhIjKlMnOpQr1234'),
        'AIzaSy...1234',
      );
      expect(GeminiLiveClient.maskApiKey(''), '(trống)');
    });

    test('buildSetupPayload differentiates full/compatible/minimal and extended-thinking', () {
      final decls = HongguoAssistantEngine.buildFunctionDeclarations(
        includeNonBlockingBehavior: true,
      );
      final extFull = GeminiLiveClient.buildSetupPayload(
        modelId: 'gemini-3.8-live-extended-thinking',
        systemPrompt: 'Sys',
        functionDeclarations: decls,
        profile: LiveSetupProfile.full,
        includeNonBlockingBehavior: true,
      );
      final setupFull = extFull['setup'] as Map<String, dynamic>;
      expect(setupFull['thinkingConfig'], {'thinkingLevel': 'low'});
      expect(
        ((setupFull['contextWindowCompression'] as Map)['slidingWindow'] as Map)['targetTokens'],
        16384,
      );
      final toolDecls =
          ((setupFull['tools'] as List).first as Map)['functionDeclarations'] as List;
      expect((toolDecls.first as Map)['behavior'], 'NON_BLOCKING');

      final compat = GeminiLiveClient.buildSetupPayload(
        modelId: 'gemini-3.8-live',
        systemPrompt: 'Sys',
        functionDeclarations: decls,
        profile: LiveSetupProfile.compatible,
        includeNonBlockingBehavior: false,
      )['setup'] as Map<String, dynamic>;
      expect(compat.containsKey('thinkingConfig'), isFalse);
      expect(compat.containsKey('contextWindowCompression'), isFalse);
      expect(compat.containsKey('inputAudioTranscription'), isTrue);

      final minimal = GeminiLiveClient.buildSetupPayload(
        modelId: 'gemini-3.8-live',
        systemPrompt: 'Sys',
        functionDeclarations: decls,
        profile: LiveSetupProfile.minimal,
      )['setup'] as Map<String, dynamic>;
      expect(minimal.containsKey('inputAudioTranscription'), isFalse);
      expect(minimal.containsKey('sessionResumption'), isFalse);
      expect((minimal['generationConfig'] as Map).containsKey('speechConfig'), isFalse);
    });

    test('genre_slug enum in buildFunctionDeclarations has no empty string', () {
      final decls = HongguoAssistantEngine.buildFunctionDeclarations();
      for (final d in decls) {
        final props =
            (d['parameters'] as Map)['properties'] as Map<String, dynamic>;
        final genre = props['genre_slug'];
        if (genre is Map && genre['enum'] is List) {
          final values = (genre['enum'] as List).cast<String>();
          expect(values, isNot(contains('')));
        }
      }
    });

    test('handleDecodedServerJson suppresses LiveErrorEvent before setupComplete and emits apiVersion on setupComplete', () async {
      final client = GeminiLiveClient();
      final emitted = <GeminiLiveEvent>[];
      final sub = client.events.listen(emitted.add);

      client.handleDecodedServerJson({
        'error': {'message': 'Pre-setup unsupported field'},
      }, apiVersion: 'v1alpha');
      await Future<void>.delayed(Duration.zero);
      expect(emitted.whereType<LiveErrorEvent>(), isEmpty);

      client.handleDecodedServerJson(
        {'setupComplete': {}},
        modelId: 'gemini-3.8-live-extended-thinking',
        apiVersion: 'v1alpha',
      );
      client.handleDecodedServerJson({
        'error': {'message': 'Mid-session error'},
      });
      await Future<void>.delayed(Duration.zero);

      final setupEvt = emitted.whereType<LiveSetupCompleteEvent>().single;
      expect(setupEvt.apiVersion, 'v1alpha');
      expect(setupEvt.resolvedModelId, 'gemini-3.8-live-extended-thinking');
      expect(emitted.whereType<LiveErrorEvent>().single.message, 'Mid-session error');

      await sub.cancel();
      await client.dispose();
    });

    test('handleDecodedServerJson parses modelTurn.parts functionCall and interactionStatus', () async {
      final client = GeminiLiveClient();
      final emitted = <GeminiLiveEvent>[];
      final sub = client.events.listen(emitted.add);

      client.handleDecodedServerJson({'setupComplete': {}}, modelId: 'gemini-3.8-live-extended-thinking');
      client.handleDecodedServerJson({
        'serverContent': {
          'interactionStatus': 'IN_PROGRESS',
          'modelTurn': {
            'parts': [
              {
                'functionCall': {
                  'id': 'call_mt_1',
                  'name': 'progressive_search',
                  'args': '{"queries_narrow_to_broad":["校园"],"limit":3}',
                },
              },
              {'text': 'Đang tìm phim cho bạn...'},
            ],
          },
          'generationComplete': true,
        },
      });
      await Future<void>.delayed(Duration.zero);

      final toolEvt = emitted.whereType<LiveToolCallEvent>().single;
      expect(toolEvt.calls.single.id, 'call_mt_1');
      expect(toolEvt.calls.single.name, 'progressive_search');
      expect(toolEvt.calls.single.args['limit'], 3);

      final turnEvt = emitted.whereType<LiveTurnCompleteEvent>().single;
      expect(turnEvt.interactionStatus, 'IN_PROGRESS');
      expect(turnEvt.isGenerationOnly, isTrue);

      await sub.cancel();
      await client.dispose();
    });
  });

  group('HongguoAssistantController handshake & no blink loop', () {
    test('handles missing keys, quick key save, ensureConnected, and single non-looping reconnect on drop', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final secureStore = <String, String>{};
      const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = (call.arguments as Map?) ?? const {};
            final key = args['key']?.toString() ?? '';
            switch (call.method) {
              case 'read':
                return secureStore[key];
              case 'write':
                secureStore[key] = args['value']?.toString() ?? '';
                return null;
              case 'delete':
                secureStore.remove(key);
                return null;
              default:
                return null;
            }
          });

      final fakeClient = _FakeGeminiLiveClient();
      final controller = HongguoAssistantController(
        liveClient: fakeClient,
        audioOutput: _NoopAudioOutput(),
      );
      await controller.initialize();

      // 1. Không có key -> ensureConnected báo lỗi sạch, không gọi connect()
      final noKeyOk = await controller.ensureConnected();
      expect(noKeyOk, isFalse);
      expect(controller.connectionState, AssistantConnectionState.error);
      expect(fakeClient.connectCalls, 0);

      // 2. Lưu key nhanh -> ensureConnected thành công & giữ trạng thái Live
      await controller.saveQuickGeminiKeys('AIzaSyFakeKeyForTest9876');
      expect(controller.hasApiKeys, isTrue);
      expect(controller.apiKeyCount, 1);
      expect(controller.maskedActiveKey, 'AIzaSy...9876');

      final ok = await controller.ensureConnected();
      expect(ok, isTrue);
      expect(fakeClient.connectCalls, 1);
      expect(controller.connectionState, AssistantConnectionState.ready);
      expect(controller.isConnected, isTrue);
      expect(controller.resolvedApiVersion, 'v1beta');

      // 3. Gửi tin nhắn trên phiên Live -> không gọi reconnect dư
      await controller.sendTextMessage('Tìm giúp mình phim học đường');
      expect(fakeClient.sentClientTexts.length, 1);
      expect(fakeClient.connectCalls, 1);

      // 4. Giả lập phiên rớt đột ngột sau khi đã setup thành công, nhưng connect mới fail:
      // phải thử nối lại ĐÚNG 1 lần (1 -> 2), KHÔNG nháy vòng lặp vô hạn!
      fakeClient.failNextConnect = true;
      fakeClient.simulateUnexpectedDrop('timeout');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(fakeClient.connectCalls, 2);
      expect(controller.connectionState, AssistantConnectionState.error);

      // Nếu lại có event close khác khi chưa từng thiết lập lại phiên -> KHÔNG nối tiếp
      fakeClient.simulateUnexpectedDrop('second');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(fakeClient.connectCalls, 2);

      controller.dispose();
    });

    test('keeps poster cards attached across NON_BLOCKING intermediate IN_PROGRESS turns', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final secureStore = <String, String>{};
      const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = (call.arguments as Map?) ?? const {};
            final key = args['key']?.toString() ?? '';
            if (call.method == 'read') return secureStore[key];
            if (call.method == 'write') {
              secureStore[key] = args['value']?.toString() ?? '';
            }
            return null;
          });

      final dio = Dio();
      dio.httpClientAdapter = _MockAdapter((options) async {
        // Độ trễ 60ms để mô phỏng NON_BLOCKING turnComplete đến TRƯỚC khi tìm xong
        await Future<void>.delayed(const Duration(milliseconds: 60));
        if (options.uri.path.contains('/api/search/result')) {
          return ResponseBody.fromString(
            jsonEncode({
              'searchList': [
                {
                  'video_data': {
                    'series_id': '7688352674999157001',
                    'series_title': '甜宠校花',
                    'series_cover': 'https://p6-novel.byteimg.com/novel-pic/nonblocking_cover.jpeg',
                    'episode_cnt': 55,
                    'tags': ['校园', '甜宠'],
                  },
                },
              ],
              'pageNum': 1,
              'totalPages': 1,
            }),
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        }
        return ResponseBody.fromString(
          '<script>window._ROUTER_DATA = {"loaderData":{"routes/page":{"dramaList":[]}}};</script>',
          200,
          headers: {
            Headers.contentTypeHeader: ['text/html; charset=utf-8'],
          },
        );
      });

      final fakeClient = _FakeGeminiLiveClient();
      final controller = HongguoAssistantController(
        resolver: HongguoResolver(dio: dio),
        liveClient: fakeClient,
        audioOutput: _NoopAudioOutput(),
      );
      await controller.initialize();
      await controller.saveQuickGeminiKeys('AIzaSyFakeKeyForNonBlockingTest');
      await controller.sendTextMessage('Tìm phim học đường ngọt');

      // 1. Server gọi tool (NON_BLOCKING) nhưng gửi ngay generationComplete + IN_PROGRESS trước khi tool xong
      fakeClient.emitEvent(
        const LiveToolCallEvent([
          LiveFunctionCall(
            id: 'nb_1',
            name: 'progressive_search',
            args: {'queries_narrow_to_broad': ['校园'], 'limit': 3},
          ),
        ]),
      );
      fakeClient.emitEvent(const LiveOutputTranscriptEvent('Để mình tìm nhanh...', finished: true));
      fakeClient.emitEvent(
        const LiveTurnCompleteEvent(interactionStatus: 'IN_PROGRESS', isGenerationOnly: false),
      );

      // Chờ HTTP xong và tool response gửi ngược lại
      await Future<void>.delayed(const Duration(milliseconds: 140));
      expect(fakeClient.sentToolResponses.length, 1);

      // Server trả kết luận IDLE cuối cùng kèm định dạng #1 Hán Việt -> tự cập nhật tên thẻ không cần MLKit hay one-shot
      fakeClient.emitEvent(
        const LiveOutputTranscriptEvent(
          '\n#1. Hoa Khôi Học Đường Ngọt Sủng — Phim kể về Lâm Phàm và Thẩm Nhu.',
          finished: true,
        ),
      );
      fakeClient.emitEvent(const LiveTurnCompleteEvent(interactionStatus: 'IDLE'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final assistantMsgs = controller.messages.where((m) => !m.isUser && !m.isSystemNotice).toList();
      expect(assistantMsgs.length, 1);
      expect(assistantMsgs.single.searchReport, isNotNull);
      expect(assistantMsgs.single.searchReport!.candidates.single.viTitle, 'Hoa Khôi Học Đường Ngọt Sủng');
      expect(assistantMsgs.single.searchReport!.candidates.single.item.cover, contains('nonblocking_cover.jpeg'));
      expect(assistantMsgs.single.isStreaming, isFalse);
      expect(fakeClient.oneShotLiveCalls, 0);

      controller.dispose();
    });

    test('attaches Hongguo poster cards automatically if Gemini responds text without invoking tools', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final secureStore = <String, String>{};
      const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = (call.arguments as Map?) ?? const {};
            final key = args['key']?.toString() ?? '';
            if (call.method == 'read') return secureStore[key];
            if (call.method == 'write') {
              secureStore[key] = args['value']?.toString() ?? '';
            }
            return null;
          });

      final dio = Dio();
      dio.httpClientAdapter = _MockAdapter((options) async {
        if (options.uri.path.contains('/api/search/result')) {
          return ResponseBody.fromString(
            jsonEncode({
              'searchList': [
                {
                  'video_data': {
                    'series_id': '7688352674999157002',
                    'series_title': '古装甜宠王妃',
                    'series_cover': 'https://p6-novel.byteimg.com/novel-pic/autosafety_cover.jpeg',
                    'episode_cnt': 80,
                    'tags': ['古装', '甜宠'],
                  },
                },
              ],
              'pageNum': 1,
              'totalPages': 1,
            }),
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        }
        return ResponseBody.fromString(
          '<script>window._ROUTER_DATA = {"loaderData":{"routes/page":{"dramaList":[]}}};</script>',
          200,
          headers: {
            Headers.contentTypeHeader: ['text/html; charset=utf-8'],
          },
        );
      });

      final fakeClient = _FakeGeminiLiveClient();
      final controller = HongguoAssistantController(
        resolver: HongguoResolver(dio: dio),
        liveClient: fakeClient,
        audioOutput: _NoopAudioOutput(),
      );
      await controller.initialize();
      await controller.saveQuickGeminiKeys('AIzaSyFakeKeyForAutoFallbackTest');
      await controller.sendTextMessage('Gợi ý cho mình phim cổ trang ngọt sủng');

      // Model trả lời chay text tên phim + tóm tắt, KHÔNG gọi LiveToolCallEvent nào
      fakeClient.nextOneShotReply =
          '#1. Vương Phi Cổ Trang Ngọt Sủng — Câu chuyện về cô nàng Thẩm Nhu xuyên không gả cho vương gia Lục Thần.';
      fakeClient.emitEvent(const LiveOutputTextEvent('1. Phim cổ trang hay với cốt truyện ngọt ngào...'));
      fakeClient.emitEvent(const LiveTurnCompleteEvent(interactionStatus: 'IDLE'));
      await Future<void>.delayed(const Duration(milliseconds: 140));

      final assistantMsgs = controller.messages.where((m) => !m.isUser && !m.isSystemNotice).toList();
      expect(assistantMsgs.length, 1);
      expect(assistantMsgs.single.searchReport, isNotNull);
      expect(assistantMsgs.single.searchReport!.candidates.single.viTitle, 'Vương Phi Cổ Trang Ngọt Sủng');
      expect(assistantMsgs.single.searchReport!.candidates.single.item.cover, contains('autosafety_cover.jpeg'));
      expect(assistantMsgs.single.text, contains('Vương Phi Cổ Trang Ngọt Sủng'));
      expect(fakeClient.oneShotLiveCalls, 1);

      controller.dispose();
    });
  });

  group('Vietnamese -> Chinese title translation mode (Hongguo)', () {
    test('engine exposes suggest_chinese_search_terms and suppresses search & fallback in translate-only mode', () async {
      final declNames = HongguoAssistantEngine.buildFunctionDeclarations()
          .map((d) => d['name'])
          .toList();
      expect(declNames, contains('suggest_chinese_search_terms'));

      final requests = <RequestOptions>[];
      final dio = Dio();
      dio.httpClientAdapter = _MockAdapter((opts) async {
        requests.add(opts);
        return ResponseBody.fromString('{}', 200);
      });
      final engine = HongguoAssistantEngine(
        resolver: HongguoResolver(dio: dio),
      );

      ChineseTitleSuggestionBatch? capturedBatch;
      final res = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'hg_cn_1',
          name: 'suggest_chinese_search_terms',
          args: {
            'vi_input_summary': 'tổng tài giả nghèo cưới vợ thử lòng',
            'suggestions': [
              {
                'zh_title': '总裁装穷娶妻试探',
                'han_viet_meaning': 'Tổng Tài Trang Cùng Thú Thê Thí Thám',
                'match_type': 'literal_han_viet',
              },
              {
                'zh_title': '假装破产后老婆竟是首富',
                'han_viet_meaning': 'Giả Trang Phá Sản Hậu Lão Bà Cánh Thị Thủ Phú',
                'match_type': 'synonym_variant',
              },
            ],
          },
        ),
        onSuggestionsUpdated: (b) => capturedBatch = b,
      );

      expect(res.response['ok'], isTrue);
      expect(res.response['count'], 2);
      expect(capturedBatch!.suggestions.first.zhTitle, '总裁装穷娶妻试探');
      expect(requests, isEmpty);

      const naturalPrompt =
          'Mình mô tả phim: "nữ chính trọng sinh gả nhầm hào môn", cho mình tên tiếng Trung để tự copy tìm (không cần đề xuất phim).';
      expect(
        HongguoAssistantEngine.looksLikeMovieDiscoveryQuery(naturalPrompt),
        isFalse,
      );
      expect(
        await engine.autoSearchFallbackFromPrompt(naturalPrompt),
        isNull,
      );

      engine.updateUiLocks(const HongguoUiLocks(titleTranslateOnly: true));
      expect(engine.buildUiContextHeader(), contains('Chỉ chuyển tên Việt -> Trung'));
      expect(
        await engine.autoSearchFallbackFromPrompt('Gợi ý 5 phim tổng tài ngọt sủng'),
        isNull,
      );
      final blockedRes = await engine.executeToolCall(
        const LiveFunctionCall(
          id: 'hg_blk_1',
          name: 'progressive_search',
          args: {
            'queries_narrow_to_broad': ['总裁'],
          },
        ),
      );
      expect(blockedRes.response['ok'], isFalse);
      expect(blockedRes.response['blocked'], isTrue);
      expect(requests, isEmpty);
    });

    test('controller returns copyable Chinese suggestions without auto-fallback movie cards (both tool & text fallback)', () async {
      SharedPreferences.setMockInitialValues({});
      final requests = <RequestOptions>[];
      final dio = Dio();
      dio.httpClientAdapter = _MockAdapter((opts) async {
        requests.add(opts);
        return ResponseBody.fromString('<html></html>', 200);
      });

      final fakeClient = _FakeGeminiLiveClient();
      final controller = HongguoAssistantController(
        resolver: HongguoResolver(dio: dio),
        liveClient: fakeClient,
        audioOutput: _NoopAudioOutput(),
      );
      await controller.initialize();
      await controller.saveQuickGeminiKeys('AIzaSyFakeKeyForTranslateModeTest');

      // Case 1: Bật pill Tên Việt -> Trung và Gemini gọi suggest_chinese_search_terms
      controller.setTitleTranslateOnly(true);
      await controller.sendTextMessage(
        'Phim tổng tài giả nghèo cưới vợ thử lòng',
      );
      expect(
        fakeClient.sentClientTexts.last,
        contains('CHỈ CHUYỂN TÊN VIỆT → TRUNG'),
      );

      fakeClient.emitEvent(
        const LiveToolCallEvent([
          LiveFunctionCall(
            id: 'call_hg_cn',
            name: 'suggest_chinese_search_terms',
            args: {
              'vi_input_summary': 'tổng tài giả nghèo cưới vợ thử lòng',
              'suggestions': [
                {
                  'zh_title': '总裁装穷试婚',
                  'han_viet_meaning': 'Tổng Tài Trang Cùng Thí Hôn',
                  'match_type': 'exact_title',
                },
              ],
            },
          ),
        ]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
      fakeClient.emitEvent(
        const LiveOutputTextEvent('Gợi ý bạn copy tên `总裁装穷试婚` để tự tìm nhé.'),
      );
      fakeClient.emitEvent(const LiveTurnCompleteEvent(interactionStatus: 'IDLE'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      var assistantMsgs =
          controller.messages.where((m) => !m.isUser && !m.isSystemNotice).toList();
      expect(assistantMsgs.length, 1);
      expect(assistantMsgs.single.searchReport, isNull);
      expect(
        assistantMsgs.single.titleSuggestions?.suggestions.single.zhTitle,
        '总裁装穷试婚',
      );

      // Case 2: Tắt pill nhưng hỏi tự nhiên không đề xuất phim -> model trả text chay -> KHÔNG tự fallback tìm phim + tự tách cụm Hán Việt copy
      controller.setTitleTranslateOnly(false);
      await controller.sendTextMessage(
        'Mình mô tả phim ngắn: "nữ phụ trọng sinh trả thù tra nam", chỉ cần tên tiếng Trung để tự tìm không đề xuất phim',
      );
      fakeClient.emitEvent(
        const LiveOutputTextEvent(
          '1. 重生女配复仇记 — Trọng Sinh Nữ Phụ Phục Thù Ký\n'
          '2. 女配逆袭打脸渣男 — Nữ Phụ Nghịch Tập Đả Kiểm Tra Nam',
        ),
      );
      fakeClient.emitEvent(const LiveTurnCompleteEvent(interactionStatus: 'IDLE'));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      assistantMsgs =
          controller.messages.where((m) => !m.isUser && !m.isSystemNotice).toList();
      expect(assistantMsgs.length, 2);
      expect(assistantMsgs[1].searchReport, isNull);
      expect(assistantMsgs[1].titleSuggestions, isNotNull);
      expect(
        assistantMsgs[1].titleSuggestions!.suggestions.map((e) => e.zhTitle),
        containsAll(['重生女配复仇记', '女配逆袭打脸渣男']),
      );
      expect(requests, isEmpty);

      controller.dispose();
    });
  });
}

class _FakeGeminiLiveClient extends GeminiLiveClient {
  final StreamController<GeminiLiveEvent> _fakeEvents =
      StreamController<GeminiLiveEvent>.broadcast();

  int connectCalls = 0;
  bool failNextConnect = false;
  bool _fakeConnected = false;
  String _fakeKey = '';
  String _fakeModel = 'gemini-3.8-live';
  final String _fakeVersion = 'v1beta';
  LiveConnectionDiagnostics? _fakeDiag;
  final List<String> sentClientTexts = [];
  final List<List<LiveFunctionResponse>> sentToolResponses = [];
  int oneShotLiveCalls = 0;
  String nextOneShotReply = '';

  void emitEvent(GeminiLiveEvent event) => _fakeEvents.add(event);

  @override
  Stream<GeminiLiveEvent> get events => _fakeEvents.stream;

  @override
  bool get isConnected => _fakeConnected;

  @override
  String get activeApiKey => _fakeKey;

  @override
  String get activeModelId => _fakeModel;

  @override
  String get activeApiVersion => _fakeVersion;

  @override
  LiveConnectionDiagnostics? get lastDiagnostics => _fakeDiag;

  @override
  Future<LiveConnectionDiagnostics> connect({
    required List<String> apiKeys,
    required String modelId,
    required String systemPrompt,
    required List<Map<String, dynamic>> functionDeclarations,
    String? resumptionHandle,
    String voiceName = 'Aoede',
    bool forceRefreshModelDiscovery = false,
    String? translationTargetLanguageCode,
    bool echoTargetLanguage = false,
    bool enableCompression = true,
    int compressionTriggerTokens = 16384,
    int compressionTargetTokens = 8192,
  }) async {
    connectCalls++;
    _fakeModel = modelId;
    _fakeKey = apiKeys.isNotEmpty ? apiKeys.first : '';
    if (failNextConnect) {
      _fakeConnected = false;
      _fakeDiag = LiveConnectionDiagnostics(
        success: false,
        requestedModelId: modelId,
        resolvedModelId: '',
        apiVersion: _fakeVersion,
        setupProfile: null,
        maskedKey: GeminiLiveClient.maskApiKey(_fakeKey),
        apiKeyCount: apiKeys.length,
        latencyMs: 12,
        availableBidiModels: const [],
        summaryMessage: 'Simulated handshake error',
        attemptLogs: const ['Simulated failure'],
        checkedAt: DateTime.now(),
      );
      throw StateError('Simulated handshake error');
    }

    _fakeConnected = true;
    _fakeDiag = LiveConnectionDiagnostics(
      success: true,
      requestedModelId: modelId,
      resolvedModelId: modelId,
      apiVersion: _fakeVersion,
      setupProfile: LiveSetupProfile.full,
      maskedKey: GeminiLiveClient.maskApiKey(_fakeKey),
      apiKeyCount: apiKeys.length,
      latencyMs: 28,
      availableBidiModels: [modelId],
      summaryMessage: 'OK',
      attemptLogs: const ['OK'],
      checkedAt: DateTime.now(),
    );
    _fakeEvents.add(LiveSetupCompleteEvent(modelId, apiVersion: _fakeVersion));
    return _fakeDiag!;
  }

  @override
  Future<void> disconnect({bool intentional = true}) async {
    _fakeConnected = false;
  }

  @override
  void sendClientText(String text, {bool turnComplete = true}) {
    sentClientTexts.add(text);
  }

  @override
  void sendToolResponses(List<LiveFunctionResponse> responses) {
    sentToolResponses.add(responses);
  }

  @override
  void sendHistoryTurns(
    List<Map<String, dynamic>> turns, {
    bool turnComplete = false,
  }) {}

  @override
  Future<String> runOneShotLivePrompt({
    required List<String> apiKeys,
    required String modelId,
    required String systemPrompt,
    required String userPrompt,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    oneShotLiveCalls++;
    return nextOneShotReply;
  }

  void simulateUnexpectedDrop(String reason) {
    _fakeConnected = false;
    _fakeEvents.add(LiveConnectionClosedEvent(intentional: false, reason: reason));
  }

  @override
  Future<void> dispose() async {
    await _fakeEvents.close();
  }
}

class _NoopAudioOutput implements LivePcmAudioOutput {
  bool _enabled = false;
  bool _paused = false;
  double _volume = 1.0;
  double _rate = 1.0;
  @override
  int get firstSegmentBytes => 19200;
  @override
  int get normalSegmentBytes => 57600;
  @override
  VoidCallback? onPlaybackStateChanged;
  @override
  bool get isEnabled => _enabled;
  @override
  bool get isPlaying => false;
  @override
  bool get isPaused => _paused;
  @override
  double get volume => _volume;
  @override
  double get playbackRate => _rate;
  @override
  void setEnabled(bool enabled) => _enabled = enabled;
  @override
  Future<void> setVolume(double volume) async => _volume = volume;
  @override
  Future<void> setPlaybackRate(double rate) async => _rate = rate;
  @override
  Future<void> setPaused(bool paused) async => _paused = paused;
  @override
  Future<void> enqueuePcmChunk(Uint8List pcmBytes) async {}
  @override
  Future<void> flushTurn() async {}
  @override
  Future<void> interrupt() async {}
  @override
  Future<void> dispose() async {}
}
