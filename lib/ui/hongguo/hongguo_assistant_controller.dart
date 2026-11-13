import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/repository/settings_repository.dart';
import '../../domain/ai/ai_model_registry.dart';
import '../../domain/ai/live/gemini_live_client.dart';
import '../../domain/ai/live/live_audio_io.dart';
import '../../domain/media/hongguo/hongguo_assistant_engine.dart';
import '../../domain/media/hongguo_resolver.dart';

enum AssistantConnectionState {
  disconnected,
  connecting,
  ready,
  reconnecting,
  error,
}

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
  bool _disposed = false;
  int _msgSeq = 0;

  String? _activeAssistantMsgId;
  String? _activeUserVoiceMsgId;
  bool _turnReceivedTranscript = false;
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

  Future<void> initialize() async {
    try {
      final settings = await SettingsRepository.getInstance();
      _selectedModelId = settings.hongguoAssistantModel;
      _outputAudioEnabled = settings.hongguoAssistantOutputAudio;
      _preferredCount = settings.hongguoAssistantDefaultCount;
      _hasApiKeys = settings.geminiApiKeys.isNotEmpty;
      _audioOutput.setEnabled(_outputAudioEnabled);
      _syncEngineLocks();
      if (!_disposed) notifyListeners();
    } catch (_) {}
  }

  Future<void> refreshApiKeyStatus() async {
    try {
      final settings = await SettingsRepository.getInstance();
      _hasApiKeys = settings.geminiApiKeys.isNotEmpty;
      if (!_disposed) notifyListeners();
    } catch (_) {}
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
  }) async {
    if (_liveClient.isConnected && !forceFreshSession) {
      return true;
    }

    final settings = await SettingsRepository.getInstance();
    final apiKeys = settings.geminiApiKeys;
    _hasApiKeys = apiKeys.isNotEmpty;
    if (apiKeys.isEmpty) {
      _errorBanner =
          'Chưa có Gemini API Key. Hãy thêm key trong phần Cài đặt ➔ Gemini.';
      _connectionState = AssistantConnectionState.error;
      if (!_disposed) notifyListeners();
      return false;
    }

    _errorBanner = null;
    _connectionState = _messages.isNotEmpty
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

      await _liveClient.connect(
        apiKeys: apiKeys,
        modelId: _selectedModelId,
        systemPrompt: prompt,
        functionDeclarations: decls,
        resumptionHandle: handle,
      );

      _connectionState = AssistantConnectionState.ready;
      _resolvedServerModelId = _liveClient.activeModelId;
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
      _connectionState = AssistantConnectionState.error;
      _errorBanner = e.toString().replaceFirst('Bad state: ', '');
      if (!_disposed) notifyListeners();
      return false;
    }
  }

  /// Chuyển đổi giữa 3 model Live API mà vẫn giữ nguyên toàn bộ đoạn chat & danh sách phim.
  Future<void> switchModel(String newModelId) async {
    if (_selectedModelId == newModelId && _liveClient.isConnected) return;

    await stopMic();
    await _audioOutput.interrupt();
    _selectedModelId = newModelId;
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

    if (_messages.isNotEmpty || engine.lastDisplayedCandidates.isNotEmpty) {
      await ensureConnected(seedContextSnapshot: true, forceFreshSession: true);
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
    _activeUserVoiceMsgId = null;
    _pendingTurnReport = null;
    _isAssistantBusy = false;
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
        _micLevel = level;
        if (!_disposed) notifyListeners();
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
      case LiveSetupCompleteEvent(:final resolvedModelId):
        _connectionState = AssistantConnectionState.ready;
        _resolvedServerModelId = resolvedModelId;
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
        unawaited(_executeAndRespondTools(calls));

      case LiveToolCallCancelledEvent():
        _isAssistantBusy = false;
        _busyLabel = '';
        notifyListeners();

      case LiveTurnCompleteEvent():
        unawaited(_audioOutput.flushTurn());
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
          _connectionState = AssistantConnectionState.disconnected;
          // Nếu đang có cuộc trò chuyện và rớt giữa chừng/hết 10 phút WebSocket -> tự nối lại phiên
          if (_messages.isNotEmpty) {
            unawaited(_autoReconnectAfterDrop(reason));
          } else {
            notifyListeners();
          }
        }

      case LiveErrorEvent(:final message):
        _errorBanner = message;
        _isAssistantBusy = false;
        _busyLabel = '';
        notifyListeners();
    }
  }

  void _handleInputTranscript(String delta, {bool finished = false}) {
    if (_activeUserVoiceMsgId == null) {
      _activeUserVoiceMsgId = 'uv_${++_msgSeq}';
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
      _messages[idx] = cur.copyWith(
        text: '${cur.text}$delta',
        isStreaming: !markDone,
        searchReport: _pendingTurnReport ?? cur.searchReport,
      );
      notifyListeners();
    }
  }

  void _attachReportToActiveAssistant() {
    if (_pendingTurnReport == null) return;
    if (_activeAssistantMsgId == null) {
      _prepareNewAssistantTurn();
    }
    final idx = _messages.indexWhere((m) => m.id == _activeAssistantMsgId);
    if (idx != -1) {
      _messages[idx] = _messages[idx].copyWith(
        searchReport: _pendingTurnReport,
      );
      notifyListeners();
    }
  }

  void _finalizeActiveAssistantTurn() {
    _isAssistantBusy = false;
    _busyLabel = '';
    if (_activeAssistantMsgId != null) {
      final idx = _messages.indexWhere((m) => m.id == _activeAssistantMsgId);
      if (idx != -1) {
        final cur = _messages[idx];
        if (cur.text.trim().isEmpty && cur.searchReport == null) {
          _messages.removeAt(idx);
        } else {
          _messages[idx] = cur.copyWith(
            isStreaming: false,
            searchReport: _pendingTurnReport ?? cur.searchReport,
          );
        }
      }
      _activeAssistantMsgId = null;
      _pendingTurnReport = null;
      _turnReceivedTranscript = false;
    }
    notifyListeners();
  }

  Future<void> _executeAndRespondTools(List<LiveFunctionCall> calls) async {
    _isAssistantBusy = true;
    _busyLabel = 'Đang tra kho Hồng Quả...';
    if (_activeAssistantMsgId == null) {
      _prepareNewAssistantTurn();
    }
    notifyListeners();

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
            _attachReportToActiveAssistant();
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
        _isAssistantBusy = false;
        _busyLabel = '';
        notifyListeners();
      }
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
    if (_disposed) return;
    _connectionState = AssistantConnectionState.reconnecting;
    notifyListeners();

    final resumed = await ensureConnected(
      seedContextSnapshot: _liveClient.lastResumptionHandle == null,
      forceFreshSession: false,
    );
    if (!resumed && !_disposed) {
      // Nếu handle cũ đã hết hạn -> thử tạo phiên sạch + bơm snapshot ngữ cảnh
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
