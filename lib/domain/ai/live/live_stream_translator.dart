import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../data/repository/settings_repository.dart';
import '../ai_model_registry.dart';
import 'gemini_live_client.dart';
import 'live_audio_io.dart';
import 'live_pcm_stream_extractor.dart';

enum LiveTranslateStatus {
  idle,
  connecting,
  buffering,
  active,
  paused,
  reconnecting,
  error,
}

/// Điều phối luồng nghe dịch trực tiếp (Real-time Lookahead Stream Translation)
/// bằng `gemini-3.5-live-translate-preview`:
/// - Đọc âm thanh tại mốc `T_play + leadMs` (người dùng tự chỉnh được từ 0s..8s)
///   để bù độ trễ mạng & xử lý câu của Gemini Live.
/// - Phát giọng tiếng Việt 24kHz qua [LivePcmAudioOutput] chỉ đệm ngắn trên RAM,
///   không ghi lưu tệp dài hạn ra ổ cứng.
/// - Lọc khoảng lặng (Local VAD) + nén cửa sổ ngữ cảnh + xoay vòng phiên/API Key
///   để hoạt động bền bỉ dưới ngưỡng 20k TPM.
class LiveStreamTranslator extends ChangeNotifier {
  static const Duration _proactiveSessionRotateInterval = Duration(
    minutes: 4,
    seconds: 30,
  );
  static const int maxLeadMs = 8000;
  static const int minLeadMs = 0;

  final SettingsRepository? _settings;
  final GeminiLiveClient _client;
  final LivePcmAudioOutput _audioOutput;
  final LivePcmAudioReader Function() _readerFactory;
  final Future<void> Function(Duration)? _delayFn;

  SettingsRepository? get settings => _settings;

  LiveAudioSource? _source;
  LivePcmAudioReader? _reader;
  StreamSubscription<GeminiLiveEvent>? _clientSub;
  Timer? _feedTimer;

  bool _enabled = false;
  bool _disposed = false;
  bool _isConnecting = false;
  bool _isRotating = false;
  bool _isTickRunning = false;
  bool _reachedEof = false;
  bool _sentAudioSinceFlush = false;
  bool _warmupFeedActive = false;
  bool _awaitingFirstOutput = false;
  bool _turnFinishedForCaption = false;

  LiveTranslateStatus _status = LiveTranslateStatus.idle;
  String _statusMessage = 'Chưa bật nghe dịch trực tiếp';
  String? _errorMessage;

  int _leadMs = 2000;
  String _targetLanguageCode = 'vi';
  bool _echoTargetLanguage = false;
  bool _showLiveCaptions = true;
  bool _pauseVideoOnWarmup = true;
  double _aiVolume = 1.0;

  int _currentPlayPosMs = 0;
  int _aiReadCursorMs = 0;
  int _mediaDurationMs = 0;
  bool _videoIsPlaying = false;
  bool _videoIsBuffering = false;
  bool _videoIsScrubbing = false;
  double _playbackSpeed = 1.0;

  String _liveInputTranscript = '';
  String _liveOutputTranscript = '';
  String _activeModelId = AiModelRegistry.geminiLiveTranslateModel;
  String _maskedActiveKey = '';
  bool _isAiSpeaking = false;

  List<String> _apiKeys = const [];
  int _keyOffset = 0;
  int _reconnectAttempts = 0;
  DateTime? _sessionStartedAt;
  DateTime? _lastSpeechAt;

  int _skippedSilenceChunks = 0;
  int _sentAudioMs = 0;

  final PcmSilenceGate _silenceGate = PcmSilenceGate(
    speechRmsThreshold: 135.0,
    preRollFrameCount: 1,
    hangoverMs: 900,
    enabled: true,
  );

  VoidCallback? onFirstOutputArrived;

  LiveStreamTranslator({
    SettingsRepository? settings,
    GeminiLiveClient? liveClient,
    LivePcmAudioOutput? audioOutput,
    LivePcmAudioReader Function()? readerFactory,
    this._delayFn,
  }) : _settings = settings,
       _client = liveClient ?? GeminiLiveClient(),
       _audioOutput =
           audioOutput ??
           LivePcmAudioOutput(
             firstSegmentBytes: 9600, // ~0.2s phản hồi nhanh câu đầu
             normalSegmentBytes: 38400, // ~0.8s nối mượt giữa các mảnh
           ),
       _readerFactory =
           readerFactory ?? (() => MethodChannelLivePcmAudioReader()) {
    if (settings != null) {
      _leadMs = settings.liveTranslateLeadMs.clamp(minLeadMs, maxLeadMs);
      _targetLanguageCode = settings.liveTranslateTargetLanguage;
      _echoTargetLanguage = settings.liveTranslateEchoTargetLanguage;
      _showLiveCaptions = settings.liveTranslateShowLiveCaptions;
      _pauseVideoOnWarmup = settings.liveTranslatePauseVideoOnWarmup;
      _silenceGate.enabled = settings.liveTranslateVadFilterEnabled;
      _aiVolume = settings.ttsVolume.clamp(0.0, 1.0);
      _activeModelId = settings.liveTranslateModel;
    }
    _audioOutput.onPlaybackStateChanged = _handleOutputPlaybackChanged;
    unawaited(_audioOutput.setVolume(_aiVolume));
    _clientSub = _client.events.listen(_handleLiveEvent);
  }

  bool get isEnabled => _enabled;
  LiveTranslateStatus get status => _status;
  String get statusMessage => _statusMessage;
  String? get errorMessage => _errorMessage;

  int get leadMs => _leadMs;
  double get leadSeconds => _leadMs / 1000.0;
  String get targetLanguageCode => _targetLanguageCode;
  bool get echoTargetLanguage => _echoTargetLanguage;
  bool get showLiveCaptions => _showLiveCaptions;
  bool get pauseVideoOnWarmup => _pauseVideoOnWarmup;
  bool get vadFilterEnabled => _silenceGate.enabled;
  double get aiVolume => _aiVolume;

  int get currentPlayPosMs => _currentPlayPosMs;
  int get aiReadCursorMs => _aiReadCursorMs;
  int get mediaDurationMs => _mediaDurationMs;
  int get actualLeadMs =>
      _enabled ? (_aiReadCursorMs - _currentPlayPosMs).clamp(-10000, 20000) : 0;

  String get liveInputTranscript => _liveInputTranscript;
  String get liveOutputTranscript => _liveOutputTranscript;
  String get activeModelId => _activeModelId;
  String get maskedActiveKey => _maskedActiveKey;
  bool get isAiSpeaking => _isAiSpeaking;
  int get skippedSilenceChunks => _skippedSilenceChunks;
  int get sentAudioSeconds => _sentAudioMs ~/ 1000;
  LiveAudioSource? get currentSource => _source;
  bool get isWarmingUp => _warmupFeedActive;

  void _handleOutputPlaybackChanged() {
    if (_disposed) return;
    _isAiSpeaking = _audioOutput.isPlaying;
    notifyListeners();
  }

  /// Thay đổi thời gian "AI nghe trước" ngay lập tức khi đang xem.
  void setLeadMs(int newLeadMs) {
    final clamped = newLeadMs.clamp(minLeadMs, maxLeadMs);
    if (_leadMs == clamped) return;
    _leadMs = clamped;
    _settings?.liveTranslateLeadMs = clamped;
    if (_enabled && _status == LiveTranslateStatus.active) {
      _statusMessage = 'Đang nghe dịch trước +${(clamped / 1000).toStringAsFixed(1)}s';
    }
    notifyListeners();
  }

  Future<void> setVolume(double volume) async {
    _aiVolume = volume.clamp(0.0, 1.0);
    _settings?.ttsVolume = _aiVolume;
    await _audioOutput.setVolume(_aiVolume);
    notifyListeners();
  }

  void setShowLiveCaptions(bool value) {
    _showLiveCaptions = value;
    _settings?.liveTranslateShowLiveCaptions = value;
    notifyListeners();
  }

  void setPauseVideoOnWarmup(bool value) {
    _pauseVideoOnWarmup = value;
    _settings?.liveTranslatePauseVideoOnWarmup = value;
    notifyListeners();
  }

  void setVadFilterEnabled(bool value) {
    _silenceGate.enabled = value;
    _settings?.liveTranslateVadFilterEnabled = value;
    notifyListeners();
  }

  Future<void> setTargetLanguageCode(String code) async {
    final clean = code.trim().isEmpty ? 'vi' : code.trim();
    if (_targetLanguageCode == clean) return;
    _targetLanguageCode = clean;
    _settings?.liveTranslateTargetLanguage = clean;
    notifyListeners();
    if (_enabled) {
      await _rotateOrReconnectSession(
        reason: 'Đang chuyển ngôn ngữ dịch sang $clean...',
      );
    }
  }

  Future<void> setEchoTargetLanguage(bool echo) async {
    if (_echoTargetLanguage == echo) return;
    _echoTargetLanguage = echo;
    _settings?.liveTranslateEchoTargetLanguage = echo;
    notifyListeners();
    if (_enabled) {
      await _rotateOrReconnectSession(
        reason: 'Đang áp dụng cấu hình lặp lại giọng gốc...',
      );
    }
  }

  /// Bắt đầu phiên Nghe Dịch Trực Tiếp cho nguồn âm thanh hiện tại.
  Future<void> start({
    required LiveAudioSource source,
    required List<String> apiKeys,
    int initialPositionMs = 0,
    double playbackSpeed = 1.0,
    bool isPlaying = true,
  }) async {
    if (_disposed) return;
    final cleanKeys = apiKeys
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .toList();
    if (cleanKeys.isEmpty) {
      _enabled = false;
      _status = LiveTranslateStatus.error;
      _errorMessage =
          'Chưa có Gemini API Key. Hãy thêm key trong Cài đặt để bật Nghe Dịch Live.';
      _statusMessage = _errorMessage!;
      notifyListeners();
      return;
    }
    if (!source.isValid) {
      _enabled = false;
      _status = LiveTranslateStatus.error;
      _errorMessage = 'Không tìm thấy luồng âm thanh hợp lệ cho video này.';
      _statusMessage = _errorMessage!;
      notifyListeners();
      return;
    }

    await stop(silent: true);

    _enabled = true;
    _apiKeys = cleanKeys;
    _source = source;
    _currentPlayPosMs = math.max(0, initialPositionMs);
    _playbackSpeed = playbackSpeed.clamp(0.5, 2.5);
    _videoIsPlaying = isPlaying;
    _videoIsBuffering = false;
    _videoIsScrubbing = false;
    _reachedEof = false;
    _sentAudioSinceFlush = false;
    _warmupFeedActive = true;
    _awaitingFirstOutput = true;
    _reconnectAttempts = 0;
    _skippedSilenceChunks = 0;
    _sentAudioMs = 0;
    _errorMessage = null;
    _liveInputTranscript = '';
    _liveOutputTranscript = '';
    _silenceGate.reset();

    final targetStartMs = math.max(0, _currentPlayPosMs);
    _aiReadCursorMs = targetStartMs;

    _status = LiveTranslateStatus.connecting;
    _statusMessage = 'Đang kết nối Gemini 3.5 Live Translate...';
    notifyListeners();

    try {
      await _openAudioReader(source, startMs: targetStartMs);
      if (!_enabled || _disposed) return;

      await _connectLiveSocket();
      if (!_enabled || _disposed) return;

      _audioOutput.setEnabled(true);
      await _audioOutput.setVolume(_aiVolume);
      await _audioOutput.setPlaybackRate(_playbackSpeed);
      await _audioOutput.setPaused(false);

      _status = LiveTranslateStatus.buffering;
      _statusMessage =
          'Đang đệm trước +${(_leadMs / 1000).toStringAsFixed(1)}s âm thanh...';
      notifyListeners();

      _startFeedLoop();
      // Đẩy ngay nhịp đầu tiên không cần đợi tick 200ms
      unawaited(_tickFeed());
    } catch (e) {
      await _handleFatalOrRecoverableFailure(e);
    }
  }

  /// Cập nhật nguồn âm thanh mới (đổi tập, đổi chất lượng Bilibili, hoặc tải xong cache).
  Future<void> updateSource({
    required LiveAudioSource source,
    required int positionMs,
    List<String>? apiKeys,
    double? playbackSpeed,
  }) async {
    if (_disposed || !_enabled) return;
    if (_source != null && _source!.isSameSource(source)) {
      return;
    }
    if (apiKeys != null && apiKeys.isNotEmpty) {
      _apiKeys = apiKeys
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    _source = source;
    _currentPlayPosMs = math.max(0, positionMs);
    if (playbackSpeed != null) {
      _playbackSpeed = playbackSpeed.clamp(0.5, 2.5);
    }
    _reachedEof = false;
    _warmupFeedActive = true;
    _awaitingFirstOutput = true;
    _silenceGate.reset();
    _liveInputTranscript = '';
    _liveOutputTranscript = '';

    await _audioOutput.interrupt();
    _safeSendAudioStreamEnd();

    final targetStartMs = math.max(0, _currentPlayPosMs);
    _aiReadCursorMs = targetStartMs;

    _status = LiveTranslateStatus.buffering;
    _statusMessage = 'Đang nạp luồng âm thanh nguồn mới...';
    notifyListeners();

    try {
      await _openAudioReader(source, startMs: targetStartMs);
      if (!_client.isConnected) {
        await _connectLiveSocket();
      }
      _startFeedLoop();
      unawaited(_tickFeed());
    } catch (e) {
      await _handleFatalOrRecoverableFailure(e);
    }
  }

  /// Đồng bộ trạng thái phát video từ player (~80-250ms/lần).
  void onVideoStateUpdate({
    required int positionMs,
    required bool isPlaying,
    required bool isBuffering,
    required bool isScrubbing,
    required double playbackSpeed,
  }) {
    if (!_enabled || _disposed) return;

    final clampedPos = math.max(0, positionMs);
    final posJump = (clampedPos - _currentPlayPosMs).abs();
    final playChanged = _videoIsPlaying != isPlaying;
    final speedChanged = (_playbackSpeed - playbackSpeed).abs() > 0.01;

    _currentPlayPosMs = clampedPos;
    _videoIsBuffering = isBuffering;
    _videoIsScrubbing = isScrubbing;
    _playbackSpeed = playbackSpeed.clamp(0.5, 2.5);

    if (speedChanged) {
      unawaited(_audioOutput.setPlaybackRate(_playbackSpeed));
    }

    if (playChanged) {
      _videoIsPlaying = isPlaying;
      if (isPlaying) {
        unawaited(_audioOutput.setPaused(false));
        if (_status == LiveTranslateStatus.paused) {
          _status = LiveTranslateStatus.active;
          _statusMessage =
              'AI đang nghe trước +${(_leadMs / 1000).toStringAsFixed(1)}s';
          notifyListeners();
        }
      } else if (!_warmupFeedActive) {
        unawaited(_audioOutput.setPaused(true));
        if (_sentAudioSinceFlush) {
          _safeSendAudioStreamEnd();
        }
        if (_status == LiveTranslateStatus.active ||
            _status == LiveTranslateStatus.buffering) {
          _status = LiveTranslateStatus.paused;
          _statusMessage = 'Đã tạm dừng nghe dịch (đang giữ nhịp)';
          notifyListeners();
        }
      }
    }

    // Phát hiện tua đột ngột ngay cả khi onSeek chưa được gọi trực tiếp
    if (!isScrubbing && posJump > 2500) {
      unawaited(onSeek(clampedPos));
    }
  }

  /// Xử lý khi người dùng tua video sang mốc mới.
  Future<void> onSeek(int newPositionMs) async {
    if (!_enabled || _disposed) return;
    final safePos = math.max(0, newPositionMs);
    final targetAiPos = (_mediaDurationMs > 0)
        ? math.min(_mediaDurationMs, safePos)
        : safePos;

    _currentPlayPosMs = safePos;
    _aiReadCursorMs = targetAiPos;
    _reachedEof = false;
    _warmupFeedActive = true;
    _awaitingFirstOutput = true;
    _silenceGate.reset();
    _liveInputTranscript = '';
    _liveOutputTranscript = '';

    await _audioOutput.interrupt();
    await _audioOutput.setPaused(!_videoIsPlaying && !_pauseVideoOnWarmup);
    _safeSendAudioStreamEnd();

    final reader = _reader;
    if (reader != null) {
      try {
        final actual = await reader.seekTo(targetAiPos);
        _aiReadCursorMs = actual;
      } catch (e) {
        debugPrint('[LiveStreamTranslator] Lỗi seek reader: $e');
      }
    }

    _status = LiveTranslateStatus.buffering;
    _statusMessage =
        'Đang đồng bộ lại +${(_leadMs / 1000).toStringAsFixed(1)}s sau khi tua...';
    notifyListeners();
    unawaited(_tickFeed());
  }

  /// Kết thúc giai đoạn giữ nhịp warmup (hoặc khi người dùng chủ động bấm Play).
  void finishWarmup() {
    if (!_warmupFeedActive) return;
    _warmupFeedActive = false;
    if (_enabled && !_videoIsPlaying && _status != LiveTranslateStatus.paused) {
      unawaited(_audioOutput.setPaused(true));
    }
    notifyListeners();
  }

  /// Dừng hoàn toàn phiên Nghe Dịch Trực Tiếp và giải phóng bộ đệm tạm.
  Future<void> stop({bool silent = false}) async {
    _enabled = false;
    _warmupFeedActive = false;
    _awaitingFirstOutput = false;
    _isConnecting = false;
    _isRotating = false;
    _feedTimer?.cancel();
    _feedTimer = null;

    _safeSendAudioStreamEnd();
    await _client.disconnect(intentional: true);
    await _audioOutput.setPaused(false);
    await _audioOutput.interrupt();
    _audioOutput.setEnabled(false);

    await _closeAudioReader();

    _silenceGate.reset();
    _isAiSpeaking = false;
    _liveInputTranscript = '';
    _liveOutputTranscript = '';
    _errorMessage = null;
    _status = LiveTranslateStatus.idle;
    _statusMessage = 'Đã tắt nghe dịch trực tiếp';
    if (!silent && !_disposed) {
      notifyListeners();
    }
  }

  Future<void> _openAudioReader(
    LiveAudioSource source, {
    required int startMs,
  }) async {
    await _closeAudioReader();
    final reader = _readerFactory();
    _reader = reader;
    final dur = await reader.open(source, startMs: startMs);
    if (_disposed || !_enabled) {
      await reader.close();
      return;
    }
    _mediaDurationMs = math.max(0, dur);
    if (_mediaDurationMs > 0 && _aiReadCursorMs > _mediaDurationMs) {
      _aiReadCursorMs = _mediaDurationMs;
      await reader.seekTo(_aiReadCursorMs);
    }
  }

  Future<void> _closeAudioReader() async {
    final reader = _reader;
    _reader = null;
    if (reader != null) {
      try {
        await reader.close();
      } catch (_) {}
    }
  }

  List<String> _rotatedApiKeys() {
    if (_apiKeys.isEmpty) return const [];
    final offset = _keyOffset % _apiKeys.length;
    if (offset == 0) return _apiKeys;
    return [
      ..._apiKeys.sublist(offset),
      ..._apiKeys.sublist(0, offset),
    ];
  }

  Future<void> _connectLiveSocket() async {
    if (_isConnecting || _disposed || !_enabled) return;
    _isConnecting = true;
    try {
      final modelId =
          _settings?.liveTranslateModel ??
          AiModelRegistry.geminiLiveTranslateModel;
      final diag = await _client.connect(
        apiKeys: _rotatedApiKeys(),
        modelId: modelId,
        systemPrompt: '',
        functionDeclarations: const [],
        translationTargetLanguageCode: _targetLanguageCode,
        echoTargetLanguage: _echoTargetLanguage,
        enableCompression: true,
        compressionTriggerTokens: 16384,
        compressionTargetTokens: 8192,
      );
      _activeModelId = diag.resolvedModelId;
      _maskedActiveKey = diag.maskedKey;
      _sessionStartedAt = DateTime.now();
      _reconnectAttempts = 0;
    } finally {
      _isConnecting = false;
    }
  }

  void _startFeedLoop() {
    _feedTimer?.cancel();
    _feedTimer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => unawaited(_tickFeed()),
    );
  }

  Future<void> _tickFeed() async {
    if (_isTickRunning || !_enabled || _disposed) return;
    if (_isConnecting || _isRotating || !_client.isConnected) return;
    if (_videoIsScrubbing) return;
    if (_videoIsBuffering && !_warmupFeedActive) return;
    if (!_videoIsPlaying && !_warmupFeedActive) return;

    final reader = _reader;
    if (reader == null) return;

    _isTickRunning = true;
    try {
      // Kiểm tra xoay vòng phiên định kỳ (~4.5 phút) lúc đang im lặng để giữ context nhỏ dưới 20k TPM.
      final startedAt = _sessionStartedAt;
      if (startedAt != null &&
          DateTime.now().difference(startedAt) >=
              _proactiveSessionRotateInterval &&
          !_sentAudioSinceFlush) {
        unawaited(
          _rotateOrReconnectSession(
            reason: 'Làm mới phiên định kỳ tối ưu 20k TPM...',
            advanceKey: _apiKeys.length > 1,
          ),
        );
        return;
      }

      final targetCursor = _mediaDurationMs > 0
          ? math.min(_mediaDurationMs, _currentPlayPosMs + _leadMs)
          : (_currentPlayPosMs + _leadMs);
      final deltaMs = targetCursor - _aiReadCursorMs;

      // Chênh lệch lớn (> 6.5s hoặc lùi > 1.2s): nhảy đọc thẳng tới mốc mới
      if (deltaMs < -1200 || deltaMs > 6500) {
        if (deltaMs < -1000) {
          await _audioOutput.interrupt();
        }
        _safeSendAudioStreamEnd();
        _silenceGate.reset();
        _reachedEof = false;
        final actual = await reader.seekTo(targetCursor);
        _aiReadCursorMs = actual;
        return;
      }

      // Đã đọc vượt quá mức leadMs người dùng chọn -> chờ playback đuổi kịp
      if (_aiReadCursorMs > targetCursor + 350) {
        if (_warmupFeedActive && !_awaitingFirstOutput) {
          _warmupFeedActive = false;
        }
        return;
      }

      if (_reachedEof || deltaMs < 140) {
        return;
      }

      // Kiểm soát tốc độ đẩy: ~1x khi đã ổn định, tối đa ~2.5x (~550ms) lúc đang đuổi leadMs
      final normalStep = (200 * _playbackSpeed).round().clamp(160, 500);
      final stepMs = deltaMs > 450
          ? math.min(550, deltaMs)
          : math.min(normalStep, deltaMs + 80);

      final chunk = await reader.readChunk(durationMs: stepMs);
      if (!_enabled || _disposed) return;

      if (chunk.pcmBytes.isNotEmpty) {
        final actualDur = chunk.endMs > chunk.startMs
            ? (chunk.endMs - chunk.startMs)
            : stepMs;
        _aiReadCursorMs = chunk.endMs > 0
            ? chunk.endMs
            : (_aiReadCursorMs + actualDur);

        final decision = _silenceGate.evaluate(chunk.pcmBytes, actualDur);
        for (final frame in decision.framesToSend) {
          if (!_client.isConnected) break;
          _client.sendRealtimeAudioPcm16k(frame);
          _sentAudioSinceFlush = true;
          _lastSpeechAt = DateTime.now();
          _sentAudioMs += frame.length ~/ 32; // 16kHz 16-bit mono = 32 bytes/ms
        }
        if (decision.skippedSilence) {
          _skippedSilenceChunks++;
        }
        if (decision.shouldSendStreamEnd) {
          _safeSendAudioStreamEnd();
        }
      }

      if (chunk.eof) {
        _reachedEof = true;
        _safeSendAudioStreamEnd();
      }

      if (_status == LiveTranslateStatus.buffering &&
          _aiReadCursorMs >= targetCursor - 250) {
        if (!_awaitingFirstOutput) {
          _status = _videoIsPlaying
              ? LiveTranslateStatus.active
              : LiveTranslateStatus.paused;
          _statusMessage =
              'AI đang nghe trước +${(_leadMs / 1000).toStringAsFixed(1)}s';
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[LiveStreamTranslator] Lỗi vòng đẩy audio: $e');
      if (e.toString().toLowerCase().contains('websocket')) {
        unawaited(
          _rotateOrReconnectSession(
            reason: 'Mất kết nối tạm thời, đang nối lại...',
          ),
        );
      }
    } finally {
      _isTickRunning = false;
    }
  }

  void _safeSendAudioStreamEnd() {
    if (!_sentAudioSinceFlush || !_client.isConnected) {
      _sentAudioSinceFlush = false;
      return;
    }
    try {
      _client.sendAudioStreamEnd();
    } catch (_) {}
    _sentAudioSinceFlush = false;
  }

  void _handleLiveEvent(GeminiLiveEvent event) {
    if (_disposed || !_enabled) return;

    switch (event) {
      case LiveSetupCompleteEvent():
        _activeModelId = event.resolvedModelId;
        _status = _awaitingFirstOutput
            ? LiveTranslateStatus.buffering
            : (_videoIsPlaying
                  ? LiveTranslateStatus.active
                  : LiveTranslateStatus.paused);
        notifyListeners();

      case LiveOutputAudioEvent():
        _markFirstOutputArrived();
        if (_videoIsPlaying || _warmupFeedActive) {
          unawaited(_audioOutput.enqueuePcmChunk(event.pcmBytes));
        }

      case LiveOutputTranscriptEvent():
        _markFirstOutputArrived();
        final trimmed = event.text;
        if (trimmed.isNotEmpty) {
          if (_turnFinishedForCaption) {
            _liveOutputTranscript = trimmed;
            _turnFinishedForCaption = false;
          } else {
            _liveOutputTranscript = _appendTranscriptFragment(
              _liveOutputTranscript,
              trimmed,
            );
          }
          notifyListeners();
        }

      case LiveInputTranscriptEvent():
        final trimmed = event.text;
        if (trimmed.isNotEmpty) {
          if (_turnFinishedForCaption) {
            _liveInputTranscript = trimmed;
          } else {
            _liveInputTranscript = _appendTranscriptFragment(
              _liveInputTranscript,
              trimmed,
            );
          }
          notifyListeners();
        }

      case LiveTurnCompleteEvent():
        if (!event.isGenerationOnly) {
          _turnFinishedForCaption = true;
          unawaited(_audioOutput.flushTurn());
        }

      case LiveInterruptedEvent():
        _turnFinishedForCaption = true;
        unawaited(_audioOutput.flushTurn());

      case LiveGoAwayEvent():
        unawaited(
          _rotateOrReconnectSession(
            reason: 'Google Live yêu cầu làm mới kết nối (${event.timeLeft})...',
            advanceKey: _apiKeys.length > 1,
          ),
        );

      case LiveSessionResumptionEvent():
        break;

      case LiveErrorEvent():
        final lower = event.message.toLowerCase();
        final isQuota =
            lower.contains('quota') ||
            lower.contains('429') ||
            lower.contains('resource_exhausted');
        unawaited(
          _rotateOrReconnectSession(
            reason: isQuota
                ? 'Key chạm ngưỡng TPM, đang xoay vòng key/kết nối lại...'
                : 'Lỗi luồng Live: ${event.message}',
            advanceKey: true,
            backoff: isQuota && _apiKeys.length <= 1
                ? const Duration(seconds: 2)
                : const Duration(milliseconds: 500),
          ),
        );

      case LiveOutputTextEvent():
      case LiveToolCallEvent():
      case LiveToolCallCancelledEvent():
        break;

      case LiveConnectionClosedEvent():
        if (!event.intentional && _enabled && !_isRotating && !_isConnecting) {
          unawaited(
            _rotateOrReconnectSession(
              reason: 'Phiên Live vừa đóng (${event.closeCode ?? "?"}), đang khôi phục...',
              advanceKey: event.closeCode == 1008 || event.closeCode == 1011,
            ),
          );
        }
    }
  }

  void _markFirstOutputArrived() {
    if (_awaitingFirstOutput) {
      _awaitingFirstOutput = false;
      _warmupFeedActive = false;
      _status = _videoIsPlaying
          ? LiveTranslateStatus.active
          : LiveTranslateStatus.paused;
      _statusMessage =
          'AI đang nghe trước +${(_leadMs / 1000).toStringAsFixed(1)}s';
      onFirstOutputArrived?.call();
      notifyListeners();
    } else if (_status == LiveTranslateStatus.buffering) {
      _status = _videoIsPlaying
          ? LiveTranslateStatus.active
          : LiveTranslateStatus.paused;
      _statusMessage =
          'AI đang nghe trước +${(_leadMs / 1000).toStringAsFixed(1)}s';
      notifyListeners();
    }
  }

  static String _appendTranscriptFragment(String current, String incoming) {
    final c = current.trim();
    final inc = incoming.trim();
    if (c.isEmpty) return inc;
    if (inc.isEmpty) return c;
    // Giữ tối đa ~140 ký tự gần nhất để tránh che video
    final needsSpace =
        !c.endsWith(' ') &&
        !inc.startsWith(RegExp(r'[,.!?;:)]')) &&
        RegExp(r'[a-zA-Z0-9\u00C0-\u1EF9]$').hasMatch(c);
    final combined = needsSpace ? '$c $inc' : '$c$inc';
    if (combined.length <= 140) return combined;
    return combined.substring(combined.length - 140).trimLeft();
  }

  Future<void> _rotateOrReconnectSession({
    required String reason,
    bool advanceKey = false,
    Duration backoff = const Duration(milliseconds: 350),
  }) async {
    if (!_enabled || _disposed || _isRotating || _isConnecting) return;
    _isRotating = true;
    _reconnectAttempts++;
    if (_reconnectAttempts > 6 &&
        _lastSpeechAt != null &&
        DateTime.now().difference(_lastSpeechAt!) < const Duration(seconds: 20)) {
      _isRotating = false;
      await _handleFatalOrRecoverableFailure(
        StateError('Kết nối Live Translate bị ngắt liên tục. Kiểm tra API key hoặc mạng.'),
      );
      return;
    }

    if (advanceKey && _apiKeys.length > 1) {
      _keyOffset = (_keyOffset + 1) % _apiKeys.length;
    }

    _status = LiveTranslateStatus.reconnecting;
    _statusMessage = reason;
    notifyListeners();

    try {
      await _client.disconnect(intentional: true);
      if (backoff > Duration.zero) {
        final wait = _delayFn ?? Future<void>.delayed;
        await wait(backoff);
      }
      if (!_enabled || _disposed) return;

      _client.clearResumptionHandle();
      await _connectLiveSocket();
      if (!_enabled || _disposed) return;

      _status = _videoIsPlaying
          ? LiveTranslateStatus.active
          : LiveTranslateStatus.paused;
      _statusMessage =
          'AI đang nghe trước +${(_leadMs / 1000).toStringAsFixed(1)}s';
      notifyListeners();
    } catch (e) {
      await _handleFatalOrRecoverableFailure(e);
    } finally {
      _isRotating = false;
    }
  }

  Future<void> _handleFatalOrRecoverableFailure(Object error) async {
    if (_disposed) return;
    final cleanMsg = error.toString().replaceFirst('Bad state: ', '').trim();
    _errorMessage = cleanMsg;
    _status = LiveTranslateStatus.error;
    _statusMessage = cleanMsg;
    _warmupFeedActive = false;
    _awaitingFirstOutput = false;
    _feedTimer?.cancel();
    _feedTimer = null;
    await _closeAudioReader();
    await _client.disconnect(intentional: true);
    _audioOutput.setEnabled(false);
    _enabled = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _feedTimer?.cancel();
    _clientSub?.cancel();
    unawaited(_closeAudioReader());
    unawaited(_client.dispose());
    unawaited(_audioOutput.dispose());
    super.dispose();
  }
}
