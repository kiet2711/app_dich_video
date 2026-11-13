import 'dart:convert';
import 'dart:typed_data';

import 'package:capsub_flutter/domain/ai/live/gemini_live_client.dart';
import 'package:capsub_flutter/domain/ai/live/live_audio_io.dart';
import 'package:capsub_flutter/domain/media/hongguo/hongguo_assistant_engine.dart';
import 'package:capsub_flutter/domain/media/hongguo_resolver.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

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
  });
}
