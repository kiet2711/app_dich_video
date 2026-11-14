import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../data/repository/settings_repository.dart';
import '../../domain/ai/ai_model_registry.dart';
import '../../domain/ai/live/gemini_live_client.dart';
import '../../domain/ai/live/live_audio_io.dart';
import '../../domain/ai/live/live_reply_title_sync.dart';
import '../../domain/media/bilibili/bilibili_assistant_engine.dart';
import '../../domain/media/bilibili/bilibili_srt_service.dart';
import '../../domain/media/bilibili/bilibili_taste_service.dart';
import '../../domain/media/bilibili_resolver.dart';

class BilibiliChatMessage {
  final String id;
  final bool isUser;
  final String text;
  final bool isStreaming;
  final bool isSystemNotice;
  final BilibiliSearchReport? searchReport;

  const BilibiliChatMessage({
    required this.id,
    required this.isUser,
    required this.text,
    this.isStreaming = false,
    this.isSystemNotice = false,
    this.searchReport,
  });

  BilibiliChatMessage copyWith({
    String? text,
    bool? isStreaming,
    BilibiliSearchReport? searchReport,
  }) {
    return BilibiliChatMessage(
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
/// và băm nhỏ / trích xuất SRT cho Trợ lý AI Bilibili.
class BilibiliAssistantController extends ChangeNotifier {
  final BilibiliAssistantEngine engine;
  final GeminiLiveClient _liveClient;
  final LiveMicRecorder _micRecorder;
  final LivePcmAudioOutput _audioOutput;

  StreamSubscription<GeminiLiveEvent>? _eventSub;
  final List<BilibiliChatMessage> _messages = [];

  AssistantConnectionState _connectionState =
      AssistantConnectionState.disconnected;
  String _selectedModelId = 'gemini-3.8-live';
  String _resolvedServerModelId = 'gemini-3.8-live';
  bool _outputAudioEnabled = false;
  int _partitionTid = 0;
  bool _aiAnimeOnly = false;
  int _durationBucket = 0;
  String _recencyBucket = 'any';
  String _sortOrder = 'totalrank';
  int? _preferredCount = 5;
  final List<String> _pinnedKeys = [];
  String _cookie = '';

  bool _isAssistantBusy = false;
  bool _isMicActive = false;
  bool _isAiSpeaking = false;
  double _micLevel = 0.0;
  String _busyLabel = '';
  double? _sttProgress;
  bool _isRunningManualStt = false;
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
  BilibiliSearchReport? _pendingTurnReport;

  BilibiliAssistantController({
    BilibiliResolver? resolver,
    BilibiliSrtService? srtService,
    BilibiliTasteService? tasteService,
    GeminiLiveClient? liveClient,
    LiveMicRecorder? micRecorder,
    LivePcmAudioOutput? audioOutput,
  }) : engine = BilibiliAssistantEngine(
         resolver: resolver,
         srtService: srtService,
         tasteService: tasteService,
       ),
       _liveClient = liveClient ?? GeminiLiveClient(),
       _micRecorder = micRecorder ?? LiveMicRecorder(),
       _audioOutput = audioOutput ?? LivePcmAudioOutput() {
    engine.cookieProvider = () => _cookie;
    _eventSub = _liveClient.events.listen(_handleLiveEvent);
    _audioOutput.onPlaybackStateChanged = () {
      if (_disposed) return;
      _isAiSpeaking = _audioOutput.isPlaying;
      notifyListeners();
    };
  }

  List<BilibiliChatMessage> get messages => List.unmodifiable(_messages);
  AssistantConnectionState get connectionState => _connectionState;
  String get selectedModelId => _selectedModelId;
  String get resolvedServerModelId => _resolvedServerModelId;
  String get resolvedApiVersion => _resolvedApiVersion;
  bool get outputAudioEnabled => _outputAudioEnabled;
  int get partitionTid => _partitionTid;
  bool get aiAnimeOnly => _aiAnimeOnly;
  int get durationBucket => _durationBucket;
  String get recencyBucket => _recencyBucket;
  String get sortOrder => _sortOrder;
  int? get preferredCount => _preferredCount;
  List<String> get pinnedKeys => List.unmodifiable(_pinnedKeys);
  BilibiliTasteProfile? get tasteProfile => engine.tasteService.cachedProfile;
  bool get hasActiveFilters =>
      _aiAnimeOnly ||
      _partitionTid > 0 ||
      _durationBucket > 0 ||
      _recencyBucket != 'any' ||
      _sortOrder != 'totalrank';
  bool get isAssistantBusy => _isAssistantBusy;
  bool get isMicActive => _isMicActive;
  bool get isAiSpeaking => _isAiSpeaking;
  double get micLevel => _micLevel;
  String get busyLabel => _busyLabel;
  double? get sttProgress => _sttProgress;
  bool get isRunningManualStt => _isRunningManualStt;
  String? get errorBanner => _errorBanner;
  bool get hasApiKeys => _hasApiKeys;
  int get apiKeyCount => _apiKeyCount;
  String get maskedActiveKey => _maskedActiveKey;
  LiveConnectionDiagnostics? get lastDiagnostics => _lastDiagnostics;
  bool get hasEstablishedSessionOnce => _hasEstablishedSessionOnce;
  bool get isConnected => _liveClient.isConnected;
  BilibiliSrtSession? get activeSrtSession => engine.activeSrtSession;

  void updateCookie(String sessData) {
    final trimmed = sessData.trim();
    if (trimmed == _cookie) return;
    _cookie = trimmed;
    unawaited(_refreshTasteProfileSilently(forceRefresh: true));
  }

  Future<void> _refreshTasteProfileSilently({bool forceRefresh = false}) async {
    try {
      await engine.warmTasteProfile(forceRefresh: forceRefresh);
      if (!_disposed) notifyListeners();
    } catch (_) {}
  }

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
      _selectedModelId = settings.bilibiliAssistantModel;
      _outputAudioEnabled = settings.bilibiliAssistantOutputAudio;
      _preferredCount = settings.bilibiliAssistantDefaultCount;
      _cookie = settings.bilibiliSessData;
      _audioOutput.setEnabled(_outputAudioEnabled);
      _syncKeyMetadata(settings.geminiApiKeys);
      _syncEngineLocks();
      unawaited(_refreshTasteProfileSilently());
    } catch (_) {}
    if (!_disposed) notifyListeners();
  }

  Future<void> refreshApiKeyStatus() async {
    try {
      final settings = await SettingsRepository.getInstance();
      try {
        await settings.reloadSecureKeys();
      } catch (_) {}
      _cookie = settings.bilibiliSessData;
      _syncKeyMetadata(settings.geminiApiKeys);
      if (_hasApiKeys &&
          (_errorBanner?.contains('API Key') ?? false) &&
          !_liveClient.isConnected) {
        _errorBanner = null;
        _connectionState = AssistantConnectionState.disconnected;
      }
      if (!_disposed) notifyListeners();
    } catch (_) {}
  }

  Future<void> saveQuickGeminiKeys(String rawKeys) async {
    final settings = await SettingsRepository.getInstance();
    settings.geminiApiKeys = rawKeys
        .split(RegExp(r'[,;\n]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    await refreshApiKeyStatus();
    if (_hasApiKeys) {
      _appendSystemNotice(
        'Đã lưu $_apiKeyCount Gemini API Key ($_maskedActiveKey). Đang kết nối phiên Live...',
      );
      await ensureConnected(forceFreshSession: true);
    }
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
      BilibiliUiLocks(
        partitionTid: _partitionTid,
        aiAnimeOnly: _aiAnimeOnly,
        durationBucket: _durationBucket,
        recencyBucket: _recencyBucket,
        sortOrder: _sortOrder,
        lockedCount: _preferredCount,
        pinnedKeys: List<String>.from(_pinnedKeys),
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
      s.bilibiliAssistantOutputAudio = enabled;
    } catch (_) {}
    if (!_disposed) notifyListeners();
  }

  void setPartitionTid(int tid) {
    if (_partitionTid == tid) return;
    _partitionTid = tid;
    _syncEngineLocks();
    notifyListeners();
  }

  void setAiAnimeOnly(bool enabled) {
    if (_aiAnimeOnly == enabled) return;
    _aiAnimeOnly = enabled;
    _syncEngineLocks();
    notifyListeners();
  }

  void setDurationBucket(int bucket) {
    final safe = bucket.clamp(0, 4);
    if (_durationBucket == safe) return;
    _durationBucket = safe;
    _syncEngineLocks();
    notifyListeners();
  }

  void setRecencyBucket(String bucket) {
    final normalized = switch (bucket.trim().toLowerCase()) {
      '24h' || '7d' || '30d' || '90d' || '1y' => bucket.trim().toLowerCase(),
      _ => 'any',
    };
    if (_recencyBucket == normalized) return;
    _recencyBucket = normalized;
    _syncEngineLocks();
    notifyListeners();
  }

  void resetFilters() {
    if (_partitionTid == 0 &&
        !_aiAnimeOnly &&
        _durationBucket == 0 &&
        _recencyBucket == 'any' &&
        _sortOrder == 'totalrank') {
      return;
    }
    _partitionTid = 0;
    _aiAnimeOnly = false;
    _durationBucket = 0;
    _recencyBucket = 'any';
    _sortOrder = 'totalrank';
    _syncEngineLocks();
    notifyListeners();
  }

  void setSortOrder(String order) {
    if (_sortOrder == order) return;
    _sortOrder = order;
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
          s.bilibiliAssistantDefaultCount = safe;
        } catch (_) {}
      }());
    }
    _syncEngineLocks();
    notifyListeners();
  }

  void togglePinCandidate(String key) {
    if (key.isEmpty) return;
    if (_pinnedKeys.contains(key)) {
      _pinnedKeys.remove(key);
    } else {
      if (_pinnedKeys.length >= 5) {
        _pinnedKeys.removeAt(0);
      }
      _pinnedKeys.add(key);
    }
    _syncEngineLocks();
    notifyListeners();
  }

  void unpinCandidate(String key) {
    if (_pinnedKeys.remove(key)) {
      _syncEngineLocks();
      notifyListeners();
    }
  }

  void clearPins() {
    if (_pinnedKeys.isNotEmpty) {
      _pinnedKeys.clear();
      _syncEngineLocks();
      notifyListeners();
    }
  }

  Future<bool> ensureConnected({
    bool seedContextSnapshot = false,
    bool forceFreshSession = false,
    bool forceRefreshModelDiscovery = false,
  }) {
    final inFlight = _connectInFlight;
    if (inFlight != null) return inFlight;

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
    _cookie = settings.bilibiliSessData;
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
        attemptLogs: const ['Không tìm thấy Gemini API Key trong bộ nhớ bảo mật.'],
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
      unawaited(_refreshTasteProfileSilently());
      final prompt = BilibiliAssistantEngine.buildSystemPrompt(
        compactVoiceStyle: _outputAudioEnabled,
        defaultCount: _preferredCount ?? settings.bilibiliAssistantDefaultCount,
      );
      final decls = BilibiliAssistantEngine.buildFunctionDeclarations();
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
      s.bilibiliAssistantModel = newModelId;
    } catch (_) {}

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
        'Đã chuyển sang $displayName (giữ nguyên ngữ cảnh & danh sách video Bilibili).',
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

  Future<void> resetConversation() async {
    await stopMic();
    await _audioOutput.interrupt();
    _liveClient.clearResumptionHandle();
    await _liveClient.disconnect(intentional: true);
    _messages.clear();
    _pinnedKeys.clear();
    engine.srtService.clearCache();
    _activeAssistantMsgId = null;
    _lastAssistantMsgId = null;
    _activeUserVoiceMsgId = null;
    _pendingTurnReport = null;
    _turnExecutedTool = false;
    _inFlightToolCount = 0;
    _lastUserPrompt = '';
    _isAssistantBusy = false;
    _isRunningManualStt = false;
    _sttProgress = null;
    _hasEstablishedSessionOnce = false;
    _autoReconnectInFlight = false;
    _resolvedServerModelId = '';
    _busyLabel = '';
    _errorBanner = null;
    _connectionState = AssistantConnectionState.disconnected;
    _syncEngineLocks();
    if (!_disposed) notifyListeners();
  }

  Future<void> sendTextMessage(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;

    if (_isMicActive) {
      await stopMic();
    }
    await _audioOutput.interrupt();

    _messages.add(
      BilibiliChatMessage(id: 'u_${++_msgSeq}', isUser: true, text: clean),
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

  String buildSummarizePrompt(
    BilibiliAssistantCandidate candidate, {
    String summaryStyle = 'structured',
  }) {
    if (candidate.kind == BilibiliCandidateKind.upChannel) {
      return 'Hãy mở danh sách video nổi bật của kênh UP #${candidate.displayIndex} để mình chọn.';
    }
    final isStory = summaryStyle == 'story';
    if (isStory) {
      return 'Hãy tóm tắt CỐT TRUYỆN #${candidate.displayIndex} (truyền `summary_style: "story"` vào `inspect_video_overview`). Kể mạch truyện trôi chảy bằng tiếng Việt, tên nhân vật/tông môn dùng Hán Việt chuẩn, TUYỆT ĐỐI KHÔNG chèn mốc thời gian `[mm:ss]`. Nếu chưa có phụ đề CC thì tóm tắt trước theo mô tả + bình luận top và hỏi xem có cần tạo phụ đề `.srt` bằng âm thanh không.';
    }
    return 'Hãy tóm tắt Ý CHÍNH #${candidate.displayIndex} (truyền `summary_style: "structured"` vào `inspect_video_overview`) theo từng ý rõ ràng kèm mốc thời gian `[mm:ss]`. Nếu chưa có phụ đề CC thì tóm tắt trước theo mô tả + bình luận top và hỏi xem có cần tạo phụ đề `.srt` bằng âm thanh không.';
  }

  Future<void> askSummarizeCandidate(
    BilibiliAssistantCandidate candidate, {
    String summaryStyle = 'structured',
  }) async {
    await sendTextMessage(
      buildSummarizePrompt(candidate, summaryStyle: summaryStyle),
    );
  }

  /// Trích xuất âm thanh -> CapCut STT để tạo & xuất file `.srt` (KHÔNG tự tóm tắt AI).
  Future<File?> extractAndExportSrtOnly(
    BilibiliAssistantCandidate candidate, {
    int page = 1,
  }) async {
    if (candidate.bvid.isEmpty) return null;
    final cached = engine.srtService.getCachedSession(
      candidate.bvid,
      pageIndex: page,
    );
    if (cached != null) {
      final file = await engine.srtService.exportSrtFile(cached);
      if (!_disposed) {
        _appendSystemNotice('💾 Đã lưu file phụ đề .srt tại: ${file.path}');
      }
      return file;
    }
    if (_isRunningManualStt) return null;

    _isRunningManualStt = true;
    _isAssistantBusy = true;
    _sttProgress = 0.02;
    _busyLabel = 'Đang tạo phụ đề .srt cho #${candidate.displayIndex}...';
    notifyListeners();

    try {
      final res = await engine.runCapCutSttForCandidate(
        candidate,
        page: page,
        onProgress: (p, status) {
          if (_disposed) return;
          _sttProgress = p.clamp(0.0, 1.0);
          _busyLabel = status;
          notifyListeners();
        },
        onSearchResultsUpdated: _refreshCardsReportInHistory,
      );
      if (_disposed) return null;
      if (res.session == null) {
        _appendSystemNotice('⚠️ ${res.statusNote}');
        return null;
      }
      final file = await engine.srtService.exportSrtFile(res.session!);
      if (!_disposed) {
        _appendSystemNotice(
          '💾 Đã tạo & lưu file .srt (${res.session!.document.size} dòng) tại: ${file.path}',
        );
      }
      return file;
    } finally {
      if (!_disposed) {
        _isRunningManualStt = false;
        _sttProgress = null;
        if (_activeAssistantMsgId == null) {
          _isAssistantBusy = false;
          _busyLabel = '';
        }
        notifyListeners();
      }
    }
  }

  /// Phương án A: Bấm trực tiếp trên thẻ `#k` để trích âm thanh + CapCut STT tạo SRT
  /// (chia nhiều đoạn nếu video dài) và gửi cho AI tóm tắt theo [summaryStyle].
  Future<void> runManualCapCutSttAndSummarize(
    BilibiliAssistantCandidate candidate, {
    int page = 1,
    String summaryStyle = 'structured',
  }) async {
    if (_isRunningManualStt || candidate.bvid.isEmpty) return;
    final style = summaryStyle == 'story' ? 'story' : 'structured';

    _isRunningManualStt = true;
    _isAssistantBusy = true;
    _sttProgress = 0.02;
    _busyLabel = 'Đang trích xuất SRT nhanh cho #${candidate.displayIndex}...';
    notifyListeners();

    try {
      final res = await engine.runCapCutSttForCandidate(
        candidate,
        page: page,
        onProgress: (p, status) {
          if (_disposed) return;
          _sttProgress = p.clamp(0.0, 1.0);
          _busyLabel = status;
          notifyListeners();
        },
        onSearchResultsUpdated: _refreshCardsReportInHistory,
      );

      if (_disposed) return;

      if (res.session == null) {
        _appendSystemNotice('⚠️ ${res.statusNote}');
        return;
      }

      final session = res.session!;
      _appendSystemNotice(
        '✅ Đã nạp SRT (${session.document.size} câu · chia ${session.totalChunks} đoạn) cho #${candidate.displayIndex} (${candidate.bvid}). Đang nhờ Gemini Live tóm tắt...',
      );

      final String prompt;
      if (style == 'story') {
        prompt = session.isLongVideo
            ? 'Video #${candidate.displayIndex} (${candidate.bvid}) vừa tạo xong SRT gồm ${session.totalChunks} đoạn. Hãy gọi `read_srt_chunk(bvid: "${candidate.bvid}", chunk_number: 1, summary_style: "story")` để đọc và kể lại CỐT TRUYỆN Đoạn 1 trôi chảy bằng tiếng Việt (tên riêng Hán Việt, TUYỆT ĐỐI KHÔNG chèn mốc `[mm:ss]`), đồng thời báo video còn ${session.totalChunks - 1} đoạn sau nếu mình muốn nghe tiếp.'
            : 'Video #${candidate.displayIndex} (${candidate.bvid}) vừa tạo xong SRT (${session.totalChunks} đoạn). Hãy gọi `inspect_video_overview(bvid: "${candidate.bvid}", summary_style: "story")` để đọc trọn phụ đề và kể lại toàn bộ CỐT TRUYỆN trôi chảy bằng tiếng Việt (tên riêng Hán Việt, TUYỆT ĐỐI KHÔNG chèn mốc `[mm:ss]`).';
      } else {
        prompt = session.isLongVideo
            ? 'Video #${candidate.displayIndex} (${candidate.bvid}) vừa tạo xong SRT gồm ${session.totalChunks} đoạn. Hãy gọi `read_srt_chunk(bvid: "${candidate.bvid}", chunk_number: 1, summary_style: "structured")` để đọc và tóm tắt Ý CHÍNH Đoạn 1 kèm mốc `[mm:ss]`, đồng thời liệt kê khung giờ các đoạn sau để mình chọn nếu muốn đào sâu tiếp.'
            : 'Video #${candidate.displayIndex} (${candidate.bvid}) vừa tạo xong SRT (${session.totalChunks} đoạn). Hãy gọi `inspect_video_overview(bvid: "${candidate.bvid}", summary_style: "structured")` để đọc trọn SRT và tóm tắt Ý CHÍNH chi tiết kèm mốc `[mm:ss]`.';
      }

      await sendTextMessage(prompt);
    } finally {
      if (!_disposed) {
        _isRunningManualStt = false;
        _sttProgress = null;
        if (_activeAssistantMsgId == null) {
          _isAssistantBusy = false;
          _busyLabel = '';
        }
        notifyListeners();
      }
    }
  }

  /// Xuất file `.srt` từ cache SRT của thẻ `#k` (nếu đã nạp CC hoặc chạy STT).
  Future<File?> exportSrtForCandidate(BilibiliAssistantCandidate candidate) async {
    final bvid = candidate.bvid;
    if (bvid.isEmpty) return null;
    final session = engine.srtService.getCachedSession(bvid);
    if (session == null) return null;
    final file = await engine.srtService.exportSrtFile(session);
    if (!_disposed) {
      _appendSystemNotice('💾 Đã lưu file SRT tại: ${file.path}');
    }
    return file;
  }

  void _refreshCardsReportInHistory(BilibiliSearchReport updated) {
    for (var i = _messages.length - 1; i >= 0; i--) {
      final msg = _messages[i];
      if (msg.searchReport != null) {
        _messages[i] = msg.copyWith(searchReport: updated);
        break;
      }
    }
    if (!_disposed) notifyListeners();
  }

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

    _activeUserVoiceMsgId = 'uv_${++_msgSeq}';
    _messages.add(
      BilibiliChatMessage(
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
        if ((_micLevel - level).abs() > 0.05 ||
            (level == 0.0 && _micLevel != 0.0)) {
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
      _activeUserVoiceMsgId = null;
    }
    if (!_disposed) notifyListeners();
  }

  void _prepareNewAssistantTurn() {
    _activeAssistantMsgId = 'a_${++_msgSeq}';
    _lastAssistantMsgId = _activeAssistantMsgId;
    _turnReceivedTranscript = false;
    _pendingTurnReport = null;
    _messages.add(
      BilibiliChatMessage(
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
      BilibiliChatMessage(
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
          _attachReportToActiveAssistant();
          _isAssistantBusy = true;
          if (_inFlightToolCount == 0 && _busyLabel.isEmpty) {
            _busyLabel = 'Gemini đang tổng hợp câu trả lời...';
          }
          notifyListeners();
          break;
        }
        if (isGenerationOnly) {
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
        BilibiliChatMessage(
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
        final parsed = LiveReplyTitleSync.extractAiTitlesFromLiveReply(
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

  void _attachReportToMessageId(String msgId, BilibiliSearchReport report) {
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
    BilibiliSearchReport? finalReport;
    var hasNonEmptyReplyText = false;

    if (finishedMsgId != null) {
      final idx = _messages.indexWhere((m) => m.id == finishedMsgId);
      if (idx != -1) {
        final cur = _messages[idx];
        var effectiveReport = _pendingTurnReport ?? cur.searchReport;
        hasNonEmptyReplyText = cur.text.trim().isNotEmpty;
        if (effectiveReport != null && hasNonEmptyReplyText) {
          final parsed = LiveReplyTitleSync.extractAiTitlesFromLiveReply(
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

    if (finishedMsgId != null &&
        !executedToolThisTurn &&
        finalReport == null &&
        hasNonEmptyReplyText &&
        pendingPrompt.isNotEmpty &&
        BilibiliAssistantEngine.looksLikeDiscoveryQuery(pendingPrompt)) {
      _lastUserPrompt = '';
      unawaited(_attachAutoFallbackCardsIfNeeded(finishedMsgId, pendingPrompt));
    } else if (finishedMsgId != null &&
        finalReport != null &&
        finalReport.candidates.any(BilibiliAssistantEngine.isUntranslatedTitle)) {
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
    BilibiliSearchReport report, {
    bool includeShortSummaryInMessage = false,
  }) async {
    if (_disposed) return;
    final missing = report.candidates
        .where(BilibiliAssistantEngine.isUntranslatedTitle)
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
            'Bạn là chuyên gia dịch tiêu đề Bilibili (từ công nghệ, đời sống tới phim ảnh/anime) sang Tiếng Việt tự nhiên, dùng âm Hán Việt chuẩn cho phim/nhân vật, TUYỆT ĐỐI CẤM Pinyin.',
        userPrompt: BilibiliAssistantEngine.buildLiveTitleTranslationPrompt(
          missing,
          includeShortSummary: includeShortSummaryInMessage,
        ),
      );
      if (_disposed || liveReply.trim().isEmpty) return;

      final maxIdx = report.candidates.fold<int>(
        report.candidates.length,
        (m, c) => c.displayIndex > m ? c.displayIndex : m,
      );
      final parsed = LiveReplyTitleSync.extractAiTitlesFromLiveReply(
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
          ? '${curMsg.text}\n\n📌 **Danh sách thật trên Bilibili:**\n$liveReply'
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
    _busyLabel = 'Đang tra dữ liệu Bilibili...';
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
      _appendSystemNotice(
        'Đã làm mới phiên Gemini Live tự động (giữ nguyên ngữ cảnh & SRT).',
      );
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
        _liveClient.clearResumptionHandle();
        final freshOk = await ensureConnected(
          seedContextSnapshot: true,
          forceFreshSession: true,
        );
        if (freshOk) {
          _appendSystemNotice(
            'Phiên cũ vừa hết hạn (${reason ?? "timeout"}), đã tự khởi tạo phiên mới và giữ nguyên danh sách.',
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
