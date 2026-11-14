import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../data/repository/settings_repository.dart';
import '../../domain/ai/ai_model_registry.dart';
import '../../domain/ai/live/gemini_live_client.dart';
import '../../domain/ai/live/live_audio_io.dart';
import '../../domain/ai/live/live_reply_title_sync.dart';
import '../../domain/media/hongguo/hongguo_assistant_engine.dart';
import '../../domain/media/hongguo_resolver.dart';

export '../../domain/ai/live/live_reply_title_sync.dart'
    show AssistantConnectionState;

class AssistantChatMessage {
  final String id;
  final bool isUser;
  final String text;
  final bool isStreaming;
  final bool isSystemNotice;
  final HongguoSearchReport? searchReport;

  const AssistantChatMessage({
    required this.id,
    required this.isUser,
    required this.text,
    this.isStreaming = false,
    this.isSystemNotice = false,
    this.searchReport,
  });

  AssistantChatMessage copyWith({
    String? text,
    bool? isStreaming,
    HongguoSearchReport? searchReport,
  }) {
    return AssistantChatMessage(
      id: id,
      isUser: isUser,
      text: text ?? this.text,
      isStreaming: isStreaming ?? this.isStreaming,
      isSystemNotice: isSystemNotice,
      searchReport: searchReport ?? this.searchReport,
    );
  }
}

/// Controller quản lý vòng đời Gemini Live WebSocket, Micro/Loa PCM, Tool Calling
/// và bộ nhớ ngữ cảnh xuyên suốt cho Trợ lý AI Hồng Quả.
class HongguoAssistantController extends ChangeNotifier {
  final HongguoAssistantEngine engine;
  final GeminiLiveClient _liveClient;
  final LiveMicRecorder _micRecorder;
  final LivePcmAudioOutput _audioOutput;

  StreamSubscription<GeminiLiveEvent>? _eventSub;
  final List<AssistantChatMessage> _messages = [];

  AssistantConnectionState _connectionState =
      AssistantConnectionState.disconnected;
  String _selectedModelId = 'gemini-3.8-live';
  String _resolvedServerModelId = 'gemini-3.8-live';
  bool _outputAudioEnabled = false;
  String _sourceFilter = '';
  int? _preferredCount = 5;
  final List<String> _pinnedSeriesIds = [];

  bool _isAssistantBusy = false;
  bool _isMicActive = false;
  bool _isAiSpeaking = false;
  double _micLevel = 0.0;
  String _busyLabel = '';
  String? _errorBanner;
  bool _needsSessionRenewalOnIdle = false;
  bool _hasApiKeys = true;
  int _apiKeyCount = 0;
  String _maskedActiveKey = '';
  String _resolvedApiVersion = 'v1beta';
  LiveConnectionDiagnostics? _lastDiagnostics;
  bool _hasEstablishedSessionOnce = false;
  Future<bool>? _connectInFlight;
  bool _autoReconnectInFlight = false;
  bool _disposed = false;
  int _msgSeq = 0;

  String? _activeAssistantMsgId;
  String? _lastAssistantMsgId;
  String? _activeUserVoiceMsgId;
  bool _turnReceivedTranscript = false;
  bool _turnExecutedTool = false;
  int _inFlightToolCount = 0;
  String _lastUserPrompt = '';
  HongguoSearchReport? _pendingTurnReport;

  HongguoAssistantController({
    HongguoResolver? resolver,
    GeminiLiveClient? liveClient,
    LiveMicRecorder? micRecorder,
    LivePcmAudioOutput? audioOutput,
  }) : engine = HongguoAssistantEngine(resolver: resolver),
       _liveClient = liveClient ?? GeminiLiveClient(),
       _micRecorder = micRecorder ?? LiveMicRecorder(),
       _audioOutput = audioOutput ?? LivePcmAudioOutput() {
    _eventSub = _liveClient.events.listen(_handleLiveEvent);
    _audioOutput.onPlaybackStateChanged = () {
      if (_disposed) return;
      _isAiSpeaking = _audioOutput.isPlaying;
      notifyListeners();
    };
  }

  List<AssistantChatMessage> get messages => List.unmodifiable(_messages);
  AssistantConnectionState get connectionState => _connectionState;
  String get selectedModelId => _selectedModelId;
  String get resolvedServerModelId => _resolvedServerModelId;
  String get resolvedApiVersion => _resolvedApiVersion;
  bool get outputAudioEnabled => _outputAudioEnabled;
  String get sourceFilter => _sourceFilter;
  int? get preferredCount => _preferredCount;
  List<String> get pinnedSeriesIds => List.unmodifiable(_pinnedSeriesIds);
  bool get isAssistantBusy => _isAssistantBusy;
  bool get isMicActive => _isMicActive;
  bool get isAiSpeaking => _isAiSpeaking;
  double get micLevel => _micLevel;
  String get busyLabel => _busyLabel;
  String? get errorBanner => _errorBanner;
  bool get hasApiKeys => _hasApiKeys;
  int get apiKeyCount => _apiKeyCount;
  String get maskedActiveKey => _maskedActiveKey;
  LiveConnectionDiagnostics? get lastDiagnostics => _lastDiagnostics;
  bool get hasEstablishedSessionOnce => _hasEstablishedSessionOnce;
  bool get isConnected => _liveClient.isConnected;

  void _syncKeyMetadata(List<String> keys) {
    _apiKeyCount = keys.length;
    _hasApiKeys = keys.isNotEmpty;
    final active = _liveClient.activeApiKey;
    if (active.isNotEmpty) {
      _maskedActiveKey = GeminiLiveClient.maskApiKey(active);
    } else if (keys.isNotEmpty) {
      _maskedActiveKey = GeminiLiveClient.maskApiKey(keys.first);
    } else {
      _maskedActiveKey = '';
    }
  }

  Future<void> initialize() async {
    try {
      final settings = await SettingsRepository.getInstance();
      try {
        await settings.reloadSecureKeys();
      } catch (_) {}
      _selectedModelId = settings.hongguoAssistantModel;
      _outputAudioEnabled = settings.hongguoAssistantOutputAudio;
      _preferredCount = settings.hongguoAssistantDefaultCount;
      _syncKeyMetadata(settings.geminiApiKeys);
      _audioOutput.setEnabled(_outputAudioEnabled);
      _syncEngineLocks();
      if (!_disposed) notifyListeners();
    } catch (_) {}
  }

  Future<void> refreshApiKeyStatus() async {
    try {
      final settings = await SettingsRepository.getInstance();
      try {
        await settings.reloadSecureKeys();
      } catch (_) {}
      _syncKeyMetadata(settings.geminiApiKeys);
      if (_hasApiKeys &&
          _connectionState == AssistantConnectionState.error &&
          _errorBanner != null &&
          _errorBanner!.contains('Chưa có Gemini API Key')) {
        _errorBanner = null;
        _connectionState = AssistantConnectionState.disconnected;
      }
      if (!_disposed) notifyListeners();
    } catch (_) {}
  }

  /// Lưu nhanh danh sách Gemini API Key (cách nhau bởi xuống dòng hoặc dấu phẩy) ngay từ trợ lý.
  Future<void> saveQuickGeminiKeys(String raw) async {
    final parsed = raw
        .split(RegExp(r'[\r\n,;]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final settings = await SettingsRepository.getInstance();
    settings.geminiApiKeys = parsed;
    _syncKeyMetadata(settings.geminiApiKeys);
    if (_hasApiKeys) {
      _errorBanner = null;
      if (_connectionState == AssistantConnectionState.error) {
        _connectionState = AssistantConnectionState.disconnected;
      }
    }
    if (!_disposed) notifyListeners();
  }

  void clearErrorBanner() {
    if (_errorBanner == null) return;
    _errorBanner = null;
    if (_connectionState == AssistantConnectionState.error &&
        !_liveClient.isConnected) {
      _connectionState = AssistantConnectionState.disconnected;
    }
    if (!_disposed) notifyListeners();
  }

  void _syncEngineLocks() {
    engine.updateUiLocks(
      HongguoUiLocks(
        sourceCategory: _sourceFilter,
        lockedCount: _preferredCount,
        pinnedSeriesIds: List<String>.from(_pinnedSeriesIds),
      ),
    );
  }

  Future<void> setOutputAudioEnabled(bool enabled) async {
    if (_outputAudioEnabled == enabled) return;
    _outputAudioEnabled = enabled;
    _audioOutput.setEnabled(enabled);
    if (!enabled) {
      await _audioOutput.interrupt();
    }
    try {
      final s = await SettingsRepository.getInstance();
      s.hongguoAssistantOutputAudio = enabled;
    } catch (_) {}
    if (!_disposed) notifyListeners();
  }

  void setSourceFilter(String sourceCategory) {
    if (_sourceFilter == sourceCategory) return;
    _sourceFilter = sourceCategory;
    _syncEngineLocks();
    notifyListeners();
  }

  void setPreferredCount(int? count) {
    final safe = count?.clamp(1, 20);
    if (_preferredCount == safe) return;
    _preferredCount = safe;
    if (safe != null) {
      unawaited(() async {
        try {
          final s = await SettingsRepository.getInstance();
          s.hongguoAssistantDefaultCount = safe;
        } catch (_) {}
      }());
    }
    _syncEngineLocks();
    notifyListeners();
  }

  void togglePinCandidate(String seriesId) {
    if (seriesId.isEmpty) return;
    if (_pinnedSeriesIds.contains(seriesId)) {
      _pinnedSeriesIds.remove(seriesId);
    } else {
      if (_pinnedSeriesIds.length >= 5) {
        _pinnedSeriesIds.removeAt(0);
      }
      _pinnedSeriesIds.add(seriesId);
    }
    _syncEngineLocks();
    notifyListeners();
  }

  void unpinCandidate(String seriesId) {
    if (_pinnedSeriesIds.remove(seriesId)) {
      _syncEngineLocks();
      notifyListeners();
    }
  }

  void clearPins() {
    if (_pinnedSeriesIds.isNotEmpty) {
      _pinnedSeriesIds.clear();
      _syncEngineLocks();
      notifyListeners();
    }
  }

  /// Đảm bảo kết nối WebSocket Gemini Live đã sẵn sàng (tự bơm ngữ cảnh nếu mở phiên mới).
  Future<bool> ensureConnected({
    bool seedContextSnapshot = false,
    bool forceFreshSession = false,
    bool forceRefreshModelDiscovery = false,
  }) {
    final inFlight = _connectInFlight;
    if (inFlight != null) {
      return inFlight;
    }

    final future = _ensureConnectedInternal(
      seedContextSnapshot: seedContextSnapshot,
      forceFreshSession: forceFreshSession,
      forceRefreshModelDiscovery: forceRefreshModelDiscovery,
    );
    _connectInFlight = future;
    return future.whenComplete(() {
      if (identical(_connectInFlight, future)) {
        _connectInFlight = null;
      }
    });
  }

  Future<bool> _ensureConnectedInternal({
    bool seedContextSnapshot = false,
    bool forceFreshSession = false,
    bool forceRefreshModelDiscovery = false,
  }) async {
    if (_liveClient.isConnected && !forceFreshSession) {
      _resolvedServerModelId = _liveClient.activeModelId;
      _resolvedApiVersion = _liveClient.activeApiVersion;
      _connectionState = AssistantConnectionState.ready;
      return true;
    }

    if (forceFreshSession && _liveClient.isConnected) {
      await _liveClient.disconnect(intentional: true);
    }

    final settings = await SettingsRepository.getInstance();
    try {
      await settings.reloadSecureKeys();
    } catch (_) {}
    final apiKeys = settings.geminiApiKeys;
    _syncKeyMetadata(apiKeys);
    if (apiKeys.isEmpty) {
      const msg =
          'Chưa có Gemini API Key. Hãy thêm key trong Cài đặt ➔ Gemini hoặc bấm Nhập Key để dán nhanh.';
      _errorBanner = msg;
      _connectionState = AssistantConnectionState.error;
      _lastDiagnostics = LiveConnectionDiagnostics(
        success: false,
        requestedModelId: _selectedModelId,
        resolvedModelId: '',
        apiVersion: _resolvedApiVersion,
        setupProfile: null,
        maskedKey: '',
        apiKeyCount: 0,
        latencyMs: 0,
        availableBidiModels: const [],
        summaryMessage: msg,
        attemptLogs: const ['Không tìm thấy Gemini API Key nào trong bộ nhớ bảo mật.'],
        checkedAt: DateTime.now(),
      );
      if (!_disposed) notifyListeners();
      return false;
    }

    _errorBanner = null;
    _connectionState = (_messages.isNotEmpty && _hasEstablishedSessionOnce)
        ? AssistantConnectionState.reconnecting
        : AssistantConnectionState.connecting;
    if (!_disposed) notifyListeners();

    try {
      final prompt = HongguoAssistantEngine.buildSystemPrompt(
        compactVoiceStyle: _outputAudioEnabled,
        defaultCount: _preferredCount ?? settings.hongguoAssistantDefaultCount,
      );
      final decls = HongguoAssistantEngine.buildFunctionDeclarations();
      final handle = forceFreshSession ? null : _liveClient.lastResumptionHandle;

      final diag = await _liveClient.connect(
        apiKeys: apiKeys,
        modelId: _selectedModelId,
        systemPrompt: prompt,
        functionDeclarations: decls,
        resumptionHandle: handle,
        forceRefreshModelDiscovery: forceRefreshModelDiscovery,
      );

      _lastDiagnostics = diag;
      _connectionState = AssistantConnectionState.ready;
      _resolvedServerModelId = diag.resolvedModelId;
      _resolvedApiVersion = diag.apiVersion;
      if (diag.maskedKey.isNotEmpty) {
        _maskedActiveKey = diag.maskedKey;
      }
      _hasEstablishedSessionOnce = true;
      _needsSessionRenewalOnIdle = false;

      if (seedContextSnapshot &&
          (_messages.isNotEmpty || engine.lastDisplayedCandidates.isNotEmpty)) {
        final turns = engine.buildCompressedSnapshotTurns(
          _extractRecentDialogue(),
        );
        _liveClient.sendHistoryTurns(turns, turnComplete: false);
      }

      if (!_disposed) notifyListeners();
      return true;
    } catch (e) {
      _lastDiagnostics = _liveClient.lastDiagnostics;
      _connectionState = AssistantConnectionState.error;
      final summary = _lastDiagnostics?.summaryMessage;
      _errorBanner = (summary != null && summary.isNotEmpty)
          ? summary
          : e.toString().replaceFirst('Bad state: ', '');
      if (!_disposed) notifyListeners();
      return false;
    }
  }

  /// Chuyển đổi giữa 3 model Live API mà vẫn giữ nguyên toàn bộ đoạn chat & danh sách phim.
  Future<void> switchModel(String newModelId) async {
    if (_selectedModelId == newModelId && _liveClient.isConnected) return;

    final wasConnected = _liveClient.isConnected;
    await stopMic();
    await _audioOutput.interrupt();
    _selectedModelId = newModelId;
    _errorBanner = null;
    _hasEstablishedSessionOnce = false;
    _resolvedServerModelId = '';
    try {
      final s = await SettingsRepository.getInstance();
      s.hongguoAssistantModel = newModelId;
    } catch (_) {}

    // Đổi model không thể dùng resumptionHandle của model cũ -> reset handle & bơm snapshot
    _liveClient.clearResumptionHandle();

    final displayName = AiModelRegistry.geminiLiveModels
        .firstWhere(
          (m) => m.id == newModelId,
          orElse: () => AiModelInfo(
            id: newModelId,
            displayName: newModelId,
            shortDescription: '',
            provider: AiProvider.gemini,
          ),
        )
        .displayName;

    if (_messages.isNotEmpty || engine.lastDisplayedCandidates.isNotEmpty) {
      _appendSystemNotice(
        'Đã chuyển sang $displayName (đã đồng bộ lại ngữ cảnh & danh sách phim hiện tại).',
      );
    }

    if (wasConnected ||
        _messages.isNotEmpty ||
        engine.lastDisplayedCandidates.isNotEmpty) {
      await ensureConnected(
        seedContextSnapshot:
            _messages.isNotEmpty || engine.lastDisplayedCandidates.isNotEmpty,
        forceFreshSession: true,
      );
    } else {
      await _liveClient.disconnect(intentional: true);
      _connectionState = AssistantConnectionState.disconnected;
      if (!_disposed) notifyListeners();
    }
  }

  /// Bắt đầu phiên trò chuyện mới hoàn toàn.
  Future<void> resetConversation() async {
    await stopMic();
    await _audioOutput.interrupt();
    _liveClient.clearResumptionHandle();
    await _liveClient.disconnect(intentional: true);
    _messages.clear();
    _pinnedSeriesIds.clear();
    _activeAssistantMsgId = null;
    _lastAssistantMsgId = null;
    _activeUserVoiceMsgId = null;
    _pendingTurnReport = null;
    _turnExecutedTool = false;
    _inFlightToolCount = 0;
    _lastUserPrompt = '';
    _isAssistantBusy = false;
    _hasEstablishedSessionOnce = false;
    _autoReconnectInFlight = false;
    _resolvedServerModelId = '';
    _busyLabel = '';
    _errorBanner = null;
    _connectionState = AssistantConnectionState.disconnected;
    _syncEngineLocks();
    if (!_disposed) notifyListeners();
  }

  /// Gửi yêu cầu dạng chữ từ người dùng (bao gồm cả ngữ cảnh phim ghim & bộ lọc UI).
  Future<void> sendTextMessage(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;

    if (_isMicActive) {
      await stopMic();
    }
    await _audioOutput.interrupt();

    _messages.add(
      AssistantChatMessage(
        id: 'u_${++_msgSeq}',
        isUser: true,
        text: clean,
      ),
    );
    _activeUserVoiceMsgId = null;
    _isAssistantBusy = true;
    _busyLabel = 'Đang gửi tới Gemini Live...';
    notifyListeners();

    final ok = await ensureConnected(seedContextSnapshot: true);
    if (!ok) {
      _isAssistantBusy = false;
      _busyLabel = '';
      notifyListeners();
      return;
    }

    try {
      final decorated = engine.decorateUserInput(clean);
      _closeDanglingAssistantTurnIfNeeded();
      _lastUserPrompt = clean;
      _turnExecutedTool = false;
      _prepareNewAssistantTurn();
      _liveClient.sendClientText(decorated, turnComplete: true);
    } catch (e) {
      _isAssistantBusy = false;
      _busyLabel = '';
      _errorBanner = 'Không gửi được tin nhắn: $e';
      notifyListeners();
    }
  }

  /// Bật/Tắt Micro thu âm trực tiếp gửi vào Gemini Live (`realtimeInput`).
  Future<void> toggleMic() async {
    if (_isMicActive) {
      await stopMic();
    } else {
      await startMic();
    }
  }

  Future<void> startMic() async {
    if (_isMicActive) return;

    await _audioOutput.interrupt();
    final ok = await ensureConnected(seedContextSnapshot: true);
    if (!ok) return;

    // Bơm trước ngữ cảnh UI (phim đang ghim #STT, nguồn lọc, số lượng) trước khi user nói vào mic
    final uiHeader = engine.buildUiContextHeader();
    if (uiHeader.isNotEmpty) {
      try {
        _liveClient.sendHistoryTurns([
          {
            'role': 'user',
            'parts': [
              {'text': uiHeader},
            ],
          },
        ], turnComplete: false);
      } catch (_) {}
    }

    // Tạo bong bóng thoại tạm cho lời nói của user
    _activeUserVoiceMsgId = 'uv_${++_msgSeq}';
    _messages.add(
      AssistantChatMessage(
        id: _activeUserVoiceMsgId!,
        isUser: true,
        text: '🎙️ Đang nghe bạn nói...',
        isStreaming: true,
      ),
    );
    _micLevel = 0.0;
    notifyListeners();

    final started = await _micRecorder.startStreaming(
      onPcmData: (pcm) {
        if (_liveClient.isConnected && _isMicActive) {
          _liveClient.sendRealtimeAudioPcm16k(pcm);
        }
      },
      onAmplitude: (level) {
        if ((_micLevel - level).abs() > 0.05 || (level == 0.0 && _micLevel != 0.0)) {
          _micLevel = level;
          if (!_disposed) notifyListeners();
        }
      },
      onError: (err) {
        _errorBanner = 'Lỗi Micro: $err';
        unawaited(stopMic());
      },
    );

    if (!started) {
      // Hủy bong bóng thoại tạm nếu không mở được mic
      _messages.removeWhere((m) => m.id == _activeUserVoiceMsgId);
      _activeUserVoiceMsgId = null;
      _errorBanner =
          'Chưa có quyền sử dụng Micro hoặc thiết bị không có Micro.';
      notifyListeners();
      return;
    }

    _isMicActive = true;
    notifyListeners();
  }

  Future<void> stopMic() async {
    if (!_isMicActive && !_micRecorder.isRecording) return;
    _isMicActive = false;
    _micLevel = 0.0;
    await _micRecorder.stop();
    if (_liveClient.isConnected) {
      try {
        _liveClient.sendAudioStreamEnd();
      } catch (_) {}
    }
    if (_activeUserVoiceMsgId != null) {
      final idx = _messages.indexWhere((m) => m.id == _activeUserVoiceMsgId);
      if (idx != -1) {
        final cur = _messages[idx];
        if (cur.text == '🎙️ Đang nghe bạn nói...') {
          _messages[idx] = cur.copyWith(
            text: '🎙️ (Tin nhắn thoại)',
            isStreaming: false,
          );
        } else {
          _messages[idx] = cur.copyWith(isStreaming: false);
        }
      }
      _isAssistantBusy = true;
      _busyLabel = 'Đang xử lý giọng nói...';
    }
    if (!_disposed) notifyListeners();
  }

  void _prepareNewAssistantTurn() {
    _activeAssistantMsgId = 'a_${++_msgSeq}';
    _lastAssistantMsgId = _activeAssistantMsgId;
    _turnReceivedTranscript = false;
    _pendingTurnReport = null;
    _messages.add(
      AssistantChatMessage(
        id: _activeAssistantMsgId!,
        isUser: false,
        text: '',
        isStreaming: true,
      ),
    );
  }

  void _closeDanglingAssistantTurnIfNeeded() {
    final prevId = _activeAssistantMsgId;
    if (prevId == null) return;
    final idx = _messages.indexWhere((m) => m.id == prevId);
    if (idx != -1 && _messages[idx].isStreaming) {
      _messages[idx] = _messages[idx].copyWith(isStreaming: false);
    }
    _activeAssistantMsgId = null;
  }

  void _appendSystemNotice(String text) {
    _messages.add(
      AssistantChatMessage(
        id: 'sys_${++_msgSeq}',
        isUser: false,
        text: text,
        isSystemNotice: true,
      ),
    );
    if (!_disposed) notifyListeners();
  }

  void _handleLiveEvent(GeminiLiveEvent event) {
    if (_disposed) return;

    switch (event) {
      case LiveSetupCompleteEvent(:final resolvedModelId, :final apiVersion):
        _connectionState = AssistantConnectionState.ready;
        _resolvedServerModelId = resolvedModelId;
        _resolvedApiVersion = apiVersion;
        _hasEstablishedSessionOnce = true;
        _errorBanner = null;
        notifyListeners();

      case LiveInputTranscriptEvent(:final text, :final finished):
        _handleInputTranscript(text, finished: finished);

      case LiveOutputTranscriptEvent(:final text, :final finished):
        _turnReceivedTranscript = true;
        _appendAssistantDelta(text, markDone: false);
        if (finished && _pendingTurnReport != null) {
          _attachReportToActiveAssistant();
        }

      case LiveOutputTextEvent(:final text):
        // Chỉ dùng text trực tiếp nếu turn này chưa nhận outputTranscription (tránh lặp 2 lần)
        if (!_turnReceivedTranscript) {
          _appendAssistantDelta(text, markDone: false);
        }

      case LiveOutputAudioEvent(:final pcmBytes):
        if (_outputAudioEnabled) {
          unawaited(_audioOutput.enqueuePcmChunk(pcmBytes));
        }

      case LiveToolCallEvent(:final calls):
        _turnExecutedTool = true;
        _inFlightToolCount++;
        unawaited(_executeAndRespondTools(calls));

      case LiveToolCallCancelledEvent():
        _isAssistantBusy = false;
        _busyLabel = '';
        notifyListeners();

      case LiveTurnCompleteEvent(:final interactionStatus, :final isGenerationOnly):
        unawaited(_audioOutput.flushTurn());
        if (_inFlightToolCount > 0 || interactionStatus == 'IN_PROGRESS') {
          // Extended Thinking / NON_BLOCKING tool vẫn đang chạy: giữ nguyên turn & tiếp tục chờ kết quả
          _attachReportToActiveAssistant();
          _isAssistantBusy = true;
          if (_inFlightToolCount == 0 && _busyLabel.isEmpty) {
            _busyLabel = 'Gemini đang tổng hợp câu trả lời...';
          }
          notifyListeners();
          break;
        }
        if (isGenerationOnly) {
          // Chờ `turnComplete: true` thực sự, chỉ gắn trước card nếu đã sẵn sàng
          _attachReportToActiveAssistant();
          break;
        }
        _finalizeActiveAssistantTurn();
        if (_needsSessionRenewalOnIdle) {
          unawaited(_renewSessionSeamlessly());
        }

      case LiveInterruptedEvent():
        unawaited(_audioOutput.interrupt());
        _finalizeActiveAssistantTurn();

      case LiveSessionResumptionEvent():
        // Đã được lưu trong _liveClient.lastResumptionHandle
        break;

      case LiveGoAwayEvent():
        _needsSessionRenewalOnIdle = true;
        if (!_isAssistantBusy) {
          unawaited(_renewSessionSeamlessly());
        }

      case LiveConnectionClosedEvent(:final intentional, :final reason):
        if (!intentional) {
          final shouldAutoReconnect =
              _hasEstablishedSessionOnce &&
              _messages.isNotEmpty &&
              !_autoReconnectInFlight &&
              _connectInFlight == null;
          _hasEstablishedSessionOnce = false;
          if (shouldAutoReconnect) {
            unawaited(_autoReconnectAfterDrop(reason));
          } else {
            if (_connectionState != AssistantConnectionState.error) {
              _connectionState = AssistantConnectionState.disconnected;
            }
            _isAssistantBusy = false;
            _busyLabel = '';
            notifyListeners();
          }
        }

      case LiveErrorEvent(:final message):
        _errorBanner = message;
        _isAssistantBusy = false;
        _busyLabel = '';
        if (!_liveClient.isConnected && _connectInFlight == null) {
          _connectionState = AssistantConnectionState.error;
        }
        notifyListeners();
    }
  }

  void _handleInputTranscript(String delta, {bool finished = false}) {
    if (_activeUserVoiceMsgId == null) {
      _activeUserVoiceMsgId = 'uv_${++_msgSeq}';
      _turnExecutedTool = false;
      _lastUserPrompt = delta.trim();
      _messages.add(
        AssistantChatMessage(
          id: _activeUserVoiceMsgId!,
          isUser: true,
          text: delta,
          isStreaming: !finished,
        ),
      );
      if (_activeAssistantMsgId == null) {
        _prepareNewAssistantTurn();
      }
      notifyListeners();
      return;
    }

    final idx = _messages.indexWhere((m) => m.id == _activeUserVoiceMsgId);
    if (idx != -1) {
      final cur = _messages[idx];
      final nextText = cur.text == '🎙️ Đang nghe bạn nói...'
          ? delta
          : '${cur.text}$delta';
      _lastUserPrompt = nextText.trim();
      _messages[idx] = cur.copyWith(text: nextText, isStreaming: !finished);
      if (finished) {
        _activeUserVoiceMsgId = null;
      }
      notifyListeners();
    }
  }

  void _appendAssistantDelta(String delta, {required bool markDone}) {
    if (_activeAssistantMsgId == null) {
      _prepareNewAssistantTurn();
    }
    final idx = _messages.indexWhere((m) => m.id == _activeAssistantMsgId);
    if (idx != -1) {
      final cur = _messages[idx];
      final nextText = '${cur.text}$delta';
      var nextReport = _pendingTurnReport ?? cur.searchReport;
      if (nextReport != null) {
        final parsed = HongguoAssistantEngine.extractAiTitlesFromLiveReply(
          nextText,
          maxIndex: nextReport.candidates.length,
          isFinal: markDone,
        );
        final updated = engine.applyAiTranslatedTitlesToReport(
          nextReport,
          parsed,
        );
        if (updated != null) {
          nextReport = updated;
          _pendingTurnReport = updated;
        }
      }
      _messages[idx] = cur.copyWith(
        text: nextText,
        isStreaming: !markDone,
        searchReport: nextReport,
      );
      notifyListeners();
    }
  }

  void _attachReportToActiveAssistant() {
    if (_pendingTurnReport == null) return;
    final targetId = _activeAssistantMsgId ?? _lastAssistantMsgId;
    if (targetId == null) {
      _prepareNewAssistantTurn();
      _attachReportToMessageId(_activeAssistantMsgId!, _pendingTurnReport!);
      return;
    }
    _attachReportToMessageId(targetId, _pendingTurnReport!);
  }

  void _attachReportToMessageId(String msgId, HongguoSearchReport report) {
    final idx = _messages.indexWhere((m) => m.id == msgId);
    if (idx != -1) {
      _messages[idx] = _messages[idx].copyWith(searchReport: report);
      notifyListeners();
    }
  }

  void _finalizeActiveAssistantTurn() {
    _isAssistantBusy = false;
    _busyLabel = '';
    final finishedMsgId = _activeAssistantMsgId;
    final pendingPrompt = _lastUserPrompt;
    final executedToolThisTurn = _turnExecutedTool;
    HongguoSearchReport? finalReport;
    var hasNonEmptyReplyText = false;

    if (finishedMsgId != null) {
      final idx = _messages.indexWhere((m) => m.id == finishedMsgId);
      if (idx != -1) {
        final cur = _messages[idx];
        var effectiveReport = _pendingTurnReport ?? cur.searchReport;
        hasNonEmptyReplyText = cur.text.trim().isNotEmpty;
        if (effectiveReport != null && hasNonEmptyReplyText) {
          final parsed = HongguoAssistantEngine.extractAiTitlesFromLiveReply(
            cur.text,
            maxIndex: effectiveReport.candidates.length,
            isFinal: true,
          );
          final updated = engine.applyAiTranslatedTitlesToReport(
            effectiveReport,
            parsed,
          );
          if (updated != null) {
            effectiveReport = updated;
          }
        }
        finalReport = effectiveReport;
        if (!hasNonEmptyReplyText && effectiveReport == null) {
          _messages.removeAt(idx);
        } else {
          _messages[idx] = cur.copyWith(
            isStreaming: false,
            searchReport: effectiveReport,
          );
        }
      }
      _activeAssistantMsgId = null;
      _pendingTurnReport = null;
      _turnReceivedTranscript = false;
    }

    // Safety net: nếu Gemini Live bỏ qua tool calling ở câu tìm phim -> tự lấy thẻ thật rồi nhờ model Live dịch Hán Việt + tóm tắt
    if (finishedMsgId != null &&
        !executedToolThisTurn &&
        finalReport == null &&
        hasNonEmptyReplyText &&
        pendingPrompt.isNotEmpty &&
        HongguoAssistantEngine.looksLikeMovieDiscoveryQuery(pendingPrompt)) {
      _lastUserPrompt = '';
      unawaited(_attachAutoFallbackCardsIfNeeded(finishedMsgId, pendingPrompt));
    } else if (finishedMsgId != null &&
        finalReport != null &&
        finalReport.candidates.any(HongguoAssistantEngine.isUntranslatedTitle)) {
      // Nếu Gemini chỉ đọc/ghi vài phim đầu mà thẻ sau vẫn còn tiếng Trung -> nhờ chính model Live dịch nốt tên Hán Việt
      unawaited(_translateMissingTitlesWithLiveModel(finishedMsgId, finalReport));
    }

    notifyListeners();
  }

  Future<void> _attachAutoFallbackCardsIfNeeded(
    String msgId,
    String prompt,
  ) async {
    try {
      final report = await engine.autoSearchFallbackFromPrompt(
        prompt,
        onSearchResultsUpdated: (r) {
          if (!_disposed && r.candidates.isNotEmpty) {
            _attachReportToMessageId(msgId, r);
          }
        },
      );
      if (_disposed || report == null || report.candidates.isEmpty) return;
      _attachReportToMessageId(msgId, report);

      await _translateMissingTitlesWithLiveModel(
        msgId,
        report,
        includeShortSummaryInMessage: true,
      );

      if (!_disposed && _liveClient.isConnected) {
        try {
          _liveClient.sendHistoryTurns(
            engine.buildCompressedSnapshotTurns(const []),
            turnComplete: false,
          );
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _translateMissingTitlesWithLiveModel(
    String msgId,
    HongguoSearchReport report, {
    bool includeShortSummaryInMessage = false,
  }) async {
    if (_disposed) return;
    final missing = report.candidates
        .where(HongguoAssistantEngine.isUntranslatedTitle)
        .toList();
    if (missing.isEmpty) return;

    try {
      final settings = await SettingsRepository.getInstance();
      final keys = settings.geminiApiKeys;
      if (keys.isEmpty && _liveClient.activeApiKey.trim().isEmpty) return;

      final liveReply = await _liveClient.runOneShotLivePrompt(
        apiKeys: keys,
        modelId: _selectedModelId,
        systemPrompt:
            'Bạn là chuyên gia dịch tên phim & cốt truyện phim ngắn Hoa ngữ sang Tiếng Việt mượt mà dùng âm Hán Việt chuẩn, TUYỆT ĐỐI CẤM Pinyin.',
        userPrompt: HongguoAssistantEngine.buildLiveTitleTranslationPrompt(
          missing,
          includeShortSummary: includeShortSummaryInMessage,
        ),
      );
      if (_disposed || liveReply.trim().isEmpty) return;

      final maxIdx = report.candidates.fold<int>(
        report.candidates.length,
        (m, c) => c.displayIndex > m ? c.displayIndex : m,
      );
      final parsed = HongguoAssistantEngine.extractAiTitlesFromLiveReply(
        liveReply,
        maxIndex: maxIdx,
        isFinal: true,
      );

      final idx = _messages.indexWhere((m) => m.id == msgId);
      if (idx == -1) return;
      final curMsg = _messages[idx];
      final currentReport = curMsg.searchReport ?? report;
      final updatedReport =
          engine.applyAiTranslatedTitlesToReport(currentReport, parsed) ??
              currentReport;

      final nextText = includeShortSummaryInMessage
          ? '${curMsg.text}\n\n📌 **Danh sách thật từ kho Hồng Quả:**\n$liveReply'
          : curMsg.text;

      _messages[idx] = curMsg.copyWith(
        text: nextText,
        searchReport: updatedReport,
      );
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _executeAndRespondTools(List<LiveFunctionCall> calls) async {
    _isAssistantBusy = true;
    _busyLabel = 'Đang tra kho Hồng Quả...';
    if (_activeAssistantMsgId == null) {
      _prepareNewAssistantTurn();
    }
    final targetMsgId = _activeAssistantMsgId!;
    notifyListeners();

    try {
      final responses = await Future.wait(
        calls.map(
          (call) => engine.executeToolCall(
            call,
            onProgress: (status) {
              if (_disposed) return;
              _busyLabel = status;
              notifyListeners();
            },
            onSearchResultsUpdated: (report) {
              _pendingTurnReport = report;
              _attachReportToMessageId(targetMsgId, report);
            },
          ),
        ),
      );

      if (_disposed) return;
      _busyLabel = 'Gemini đang tổng hợp câu trả lời...';
      notifyListeners();

      if (_liveClient.isConnected) {
        try {
          _liveClient.sendToolResponses(responses);
        } catch (e) {
          _errorBanner = 'Lỗi trả dữ liệu tool cho Gemini: $e';
          _finalizeActiveAssistantTurn();
        }
      } else {
        _finalizeActiveAssistantTurn();
      }
    } finally {
      _inFlightToolCount = math.max(0, _inFlightToolCount - 1);
    }
  }

  Future<void> _renewSessionSeamlessly() async {
    _needsSessionRenewalOnIdle = false;
    final ok = await ensureConnected(
      seedContextSnapshot: true,
      forceFreshSession: _liveClient.lastResumptionHandle == null,
    );
    if (ok) {
      _appendSystemNotice('Đã làm mới phiên Gemini Live tự động (vẫn giữ nguyên ngữ cảnh).');
    }
  }

  Future<void> _autoReconnectAfterDrop(String? reason) async {
    if (_disposed || _autoReconnectInFlight) return;
    _autoReconnectInFlight = true;
    try {
      _connectionState = AssistantConnectionState.reconnecting;
      notifyListeners();

      final hasHandle = _liveClient.lastResumptionHandle != null;
      final resumed = await ensureConnected(
        seedContextSnapshot: !hasHandle,
        forceFreshSession: !hasHandle,
      );
      if (!resumed && hasHandle && !_disposed) {
        // Nếu handle cũ đã hết hạn -> thử tạo phiên sạch 1 lần duy nhất + bơm snapshot ngữ cảnh
        _liveClient.clearResumptionHandle();
        final freshOk = await ensureConnected(
          seedContextSnapshot: true,
          forceFreshSession: true,
        );
        if (freshOk) {
          _appendSystemNotice(
            'Phiên cũ vừa hết hạn (${reason ?? "timeout"}), đã tự khởi tạo phiên mới và giữ nguyên danh sách phim.',
          );
        }
      }
    } finally {
      _autoReconnectInFlight = false;
    }
  }

  List<({bool isUser, String text})> _extractRecentDialogue() {
    return _messages
        .where((m) => !m.isSystemNotice && m.text.trim().isNotEmpty)
        .map((m) => (isUser: m.isUser, text: m.text))
        .toList();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_eventSub?.cancel());
    unawaited(_micRecorder.dispose());
    unawaited(_audioOutput.dispose());
    unawaited(_liveClient.dispose());
    super.dispose();
  }
}
