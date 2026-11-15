import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:capsub_flutter/data/repository/settings_repository.dart';
import 'package:capsub_flutter/domain/ai/ai_model_registry.dart';
import 'package:capsub_flutter/domain/ai/live/gemini_live_client.dart';
import 'package:capsub_flutter/domain/ai/live/live_audio_io.dart';
import 'package:capsub_flutter/domain/ai/live/live_pcm_stream_extractor.dart';
import 'package:capsub_flutter/domain/ai/live/live_stream_translator.dart';
import 'package:capsub_flutter/ui/player/live_translate_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (MethodCall call) async => '',
        );
    SharedPreferences.setMockInitialValues({});
  });

  group('GeminiLiveClient.buildSetupPayload for Live Translate', () {
    test('builds translationConfig inside generationConfig without speechConfig or tools', () {
      final payload = GeminiLiveClient.buildSetupPayload(
        modelId: AiModelRegistry.geminiLiveTranslateModel,
        systemPrompt: '',
        functionDeclarations: const [],
        translationTargetLanguageCode: 'vi',
        echoTargetLanguage: false,
        compressionTriggerTokens: 16384,
        compressionTargetTokens: 8192,
      );

      final setup = payload['setup'] as Map<String, dynamic>;
      expect(
        setup['model'],
        equals('models/${AiModelRegistry.geminiLiveTranslateModel}'),
      );
      expect(setup.containsKey('translationConfig'), isFalse);
      final gen = setup['generationConfig'] as Map<String, dynamic>;
      expect(gen['responseModalities'], equals(['AUDIO']));
      expect(
        gen['translationConfig'],
        equals({'targetLanguageCode': 'vi', 'echoTargetLanguage': false}),
      );
      expect(gen.containsKey('speechConfig'), isFalse);
      expect(setup.containsKey('tools'), isFalse);
      expect(setup.containsKey('systemInstruction'), isFalse);
      expect(setup.containsKey('inputAudioTranscription'), isTrue);
      expect(setup.containsKey('outputAudioTranscription'), isTrue);
      expect(setup['contextWindowCompression'], {
        'triggerTokens': 16384,
        'slidingWindow': {'targetTokens': 8192},
      });
    });

    test('includes echoTargetLanguage true inside generationConfig.translationConfig', () {
      final payload = GeminiLiveClient.buildSetupPayload(
        modelId: AiModelRegistry.geminiLiveTranslateModel,
        systemPrompt: '',
        functionDeclarations: const [],
        translationTargetLanguageCode: 'en',
        echoTargetLanguage: true,
      );
      final setup = payload['setup'] as Map<String, dynamic>;
      final gen = setup['generationConfig'] as Map<String, dynamic>;
      expect(
        gen['translationConfig'],
        equals({'targetLanguageCode': 'en', 'echoTargetLanguage': true}),
      );
    });
  });

  group('PcmSilenceGate & computePcm16Rms', () {
    test('detects silence, allows speech + pre-roll + hangover, then flushes stream', () {
      final silence = _makePcm16(durationMs: 250, amplitude: 0);
      final speech = _makePcm16(durationMs: 250, amplitude: 3200);

      expect(computePcm16Rms(silence), equals(0.0));
      expect(computePcm16Rms(speech), greaterThan(1500.0));

      final gate = PcmSilenceGate(
        speechRmsThreshold: 135.0,
        preRollFrameCount: 1,
        hangoverMs: 300,
        enabled: true,
      );

      // Khoảng lặng ban đầu bị lọc nhưng giữ 1 pre-roll
      final d1 = gate.evaluate(silence, 250);
      expect(d1.skippedSilence, isTrue);
      expect(d1.framesToSend, isEmpty);
      expect(d1.shouldSendStreamEnd, isFalse);

      // Khi có tiếng nói -> đẩy cả pre-roll + frame nói
      final d2 = gate.evaluate(speech, 250);
      expect(d2.skippedSilence, isFalse);
      expect(d2.framesToSend.length, equals(2));
      expect(d2.shouldSendStreamEnd, isFalse);

      // Khoảng lặng 250ms <= hangover 300ms vẫn được giữ đuôi câu
      final d3 = gate.evaluate(silence, 250);
      expect(d3.skippedSilence, isFalse);
      expect(d3.framesToSend.length, equals(1));
      expect(d3.shouldSendStreamEnd, isFalse);

      // Thêm 250ms lặng (tổng 500ms > 300ms) -> ngắt và gửi audioStreamEnd
      final d4 = gate.evaluate(silence, 250);
      expect(d4.skippedSilence, isTrue);
      expect(d4.framesToSend, isEmpty);
      expect(d4.shouldSendStreamEnd, isTrue);
    });
  });

  group('LiveStreamTranslator lookahead, VAD, seek & key rotation', () {
    test('reads ahead up to configurable leadMs and fires warmup callback on first output', () async {
      final settings = await SettingsRepository.getInstance();
      settings.liveTranslateLeadMs = 2000;
      settings.liveTranslatePauseVideoOnWarmup = true;
      settings.liveTranslateVadFilterEnabled = true;

      final fakeClient = _FakeLiveTranslateClient();
      final fakeOutput = _FakeAudioOutput();
      late _FakePcmReader reader;
      var firstOutputFired = 0;

      final translator = LiveStreamTranslator(
        settings: settings,
        liveClient: fakeClient,
        audioOutput: fakeOutput,
        readerFactory: () {
          reader = _FakePcmReader(totalDurationMs: 60000);
          return reader;
        },
        delayFn: (_) async {},
      );
      translator.onFirstOutputArrived = () => firstOutputFired++;

      await translator.start(
        source: const LiveAudioSource(mediaPath: '/tmp/sample.mp4'),
        apiKeys: const ['AIzaKeyOne', 'AIzaKeyTwo'],
        initialPositionMs: 10000,
        playbackSpeed: 1.0,
        isPlaying: true,
      );

      // Mở reader ở 10000ms và bắt đầu đệm tiến tới 10000 + 2000ms
      expect(reader.openedStartMs, equals(10000));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(fakeClient.sentPcmFrames, isNotEmpty);

      // Đủ vài tick để con trỏ AI đi trước vị trí phát
      await Future<void>.delayed(const Duration(milliseconds: 520));
      expect(translator.actualLeadMs, greaterThan(0));
      expect(translator.actualLeadMs, lessThanOrEqualTo(2400));

      // Khi Gemini trả âm thanh & phụ đề -> nhả warmup, phát audio 24kHz
      fakeClient.emit(
        const LiveOutputTranscriptEvent('Xin chào bạn', finished: false),
      );
      fakeClient.emit(LiveOutputAudioEvent(Uint8List.fromList([1, 2, 3, 4])));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(firstOutputFired, equals(1));
      expect(translator.status, equals(LiveTranslateStatus.active));
      expect(translator.liveOutputTranscript, equals('Xin chào bạn'));
      expect(fakeOutput.enqueuedChunks.length, equals(1));

      // Đổi leadMs ngay khi đang xem -> persited & updates live
      translator.setLeadMs(4200);
      expect(translator.leadMs, equals(4200));
      expect(settings.liveTranslateLeadMs, equals(4200));

      await Future<void>.delayed(const Duration(milliseconds: 520));
      expect(translator.actualLeadMs, greaterThan(2200));

      translator.dispose();
    });

    test('handles pause, playback speed, seek interrupt, and GoAway/quota key rotation', () async {
      final settings = await SettingsRepository.getInstance();
      settings.liveTranslateLeadMs = 1500;
      settings.liveTranslateVadFilterEnabled = true;

      final fakeClient = _FakeLiveTranslateClient();
      final fakeOutput = _FakeAudioOutput();
      late _FakePcmReader reader;

      final translator = LiveStreamTranslator(
        settings: settings,
        liveClient: fakeClient,
        audioOutput: fakeOutput,
        readerFactory: () {
          reader = _FakePcmReader(totalDurationMs: 90000, silentBeforeMs: 5000);
          return reader;
        },
        delayFn: (_) async {},
      );

      await translator.start(
        source: const LiveAudioSource(mediaPath: 'http://127.0.0.1:9999/stream?vid=1'),
        apiKeys: const ['AIzaKeyAlpha', 'AIzaKeyBeta'],
        initialPositionMs: 0,
        playbackSpeed: 1.0,
        isPlaying: true,
      );

      // Đoạn 0..5000ms im lặng -> bị VAD bỏ qua, tiết kiệm 20k TPM
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(translator.skippedSilenceChunks, greaterThan(0));

      // Kết thúc warmup rồi đổi tốc độ & tạm dừng
      translator.finishWarmup();
      translator.onVideoStateUpdate(
        positionMs: 500,
        isPlaying: true,
        isBuffering: false,
        isScrubbing: false,
        playbackSpeed: 1.5,
      );
      expect(fakeOutput.playbackRate, equals(1.5));

      translator.onVideoStateUpdate(
        positionMs: 600,
        isPlaying: false,
        isBuffering: false,
        isScrubbing: false,
        playbackSpeed: 1.5,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fakeOutput.isPaused, isTrue);
      expect(translator.status, equals(LiveTranslateStatus.paused));

      // Tua tới mốc có thoại (20s)
      translator.onVideoStateUpdate(
        positionMs: 20000,
        isPlaying: true,
        isBuffering: false,
        isScrubbing: false,
        playbackSpeed: 1.0,
      );
      await translator.onSeek(20000);
      expect(fakeOutput.interruptCalls, greaterThanOrEqualTo(1));
      expect(reader.lastSeekMs, equals(20000));

      // GoAway xoay vòng sang key thứ 2
      final initialConnects = fakeClient.connectHistory.length;
      fakeClient.emit(const LiveGoAwayEvent('5s'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(fakeClient.connectHistory.length, greaterThan(initialConnects));
      expect(
        fakeClient.connectHistory.last.first,
        equals('AIzaKeyBeta'),
      );

      translator.dispose();
    });

    test(
      'switches video cleanly after pause without getting stuck paused or dropping early audio',
      () async {
        final settings = await SettingsRepository.getInstance();
        settings.liveTranslateLeadMs = 1500;
        settings.liveTranslateVadFilterEnabled = false;

        final fakeClient = _FakeLiveTranslateClient();
        final fakeOutput = _FakeAudioOutput();
        final createdReaders = <_FakePcmReader>[];

        final translator = LiveStreamTranslator(
          settings: settings,
          liveClient: fakeClient,
          audioOutput: fakeOutput,
          readerFactory: () {
            final r = _FakePcmReader(totalDurationMs: 60000);
            createdReaders.add(r);
            return r;
          },
          delayFn: (_) async {},
        );

        await translator.start(
          source: const LiveAudioSource(
            mediaPath: 'https://cdn.example.com/ep1.mp4',
            sourceLabel: 'Tập 1',
          ),
          apiKeys: const ['AIzaKeyOne', 'AIzaKeyTwo'],
          initialPositionMs: 0,
          playbackSpeed: 1.0,
          isPlaying: true,
        );
        translator.finishWarmup();

        // Giống VideoPlayerScreen._switchVideo: tạm dừng player cũ trước khi chuyển tập
        translator.onVideoStateUpdate(
          positionMs: 1200,
          isPlaying: false,
          isBuffering: false,
          isScrubbing: false,
          playbackSpeed: 1.0,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(fakeOutput.isPaused, isTrue);

        // Bắt đầu chuyển tập -> ngắt tập 1 nhưng updateSource chạy sát ngay sau không được phá tập 2
        unawaited(translator.prepareForSourceSwitch());
        await translator.updateSource(
          source: const LiveAudioSource(
            mediaPath: 'https://cdn.example.com/ep2.mp4',
            sourceLabel: 'Tập 2',
          ),
          positionMs: 0,
          apiKeys: const ['AIzaKeyOne', 'AIzaKeyTwo'],
          playbackSpeed: 1.0,
        );

        expect(createdReaders.length, equals(2));
        expect(createdReaders.first.closed, isTrue);
        expect(createdReaders.last.closed, isFalse);
        // Phải mở phiên WebSocket mới sạch cho video mới & giải phóng paused output
        expect(fakeClient.disconnectCount, greaterThanOrEqualTo(2));
        expect(fakeClient.connectHistory.length, equals(2));
        expect(fakeClient.connectHistory.last.first, equals('AIzaKeyTwo'));
        expect(fakeOutput.isPaused, isFalse);

        // Ngay cả khi transcript tới trước âm thanh lúc controller mới chưa kịp báo isPlaying=true,
        // audio trả về từ Gemini vẫn phải được đưa vào output chứ không bị rớt.
        fakeClient.emit(
          const LiveOutputTranscriptEvent('Câu mở đầu tập 2', finished: false),
        );
        fakeClient.emit(
          LiveOutputAudioEvent(Uint8List.fromList([10, 20, 30, 40])),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(fakeOutput.enqueuedChunks.length, equals(1));

        // Khi video mới thực sự chạy, audio vẫn tiếp tục thông suốt
        translator.onVideoStateUpdate(
          positionMs: 200,
          isPlaying: true,
          isBuffering: false,
          isScrubbing: false,
          playbackSpeed: 1.0,
        );
        fakeClient.emit(
          LiveOutputAudioEvent(Uint8List.fromList([50, 60, 70, 80])),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(fakeOutput.enqueuedChunks.length, equals(2));
        expect(translator.status, equals(LiveTranslateStatus.active));

        translator.dispose();
      },
    );
  });

  group('LiveTranslateSheet widget', () {
    testWidgets('adjusts leadMs via preset chips and slider and invokes onToggleEnabled', (
      tester,
    ) async {
      final settings = await SettingsRepository.getInstance();
      settings.liveTranslateLeadMs = 2000;

      final fakeClient = _FakeLiveTranslateClient();
      final fakeOutput = _FakeAudioOutput();
      final translator = LiveStreamTranslator(
        settings: settings,
        liveClient: fakeClient,
        audioOutput: fakeOutput,
        readerFactory: () => _FakePcmReader(),
        delayFn: (_) async {},
      );

      bool? lastToggled;
      double latestOrigVol = 0.25;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveTranslateSheet(
              translator: translator,
              settings: settings,
              originalVideoVolume: latestOrigVol,
              onOriginalVideoVolumeChanged: (v) => latestOrigVol = v,
              onToggleEnabled: (enabled) async {
                lastToggled = enabled;
              },
              hasGeminiKeys: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Cho AI nghe trước'), findsOneWidget);
      expect(find.text('+2.0s'), findsOneWidget);

      await tester.tap(find.text('+3s'));
      await tester.pump();
      expect(translator.leadMs, equals(3000));
      expect(find.text('+3.0s'), findsOneWidget);

      await tester.tap(find.text('+1.5s'));
      await tester.pump();
      expect(translator.leadMs, equals(1500));
      expect(find.text('+1.5s'), findsNWidgets(2));

      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      expect(lastToggled, isTrue);

      translator.dispose();
    });
  });

  group('LivePcmAudioOutput native PCM streaming', () {
    test(
      'batches 120ms turn cushion, streams strictly in order without duplicate replay, and drops stale pre-interrupt chunks',
      () async {
        const channelName = LivePcmAudioOutput.nativeChannelName;
        const channel = MethodChannel(channelName);
        final recordedCalls = <MethodCall>[];
        final enqueuedPayloads = <Uint8List>[];

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
          recordedCalls.add(call);
          if (call.method == 'enqueuePcm') {
            final args = Map<Object?, Object?>.from(call.arguments as Map);
            enqueuedPayloads.add(args['pcm'] as Uint8List);
          }
          return true;
        });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });

        final output = LivePcmAudioOutput(
          nativeChannel: channel,
          enableNativeStream: true,
        );
        var playbackChanges = 0;
        output.onPlaybackStateChanged = () => playbackChanges++;
        output.setEnabled(true);

        // 2 chunks nhỏ (< 5760 bytes) ghép lại đủ đệm khởi động ~120ms, phát 1 lần đúng thứ tự
        final c1 = Uint8List.fromList(List<int>.generate(3000, (i) => i % 200));
        final c2 = Uint8List.fromList(List<int>.generate(3000, (i) => (i + 50) % 200));
        final c3 = Uint8List.fromList(List<int>.generate(1600, (i) => 222));

        await output.enqueuePcmChunk(c1);
        expect(enqueuedPayloads, isEmpty);

        await output.enqueuePcmChunk(c2);
        await output.enqueuePcmChunk(c3);

        expect(recordedCalls.first.method, equals('start'));
        expect(enqueuedPayloads.length, equals(2));
        expect(enqueuedPayloads[0].length, equals(6000));
        expect(enqueuedPayloads[0].sublist(0, 3000), equals(c1));
        expect(enqueuedPayloads[0].sublist(3000, 6000), equals(c2));
        expect(enqueuedPayloads[1], equals(c3));

        // Kiểm tra callback trạng thái phát từ native & reset cushion ở lượt mới
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
          channelName,
          channel.codec.encodeMethodCall(
            const MethodCall('onPlaybackStateChanged', true),
          ),
          (_) {},
        );
        expect(output.isPlaying, isTrue);
        expect(playbackChanges, equals(1));

        await output.setVolume(0.75);
        await output.setPlaybackRate(1.25);
        await output.setPaused(true);
        expect(output.isPlaying, isFalse);

        // Kết thúc lượt hiện tại để lượt mới quay về tích lũy 120ms cushion, rồi ngắt giữa chừng
        await output.setPaused(false);
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
          channelName,
          channel.codec.encodeMethodCall(
            const MethodCall('onPlaybackStateChanged', false),
          ),
          (_) {},
        );
        expect(output.isPlaying, isFalse);

        await output.enqueuePcmChunk(Uint8List(1000));
        expect(enqueuedPayloads.length, equals(2));
        await output.interrupt();
        await output.flushTurn();
        expect(enqueuedPayloads.length, equals(2));
        expect(recordedCalls.any((c) => c.method == 'interrupt'), isTrue);

        // Chờ ngắn để đảm bảo timer tích lũy cũ đã bị hủy không bắn muộn
        await Future<void>.delayed(const Duration(milliseconds: 140));
        expect(enqueuedPayloads.length, equals(2));

        // Khi đang pause mà interrupt (đổi video), native phải nhận lại setPaused(false)
        await output.setPaused(true);
        await output.interrupt();
        final pausedCallsAfterInterrupt = recordedCalls
            .skipWhile((c) => c.method != 'interrupt')
            .where((c) => c.method == 'setPaused')
            .toList();
        expect(pausedCallsAfterInterrupt, isNotEmpty);
        expect(
          Map<Object?, Object?>.from(
            pausedCallsAfterInterrupt.last.arguments as Map,
          )['paused'],
          isFalse,
        );

        await output.dispose();
      },
    );

    test(
      'flushes short turn tail on flushTurn and falls back gracefully on MissingPluginException',
      () async {
        const channel = MethodChannel('capsub/missing_live_audio_test');
        final output = LivePcmAudioOutput(
          nativeChannel: channel,
          enableNativeStream: true,
        );
        output.setEnabled(true);
        // Chunk lớn hơn startCushion để gọi channel ngay -> nhận MissingPluginException mà không crash
        await output.enqueuePcmChunk(Uint8List(6000));
        await output.flushTurn();
        await output.setVolume(0.8);
        await output.setPaused(true);
        await output.interrupt();
        await output.dispose();
      },
    );
  });
}

Uint8List _makePcm16({required int durationMs, required int amplitude}) {
  final sampleCount = (16000 * durationMs) ~/ 1000;
  final out = Uint8List(sampleCount * 2);
  if (amplitude == 0) return out;
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < sampleCount; i++) {
    final s = (math.sin(2 * math.pi * 440 * i / 16000) * amplitude).round();
    bd.setInt16(i * 2, s.clamp(-32768, 32767), Endian.little);
  }
  return out;
}

class _FakePcmReader implements LivePcmAudioReader {
  final int totalDurationMs;
  final int silentBeforeMs;
  int openedStartMs = 0;
  int lastSeekMs = 0;
  int _cursorMs = 0;
  bool closed = false;

  _FakePcmReader({
    this.totalDurationMs = 60000,
    this.silentBeforeMs = 0,
  });

  @override
  Future<int> open(LiveAudioSource source, {int startMs = 0}) async {
    closed = false;
    openedStartMs = startMs;
    _cursorMs = startMs;
    return totalDurationMs;
  }

  @override
  Future<LivePcmChunk> readChunk({int durationMs = 250}) async {
    final start = _cursorMs;
    final end = math.min(totalDurationMs, _cursorMs + durationMs);
    final chunkDur = math.max(0, end - start);
    _cursorMs = end;
    final eof = _cursorMs >= totalDurationMs;
    final amp = start < silentBeforeMs ? 0 : 2800;
    return LivePcmChunk(
      pcmBytes: chunkDur > 0 ? _makePcm16(durationMs: chunkDur, amplitude: amp) : Uint8List(0),
      startMs: start,
      endMs: end,
      eof: eof,
    );
  }

  @override
  Future<int> seekTo(int positionMs) async {
    lastSeekMs = positionMs;
    _cursorMs = positionMs.clamp(0, totalDurationMs);
    return _cursorMs;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _FakeLiveTranslateClient extends GeminiLiveClient {
  final StreamController<GeminiLiveEvent> _events =
      StreamController<GeminiLiveEvent>.broadcast();

  bool _connected = false;
  String _modelId = AiModelRegistry.geminiLiveTranslateModel;
  String _key = '';
  int disconnectCount = 0;
  final List<List<String>> connectHistory = [];
  final List<Uint8List> sentPcmFrames = [];
  int audioStreamEndCount = 0;

  void emit(GeminiLiveEvent event) => _events.add(event);

  @override
  Stream<GeminiLiveEvent> get events => _events.stream;

  @override
  bool get isConnected => _connected;

  @override
  String get activeModelId => _modelId;

  @override
  String get activeApiKey => _key;

  @override
  Future<LiveConnectionDiagnostics> connect({
    required List<String> apiKeys,
    required String modelId,
    required String systemPrompt,
    required List<Map<String, dynamic>> functionDeclarations,
    String? resumptionHandle,
    String voiceName = 'Aoede',
    bool enableCompression = true,
    int compressionTriggerTokens = 32768,
    int compressionTargetTokens = 16384,
    String? translationTargetLanguageCode,
    bool echoTargetLanguage = false,
    bool forceRefreshModelDiscovery = false,
  }) async {
    connectHistory.add(List<String>.from(apiKeys));
    _modelId = modelId;
    _key = apiKeys.first;
    _connected = true;
    final diag = LiveConnectionDiagnostics(
      success: true,
      requestedModelId: modelId,
      resolvedModelId: modelId,
      apiVersion: 'v1alpha',
      setupProfile: LiveSetupProfile.full,
      maskedKey: GeminiLiveClient.maskApiKey(_key),
      apiKeyCount: apiKeys.length,
      latencyMs: 10,
      availableBidiModels: [modelId],
      summaryMessage: 'OK',
      attemptLogs: const ['OK'],
      checkedAt: DateTime.now(),
    );
    _events.add(LiveSetupCompleteEvent(modelId, apiVersion: 'v1alpha'));
    return diag;
  }

  @override
  void sendRealtimeAudioPcm16k(Uint8List pcmBytes) {
    sentPcmFrames.add(pcmBytes);
  }

  @override
  void sendAudioStreamEnd() {
    audioStreamEndCount++;
  }

  @override
  Future<void> disconnect({bool intentional = true}) async {
    disconnectCount++;
    _connected = false;
  }

  @override
  Future<void> dispose() async {
    _connected = false;
    await _events.close();
  }
}

class _FakeAudioOutput implements LivePcmAudioOutput {
  bool _enabled = false;
  bool _paused = false;
  double _volume = 1.0;
  double _rate = 1.0;
  int interruptCalls = 0;
  final List<Uint8List> enqueuedChunks = [];

  @override
  int get firstSegmentBytes => 9600;

  @override
  int get normalSegmentBytes => 38400;

  @override
  VoidCallback? onPlaybackStateChanged;

  @override
  bool get isEnabled => _enabled;

  @override
  bool get isPlaying => enqueuedChunks.isNotEmpty && !_paused;

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
  Future<void> enqueuePcmChunk(Uint8List pcmBytes) async {
    enqueuedChunks.add(pcmBytes);
    onPlaybackStateChanged?.call();
  }

  @override
  Future<void> flushTurn() async {}

  @override
  Future<void> interrupt() async {
    interruptCalls++;
  }

  @override
  Future<void> dispose() async {}
}
