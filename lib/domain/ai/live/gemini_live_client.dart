import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../ai_model_registry.dart';

enum LiveSetupProfile {
  full,
  compatible,
  minimal,
}

class LiveConnectionDiagnostics {
  final bool success;
  final String requestedModelId;
  final String resolvedModelId;
  final String apiVersion;
  final LiveSetupProfile? setupProfile;
  final String maskedKey;
  final int apiKeyCount;
  final int latencyMs;
  final List<String> availableBidiModels;
  final String summaryMessage;
  final List<String> attemptLogs;
  final DateTime checkedAt;

  const LiveConnectionDiagnostics({
    required this.success,
    required this.requestedModelId,
    required this.resolvedModelId,
    required this.apiVersion,
    required this.setupProfile,
    required this.maskedKey,
    required this.apiKeyCount,
    required this.latencyMs,
    required this.availableBidiModels,
    required this.summaryMessage,
    required this.attemptLogs,
    required this.checkedAt,
  });

  String get profileLabel {
    return switch (setupProfile) {
      LiveSetupProfile.full => 'Đầy đủ (Audio + Tools + Transcript + Resumption)',
      LiveSetupProfile.compatible => 'Tương thích (Bỏ compression / voice)',
      LiveSetupProfile.minimal => 'Tối giản (Audio + Tools)',
      null => 'Chưa khớp',
    };
  }
}

class LiveFunctionCall {
  final String id;
  final String name;
  final Map<String, dynamic> args;

  const LiveFunctionCall({
    required this.id,
    required this.name,
    required this.args,
  });
}

class LiveFunctionResponse {
  final String id;
  final String name;
  final Map<String, dynamic> response;

  const LiveFunctionResponse({
    required this.id,
    required this.name,
    required this.response,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'response': response,
  };
}

sealed class GeminiLiveEvent {
  const GeminiLiveEvent();
}

class LiveSetupCompleteEvent extends GeminiLiveEvent {
  final String resolvedModelId;
  final String apiVersion;
  const LiveSetupCompleteEvent(
    this.resolvedModelId, {
    this.apiVersion = 'v1beta',
  });
}

class LiveInputTranscriptEvent extends GeminiLiveEvent {
  final String text;
  final bool finished;
  const LiveInputTranscriptEvent(this.text, {this.finished = false});
}

class LiveOutputTranscriptEvent extends GeminiLiveEvent {
  final String text;
  final bool finished;
  const LiveOutputTranscriptEvent(this.text, {this.finished = false});
}

class LiveOutputTextEvent extends GeminiLiveEvent {
  final String text;
  const LiveOutputTextEvent(this.text);
}

class LiveOutputAudioEvent extends GeminiLiveEvent {
  final Uint8List pcmBytes;
  const LiveOutputAudioEvent(this.pcmBytes);
}

class LiveToolCallEvent extends GeminiLiveEvent {
  final List<LiveFunctionCall> calls;
  const LiveToolCallEvent(this.calls);
}

class LiveToolCallCancelledEvent extends GeminiLiveEvent {
  final List<String> ids;
  const LiveToolCallCancelledEvent(this.ids);
}

class LiveTurnCompleteEvent extends GeminiLiveEvent {
  final String? interactionStatus;
  final bool isGenerationOnly;
  const LiveTurnCompleteEvent({
    this.interactionStatus,
    this.isGenerationOnly = false,
  });
}

class LiveInterruptedEvent extends GeminiLiveEvent {
  const LiveInterruptedEvent();
}

class LiveSessionResumptionEvent extends GeminiLiveEvent {
  final String handle;
  const LiveSessionResumptionEvent(this.handle);
}

class LiveGoAwayEvent extends GeminiLiveEvent {
  final String timeLeft;
  const LiveGoAwayEvent(this.timeLeft);
}

class LiveConnectionClosedEvent extends GeminiLiveEvent {
  final int? closeCode;
  final String? reason;
  final bool intentional;
  const LiveConnectionClosedEvent({
    this.closeCode,
    this.reason,
    this.intentional = false,
  });
}

class LiveErrorEvent extends GeminiLiveEvent {
  final String message;
  const LiveErrorEvent(this.message);
}

/// Client WebSocket `BidiGenerateContent` cho Gemini Live API (`v1beta` + `v1alpha`).
/// Hỗ trợ auto-resolve model ID theo từng API Key, setup fallback đa tầng (không văng 1007),
/// `sessionResumption`, `contextWindowCompression`, và chẩn đoán kết nối chi tiết.
class GeminiLiveClient {
  static const String wsBetaBaseUrl =
      'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';
  static const String wsAlphaBaseUrl =
      'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent';

  static String wsUrlForVersion(String apiVersion) =>
      apiVersion == 'v1alpha' ? wsAlphaBaseUrl : wsBetaBaseUrl;

  static final Map<String, ({List<String> models, String? error})>
  _discoveredModelsCache = {};

  final Dio _dio;
  final StreamController<GeminiLiveEvent> _events =
      StreamController<GeminiLiveEvent>.broadcast();

  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSub;
  Completer<void>? _setupCompleter;
  bool _isConnected = false;
  bool _isSetupDone = false;
  bool _intentionalClose = false;
  String _activeModelId = 'gemini-3.8-live';
  String _activeApiVersion = 'v1beta';
  String _activeApiKey = '';
  String? _lastResumptionHandle;
  String? _lastSetupErrorFromServer;
  LiveConnectionDiagnostics? _lastDiagnostics;

  GeminiLiveClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
            ),
          );

  Stream<GeminiLiveEvent> get events => _events.stream;
  bool get isConnected => _isConnected && _isSetupDone;
  String get activeModelId => _activeModelId;
  String get activeApiVersion => _activeApiVersion;
  String get activeApiKey => _activeApiKey;
  String? get lastResumptionHandle => _lastResumptionHandle;
  LiveConnectionDiagnostics? get lastDiagnostics => _lastDiagnostics;

  void clearResumptionHandle() {
    _lastResumptionHandle = null;
  }

  static String maskApiKey(String key) {
    final clean = key.trim();
    if (clean.isEmpty) return '(trống)';
    if (clean.length <= 10) return clean;
    return '${clean.substring(0, 6)}...${clean.substring(clean.length - 4)}';
  }

  /// Chọn model ID khớp nhất từ danh sách model thực tế có hỗ trợ `bidiGenerateContent`.
  static String matchPreferredBidiModel(
    String requestedModelId,
    List<String> availableBidiModels,
  ) {
    final cleanReq = requestedModelId
        .trim()
        .replaceFirst(RegExp(r'^models/'), '');
    if (availableBidiModels.isEmpty) return cleanReq;

    final normalizedAvailable = availableBidiModels
        .map((e) => e.trim().replaceFirst(RegExp(r'^models/'), ''))
        .where((e) => e.isNotEmpty)
        .toList();

    final candidates =
        AiModelRegistry.liveModelCandidateIds[cleanReq] ?? [cleanReq];
    for (final candidate in candidates) {
      if (normalizedAvailable.contains(candidate)) {
        return candidate;
      }
    }

    if (cleanReq.contains('thinking')) {
      for (final m in normalizedAvailable) {
        if (m.contains('thinking') && m.contains('live')) {
          return m;
        }
      }
    }

    if (cleanReq.contains('flash') && cleanReq.contains('live')) {
      for (final m in normalizedAvailable) {
        if (m.contains('flash') && (m.contains('live') || m.contains('native-audio'))) {
          return m;
        }
      }
    }
    return cleanReq;
  }

  /// Dò danh sách model hỗ trợ `bidiGenerateContent` qua REST API (`v1beta` hoặc `v1alpha`, có phân trang).
  Future<({List<String> models, String? error})> discoverBidiSupportedModels(
    String apiKey, {
    String apiVersion = 'v1beta',
    bool forceRefresh = false,
  }) async {
    final cleanKey = apiKey.trim();
    if (cleanKey.isEmpty) {
      return (models: const <String>[], error: 'API Key trống');
    }

    final cacheKey = '$apiVersion::$cleanKey';
    if (!forceRefresh && _discoveredModelsCache.containsKey(cacheKey)) {
      final cached = _discoveredModelsCache[cacheKey]!;
      if (cached.models.isNotEmpty) return cached;
    }

    final discovered = <String>[];
    String? pageToken;
    String? apiError;

    try {
      for (var page = 0; page < 5; page++) {
        final query = <String, dynamic>{
          'key': cleanKey,
          'pageSize': 100,
          if (pageToken != null && pageToken.isNotEmpty) 'pageToken': pageToken,
        };
        final res = await _dio.get<dynamic>(
          'https://generativelanguage.googleapis.com/$apiVersion/models',
          queryParameters: query,
          options: Options(validateStatus: (s) => s != null && s < 600),
        );

        if (res.statusCode != 200) {
          final data = res.data;
          if (data is Map && data['error'] is Map) {
            final msg = (data['error']['message'] ?? '').toString().trim();
            apiError = 'HTTP ${res.statusCode}: $msg';
          } else {
            apiError = 'HTTP ${res.statusCode}';
          }
          break;
        }

        if (res.data is Map) {
          final map = res.data as Map;
          final rawModels = map['models'];
          if (rawModels is List) {
            for (final m in rawModels) {
              if (m is! Map) continue;
              final methods = (m['supportedGenerationMethods'] as List?) ?? [];
              final supportsBidi = methods.any(
                (x) =>
                    x.toString().toLowerCase().contains('bidigeneratecontent'),
              );
              if (supportsBidi) {
                final name = (m['name'] ?? '')
                    .toString()
                    .replaceFirst(RegExp(r'^models/'), '')
                    .trim();
                if (name.isNotEmpty && !discovered.contains(name)) {
                  discovered.add(name);
                }
              }
            }
          }
          pageToken = (map['nextPageToken'] ?? '').toString().trim();
          if (pageToken.isEmpty) break;
        } else {
          break;
        }
      }
    } catch (e) {
      apiError = e.toString();
      debugPrint('[GeminiLive] Không tra được /$apiVersion/models: $e');
    }

    final result = (models: discovered, error: apiError);
    if (discovered.isNotEmpty) {
      _discoveredModelsCache[cacheKey] = result;
    }
    return result;
  }

  /// Backward-compatible wrapper cho tests & callers cũ.
  Future<List<String>> fetchBidiSupportedModels(String apiKey) async {
    final res = await discoverBidiSupportedModels(apiKey, apiVersion: 'v1beta');
    return res.models;
  }

  /// Tạo payload `setup` chuẩn cho WebSocket `BidiGenerateContent` theo profile tương thích.
  static Map<String, dynamic> buildSetupPayload({
    required String modelId,
    required String systemPrompt,
    required List<Map<String, dynamic>> functionDeclarations,
    String voiceName = 'Aoede',
    String? resumptionHandle,
    bool enableCompression = true,
    int compressionTriggerTokens = 32768,
    int compressionTargetTokens = 16384,
    String? translationTargetLanguageCode,
    bool echoTargetLanguage = false,
    LiveSetupProfile profile = LiveSetupProfile.full,
    bool includeNonBlockingBehavior = false,
  }) {
    final cleanModel = modelId.startsWith('models/')
        ? modelId
        : 'models/$modelId';
    final isExtendedThinking = modelId.toLowerCase().contains('extended-thinking');
    final targetLang = translationTargetLanguageCode?.trim() ?? '';
    final isLiveTranslate =
        modelId.toLowerCase().contains('live-translate') ||
        targetLang.isNotEmpty;
    final effectiveTargetLang = targetLang.isNotEmpty ? targetLang : 'vi';

    final preparedDecls = functionDeclarations.map((decl) {
      final copy = Map<String, dynamic>.from(decl);
      if (includeNonBlockingBehavior) {
        copy['behavior'] = 'NON_BLOCKING';
      } else {
        copy.remove('behavior');
      }
      return copy;
    }).toList();

    final generationConfig = <String, dynamic>{
      'responseModalities': ['AUDIO'],
      if (!isLiveTranslate &&
          profile == LiveSetupProfile.full &&
          voiceName.trim().isNotEmpty)
        'speechConfig': {
          'voiceConfig': {
            'prebuiltVoiceConfig': {'voiceName': voiceName.trim()},
          },
        },
    };

    final setupMap = <String, dynamic>{
      'model': cleanModel,
      'generationConfig': generationConfig,
      if (!isLiveTranslate || systemPrompt.trim().isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': systemPrompt},
          ],
        },
      if (isLiveTranslate)
        'translationConfig': {
          'targetLanguageCode': effectiveTargetLang,
          if (echoTargetLanguage) 'echoTargetLanguage': true,
        },
      if (!isLiveTranslate && preparedDecls.isNotEmpty)
        'tools': [
          {'functionDeclarations': preparedDecls},
        ],
    };

    if (profile == LiveSetupProfile.full || profile == LiveSetupProfile.compatible) {
      setupMap['inputAudioTranscription'] = <String, dynamic>{};
      setupMap['outputAudioTranscription'] = <String, dynamic>{};
      if (!isLiveTranslate || profile == LiveSetupProfile.full) {
        if (resumptionHandle != null && resumptionHandle.trim().isNotEmpty) {
          setupMap['sessionResumption'] = {'handle': resumptionHandle.trim()};
        } else {
          setupMap['sessionResumption'] = <String, dynamic>{};
        }
      }
    }

    if (profile == LiveSetupProfile.full) {
      if (isExtendedThinking) {
        setupMap['thinkingConfig'] = {'thinkingLevel': 'low'};
      }
      if (enableCompression) {
        setupMap['contextWindowCompression'] = {
          'triggerTokens': compressionTriggerTokens,
          'slidingWindow': {'targetTokens': compressionTargetTokens},
        };
      }
    }

    return {'setup': setupMap};
  }

  /// Kết nối WebSocket tới Gemini Live API, tự dò version + model + setup fallback, KHÔNG spam event rớt phiên khi chưa handshake xong.
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
    final validKeys = apiKeys
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (validKeys.isEmpty) {
      const msg =
          'Chưa có Gemini API Key. Hãy nhập và Lưu key trong Cài đặt ➔ Gemini.';
      _lastDiagnostics = LiveConnectionDiagnostics(
        success: false,
        requestedModelId: modelId,
        resolvedModelId: '',
        apiVersion: 'v1beta',
        setupProfile: null,
        maskedKey: '(không có)',
        apiKeyCount: 0,
        latencyMs: 0,
        availableBidiModels: const [],
        summaryMessage: msg,
        attemptLogs: const [msg],
        checkedAt: DateTime.now(),
      );
      throw StateError(msg);
    }

    await disconnect(intentional: true);
    _intentionalClose = false;

    final attemptLogs = <String>[];
    final combinedAvailableModels = <String>{};
    final prefersAlphaFirst = modelId.toLowerCase().contains('extended-thinking');
    final versionOrder = prefersAlphaFirst
        ? const ['v1alpha', 'v1beta']
        : const ['v1beta', 'v1alpha'];

    for (var kIdx = 0; kIdx < validKeys.length; kIdx++) {
      final apiKey = validKeys[kIdx];
      final masked = maskApiKey(apiKey);

      final betaDiscovery = await discoverBidiSupportedModels(
        apiKey,
        apiVersion: 'v1beta',
        forceRefresh: forceRefreshModelDiscovery,
      );
      final alphaDiscovery = await discoverBidiSupportedModels(
        apiKey,
        apiVersion: 'v1alpha',
        forceRefresh: forceRefreshModelDiscovery,
      );

      combinedAvailableModels.addAll(betaDiscovery.models);
      combinedAvailableModels.addAll(alphaDiscovery.models);

      if (betaDiscovery.error != null) {
        attemptLogs.add('Key $masked REST v1beta: ${betaDiscovery.error}');
      }
      if (alphaDiscovery.error != null && betaDiscovery.models.isEmpty) {
        attemptLogs.add('Key $masked REST v1alpha: ${alphaDiscovery.error}');
      }

      // Nếu key rõ ràng invalid / bị khóa trên cả 2 REST endpoint -> ghi nhận và chuyển key tiếp theo
      final hardAuthError = _extractHardKeyError(betaDiscovery.error ?? alphaDiscovery.error);
      if (hardAuthError != null &&
          betaDiscovery.models.isEmpty &&
          alphaDiscovery.models.isEmpty) {
        attemptLogs.add('Key $masked từ chối xác thực: $hardAuthError');
        continue;
      }

      for (final apiVersion in _prioritizeVersions(
        versionOrder: versionOrder,
        requestedModelId: modelId,
        betaModels: betaDiscovery.models,
        alphaModels: alphaDiscovery.models,
      )) {
        final discoveredForVer = apiVersion == 'v1alpha'
            ? (alphaDiscovery.models.isNotEmpty
                  ? alphaDiscovery.models
                  : betaDiscovery.models)
            : (betaDiscovery.models.isNotEmpty
                  ? betaDiscovery.models
                  : alphaDiscovery.models);

        final preferredModel = matchPreferredBidiModel(
          modelId,
          discoveredForVer,
        );

        final aliasCandidates =
            AiModelRegistry.liveModelCandidateIds[modelId] ?? [modelId];
        final candidates = <String>{
          preferredModel,
          ...aliasCandidates,
        }.where((s) => s.trim().isNotEmpty).toList();

        // Nếu API Key thực sự trả về danh sách Bidi models trên endpoint này,
        // ưu tiên chạy những model thực sự xuất hiện trong danh sách trước để đỡ thử model 404.
        if (discoveredForVer.isNotEmpty) {
          final inDiscovered = candidates
              .where((c) => discoveredForVer.contains(c))
              .toList();
          if (inDiscovered.isNotEmpty) {
            final others = candidates
                .where((c) => !discoveredForVer.contains(c))
                .toList();
            candidates
              ..clear()
              ..addAll(inDiscovered)
              ..addAll(others.take(1));
          }
        }

        for (final candidateModel in candidates) {
          final profiles = <LiveSetupProfile>[
            LiveSetupProfile.full,
            LiveSetupProfile.compatible,
            LiveSetupProfile.minimal,
          ];

          for (final profile in profiles) {
            final includeNonBlocking =
                candidateModel.toLowerCase().contains('extended-thinking') &&
                profile != LiveSetupProfile.minimal;

            final handleAttempts =
                (resumptionHandle != null &&
                    resumptionHandle.trim().isNotEmpty &&
                    profile != LiveSetupProfile.minimal)
                ? <String?>[resumptionHandle.trim(), null]
                : <String?>[null];

            var abortRemainingProfilesForModel = false;
            for (final handle in handleAttempts) {
              final sw = Stopwatch()..start();
              try {
                await _connectSingleSocket(
                  apiKey: apiKey,
                  apiVersion: apiVersion,
                  modelId: candidateModel,
                  systemPrompt: systemPrompt,
                  functionDeclarations: functionDeclarations,
                  voiceName: voiceName,
                  resumptionHandle: handle,
                  profile: profile,
                  includeNonBlockingBehavior: includeNonBlocking,
                  enableCompression: enableCompression,
                  compressionTriggerTokens: compressionTriggerTokens,
                  compressionTargetTokens: compressionTargetTokens,
                  translationTargetLanguageCode: translationTargetLanguageCode,
                  echoTargetLanguage: echoTargetLanguage,
                );
                sw.stop();
                _activeApiKey = apiKey;
                _activeModelId = candidateModel;
                _activeApiVersion = apiVersion;

                final diag = LiveConnectionDiagnostics(
                  success: true,
                  requestedModelId: modelId,
                  resolvedModelId: candidateModel,
                  apiVersion: apiVersion,
                  setupProfile: profile,
                  maskedKey: masked,
                  apiKeyCount: validKeys.length,
                  latencyMs: sw.elapsedMilliseconds,
                  availableBidiModels: combinedAvailableModels.toList(),
                  summaryMessage:
                      'Đã kết nối phiên Live thành công ($candidateModel · $apiVersion · ${sw.elapsedMilliseconds}ms).',
                  attemptLogs: attemptLogs,
                  checkedAt: DateTime.now(),
                );
                _lastDiagnostics = diag;
                return diag;
              } catch (e) {
                sw.stop();
                final errText = _formatFriendlyAttemptError(e);
                attemptLogs.add(
                  '[$masked | $apiVersion | $candidateModel | ${profile.name}] $errText',
                );
                debugPrint(
                  '[GeminiLive] Handshake fail [$masked | $apiVersion | $candidateModel | ${profile.name}]: $e',
                );

                // Nếu lỗi rõ ràng là Model không tồn tại (1008 / not found) hoặc API key chết -> không cần thử minimal trên cùng model nữa
                final lower = e.toString().toLowerCase();
                if (lower.contains('not found') ||
                    lower.contains('not supported for bidi') ||
                    lower.contains('api key not valid') ||
                    lower.contains('permission denied') ||
                    lower.contains('1008')) {
                  abortRemainingProfilesForModel = true;
                  break;
                }
              }
            }
            if (abortRemainingProfilesForModel) break;
          }
        }
      }
    }

    final summary = _summarizeFailure(
      modelId: modelId,
      maskedKey: maskApiKey(validKeys.first),
      keyCount: validKeys.length,
      availableModels: combinedAvailableModels.toList(),
      attemptLogs: attemptLogs,
    );

    _lastDiagnostics = LiveConnectionDiagnostics(
      success: false,
      requestedModelId: modelId,
      resolvedModelId: '',
      apiVersion: prefersAlphaFirst ? 'v1alpha' : 'v1beta',
      setupProfile: null,
      maskedKey: maskApiKey(validKeys.first),
      apiKeyCount: validKeys.length,
      latencyMs: 0,
      availableBidiModels: combinedAvailableModels.toList(),
      summaryMessage: summary,
      attemptLogs: attemptLogs,
      checkedAt: DateTime.now(),
    );

    throw StateError(summary);
  }

  static String? _extractHardKeyError(String? err) {
    if (err == null || err.isEmpty) return null;
    final lower = err.toLowerCase();
    if (lower.contains('api key not valid') ||
        lower.contains('http 400') ||
        lower.contains('http 403')) {
      return err;
    }
    return null;
  }

  static String _formatFriendlyAttemptError(Object e) {
    final s = e.toString().replaceFirst('Bad state: ', '').trim();
    if (s.length > 180) return '${s.substring(0, 180)}...';
    return s;
  }

  static String _summarizeFailure({
    required String modelId,
    required String maskedKey,
    required int keyCount,
    required List<String> availableModels,
    required List<String> attemptLogs,
  }) {
    final joined = attemptLogs.join(' | ').toLowerCase();
    if (joined.contains('api key not valid') ||
        joined.contains('api_key_invalid')) {
      return 'API Key ($maskedKey) không hợp lệ hoặc đã bị thu hồi. Hãy kiểm tra lại trong Cài đặt.';
    }
    if (joined.contains('quota') ||
        joined.contains('resource_exhausted') ||
        joined.contains('429')) {
      return 'Key ($maskedKey) đã hết hạn mức Live API (429). Hãy thêm key khác hoặc đổi model.';
    }
    if (joined.contains('socketexception') ||
        joined.contains('handshakeexception') ||
        joined.contains('timed out') ||
        joined.contains('failed host lookup')) {
      return 'Không kết nối được máy chủ Google Live WebSocket (kiểm tra mạng/VPN/DNS).';
    }
    if (availableModels.isNotEmpty) {
      return 'Key $maskedKey ($keyCount key) chưa mở/khớp được với $modelId. Các model Live khả dụng trên key: ${availableModels.join(", ")}.';
    }
    final lastDetail = attemptLogs.isNotEmpty ? attemptLogs.last : 'Không rõ nguyên nhân';
    return 'Không kết nối được $modelId (Key $maskedKey): $lastDetail';
  }

  static List<String> _prioritizeVersions({
    required List<String> versionOrder,
    required String requestedModelId,
    required List<String> betaModels,
    required List<String> alphaModels,
  }) {
    final cleanReq = requestedModelId.trim().replaceFirst(RegExp(r'^models/'), '');
    final aliases = AiModelRegistry.liveModelCandidateIds[cleanReq] ?? [cleanReq];
    final inBeta = aliases.any((a) => betaModels.contains(a));
    final inAlpha = aliases.any((a) => alphaModels.contains(a));
    if (inAlpha && !inBeta) return const ['v1alpha', 'v1beta'];
    if (inBeta && !inAlpha) return const ['v1beta', 'v1alpha'];
    return versionOrder;
  }

  Future<void> _connectSingleSocket({
    required String apiKey,
    required String apiVersion,
    required String modelId,
    required String systemPrompt,
    required List<Map<String, dynamic>> functionDeclarations,
    required String voiceName,
    required LiveSetupProfile profile,
    required bool includeNonBlockingBehavior,
    bool enableCompression = true,
    int compressionTriggerTokens = 32768,
    int compressionTargetTokens = 16384,
    String? translationTargetLanguageCode,
    bool echoTargetLanguage = false,
    String? resumptionHandle,
  }) async {
    final baseUrl = wsUrlForVersion(apiVersion);
    final uri = Uri.parse('$baseUrl?key=${Uri.encodeComponent(apiKey)}');
    final ws = await WebSocket.connect(uri.toString()).timeout(
      const Duration(seconds: 10),
    );

    _socket = ws;
    _isConnected = true;
    _isSetupDone = false;
    _lastSetupErrorFromServer = null;
    _setupCompleter = Completer<void>();

    var setupDoneOnThisSocket = false;

    _socketSub = ws.listen(
      (raw) {
        final beforeSetup = _isSetupDone;
        _handleRawServerMessage(raw, modelId, apiVersion: apiVersion);
        if (!beforeSetup && _isSetupDone) {
          setupDoneOnThisSocket = true;
        }
      },
      onError: (Object err) {
        if (setupDoneOnThisSocket && !_intentionalClose) {
          _events.add(LiveErrorEvent('Lỗi kết nối Live WebSocket: $err'));
        }
        if (!(_setupCompleter?.isCompleted ?? true)) {
          _setupCompleter?.completeError(err);
        }
      },
      onDone: () {
        final code = ws.closeCode;
        final reason = ws.closeReason;
        final wasIntentional = _intentionalClose;
        _isConnected = false;
        _isSetupDone = false;

        if (!(_setupCompleter?.isCompleted ?? true)) {
          final serverDetail = _lastSetupErrorFromServer;
          final reasonText = [
            if (code != null) 'code=$code',
            if (reason != null && reason.isNotEmpty) reason,
            if (serverDetail != null && serverDetail.isNotEmpty) serverDetail,
          ].join(' · ');
          _setupCompleter?.completeError(
            StateError(
              'WebSocket đóng trước setupComplete (${reasonText.isNotEmpty ? reasonText : "closed"})',
            ),
          );
          return;
        }

        // CHỈ phát sự kiện rớt phiên nếu phiên đã từng setupComplete thành công (tránh vòng lặp nháy lỗi khi connect thất bại)
        if (setupDoneOnThisSocket && !wasIntentional) {
          _events.add(
            LiveConnectionClosedEvent(
              closeCode: code,
              reason: reason,
              intentional: false,
            ),
          );
        }
      },
      cancelOnError: false,
    );

    final setupPayload = buildSetupPayload(
      modelId: modelId,
      systemPrompt: systemPrompt,
      functionDeclarations: functionDeclarations,
      voiceName: voiceName,
      resumptionHandle: resumptionHandle,
      enableCompression: enableCompression,
      compressionTriggerTokens: compressionTriggerTokens,
      compressionTargetTokens: compressionTargetTokens,
      translationTargetLanguageCode: translationTargetLanguageCode,
      echoTargetLanguage: echoTargetLanguage,
      profile: profile,
      includeNonBlockingBehavior: includeNonBlockingBehavior,
    );
    ws.add(jsonEncode(setupPayload));

    try {
      await _setupCompleter!.future.timeout(const Duration(seconds: 10));
    } catch (e) {
      await _cleanupSocketOnly();
      rethrow;
    }
  }

  /// Giải mã và xử lý một frame JSON nhận từ server Gemini Live.
  @visibleForTesting
  void handleDecodedServerJson(
    Map<String, dynamic> json, {
    String modelId = '',
    String apiVersion = 'v1beta',
  }) {
    final effectiveModel = modelId.isNotEmpty ? modelId : _activeModelId;

    if (json.containsKey('setupComplete')) {
      _isSetupDone = true;
      _activeModelId = effectiveModel;
      _activeApiVersion = apiVersion;
      if (!(_setupCompleter?.isCompleted ?? true)) {
        _setupCompleter?.complete();
      }
      _events.add(
        LiveSetupCompleteEvent(effectiveModel, apiVersion: apiVersion),
      );
    }

    final errorObj = json['error'];
    if (errorObj is Map) {
      final msg = (errorObj['message'] ?? errorObj.toString()).toString();
      if (!_isSetupDone) {
        _lastSetupErrorFromServer = msg;
      } else {
        _events.add(LiveErrorEvent(msg));
      }
    }

    final resumption = json['sessionResumptionUpdate'];
    if (resumption is Map) {
      final newHandle = (resumption['newHandle'] ?? '').toString().trim();
      final resumable = resumption['resumable'] == true;
      if (newHandle.isNotEmpty && resumable) {
        _lastResumptionHandle = newHandle;
        _events.add(LiveSessionResumptionEvent(newHandle));
      }
    }

    final goAway = json['goAway'];
    if (goAway is Map) {
      final timeLeft = (goAway['timeLeft'] ?? '').toString();
      _events.add(LiveGoAwayEvent(timeLeft));
    }

    final toolCall = json['toolCall'];
    if (toolCall is Map) {
      final rawCalls = toolCall['functionCalls'];
      if (rawCalls is List && rawCalls.isNotEmpty) {
        final calls = <LiveFunctionCall>[];
        for (final c in rawCalls) {
          final parsed = _parseFunctionCall(c);
          if (parsed != null) calls.add(parsed);
        }
        if (calls.isNotEmpty) {
          _events.add(LiveToolCallEvent(calls));
        }
      }
    }

    final cancellation = json['toolCallCancellation'];
    if (cancellation is Map) {
      final rawIds = cancellation['ids'];
      if (rawIds is List && rawIds.isNotEmpty) {
        _events.add(
          LiveToolCallCancelledEvent(
            rawIds.map((e) => e.toString()).toList(),
          ),
        );
      }
    }

    final serverContent = json['serverContent'];
    if (serverContent is Map) {
      if (serverContent['interrupted'] == true) {
        _events.add(const LiveInterruptedEvent());
      }

      final inputTx = serverContent['inputTranscription'];
      if (inputTx is Map) {
        final text = (inputTx['text'] ?? '').toString();
        if (text.isNotEmpty) {
          _events.add(
            LiveInputTranscriptEvent(
              text,
              finished: inputTx['finished'] == true,
            ),
          );
        }
      }

      final outputTx = serverContent['outputTranscription'];
      if (outputTx is Map) {
        final text = (outputTx['text'] ?? '').toString();
        if (text.isNotEmpty) {
          _events.add(
            LiveOutputTranscriptEvent(
              text,
              finished: outputTx['finished'] == true,
            ),
          );
        }
      }

      final modelTurn = serverContent['modelTurn'];
      if (modelTurn is Map) {
        final parts = modelTurn['parts'];
        if (parts is List) {
          final modelTurnCalls = <LiveFunctionCall>[];
          for (final part in parts) {
            if (part is! Map) continue;
            // Bỏ qua phần suy luận nội bộ (`thought: true`) của Extended Thinking
            if (part['thought'] == true) continue;

            final fnCall = _parseFunctionCall(part['functionCall']);
            if (fnCall != null) {
              modelTurnCalls.add(fnCall);
            }

            final text = (part['text'] ?? '').toString();
            if (text.isNotEmpty) {
              _events.add(LiveOutputTextEvent(text));
            }

            final inlineData = part['inlineData'];
            if (inlineData is Map) {
              final mime = (inlineData['mimeType'] ?? '').toString().toLowerCase();
              final b64 = (inlineData['data'] ?? '').toString();
              if (mime.contains('audio/pcm') && b64.isNotEmpty) {
                try {
                  final bytes = base64Decode(b64);
                  if (bytes.isNotEmpty) {
                    _events.add(LiveOutputAudioEvent(bytes));
                  }
                } catch (_) {}
              }
            }
          }
          if (modelTurnCalls.isNotEmpty) {
            _events.add(LiveToolCallEvent(modelTurnCalls));
          }
        }
      }

      final rawInteractionStatus =
          (serverContent['interactionStatus'] ??
                  serverContent['interaction_status'] ??
                  json['interactionStatus'] ??
                  json['interaction_status'])
              ?.toString()
              .trim()
              .toUpperCase();
      final interactionStatus =
          (rawInteractionStatus != null && rawInteractionStatus.isNotEmpty)
              ? rawInteractionStatus
              : null;
      final isTurnComplete = serverContent['turnComplete'] == true;
      final isGenerationComplete = serverContent['generationComplete'] == true;
      if (isTurnComplete || isGenerationComplete) {
        _events.add(
          LiveTurnCompleteEvent(
            interactionStatus: interactionStatus,
            isGenerationOnly: !isTurnComplete && isGenerationComplete,
          ),
        );
      }
    }

    // Xử lý sự kiện top-level `interactionStatus` nếu tách khỏi `serverContent`
    if (serverContent is! Map) {
      final topStatus = (json['interactionStatus'] ?? json['interaction_status'])
          ?.toString()
          .trim()
          .toUpperCase();
      if (topStatus == 'IDLE') {
        _events.add(const LiveTurnCompleteEvent(interactionStatus: 'IDLE'));
      }
    }
  }

  static LiveFunctionCall? _parseFunctionCall(dynamic raw) {
    if (raw is! Map) return null;
    final name = (raw['name'] ?? '').toString().trim();
    if (name.isEmpty) return null;
    final rawArgs = raw['args'];
    Map<String, dynamic> argsMap = <String, dynamic>{};
    if (rawArgs is Map) {
      argsMap = Map<String, dynamic>.from(rawArgs);
    } else if (rawArgs is String && rawArgs.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawArgs);
        if (decoded is Map) {
          argsMap = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
    }
    return LiveFunctionCall(
      id: (raw['id'] ?? '').toString(),
      name: name,
      args: argsMap,
    );
  }

  void _handleRawServerMessage(
    dynamic raw,
    String modelId, {
    String apiVersion = 'v1beta',
  }) {
    try {
      final text = raw is String ? raw : utf8.decode(raw as List<int>);
      if (text.trim().isEmpty) return;
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        handleDecodedServerJson(
          Map<String, dynamic>.from(decoded),
          modelId: modelId,
          apiVersion: apiVersion,
        );
      }
    } catch (e) {
      debugPrint('[GeminiLive] Lỗi parse JSON từ server: $e');
    }
  }

  void _sendJson(Map<String, dynamic> payload) {
    final ws = _socket;
    if (ws == null || ws.readyState != WebSocket.open) {
      throw StateError('WebSocket Gemini Live chưa sẵn sàng.');
    }
    ws.add(jsonEncode(payload));
  }

  /// Gửi tin nhắn chữ từ người dùng trong phiên đang chạy.
  void sendClientText(String text, {bool turnComplete = true}) {
    _sendJson({
      'clientContent': {
        'turns': [
          {
            'role': 'user',
            'parts': [
              {'text': text},
            ],
          },
        ],
        'turnComplete': turnComplete,
      },
    });
  }

  /// Bơm lịch sử hội thoại / ngữ cảnh rút gọn (khi chuyển model hoặc mở phiên mới sau giới hạn).
  void sendHistoryTurns(
    List<Map<String, dynamic>> turns, {
    bool turnComplete = false,
  }) {
    if (turns.isEmpty) return;
    _sendJson({
      'clientContent': {
        'turns': turns,
        'turnComplete': turnComplete,
      },
    });
  }

  /// Gửi luồng PCM 16kHz 16-bit mono từ micro lên server.
  void sendRealtimeAudioPcm16k(Uint8List pcmBytes) {
    if (pcmBytes.isEmpty) return;
    _sendJson({
      'realtimeInput': {
        'audio': {
          'mimeType': 'audio/pcm;rate=16000',
          'data': base64Encode(pcmBytes),
        },
      },
    });
  }

  /// Báo cho server biết người dùng vừa ngừng nói.
  void sendAudioStreamEnd() {
    if (!isConnected) return;
    _sendJson({
      'realtimeInput': {'audioStreamEnd': true},
    });
  }

  /// Dùng chính model Gemini Live (một phiên phụ ngắn hạn, không dùng REST model thường hay MLKit)
  /// để hoàn thành nhanh một lượt hỏi-đáp một lần (vd dịch tên phim Hán Việt còn thiếu).
  Future<String> runOneShotLivePrompt({
    required List<String> apiKeys,
    required String modelId,
    required String systemPrompt,
    required String userPrompt,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final orderedKeys = <String>[
      if (isConnected && _activeApiKey.trim().isNotEmpty) _activeApiKey.trim(),
      for (final k in apiKeys)
        if (k.trim().isNotEmpty && k.trim() != _activeApiKey.trim()) k.trim(),
    ];
    if (orderedKeys.isEmpty) return '';

    final effectiveModel =
        (isConnected && _activeModelId.trim().isNotEmpty)
            ? _activeModelId.trim()
            : modelId.trim();

    final helper = GeminiLiveClient(dio: _dio);
    final transcriptBuf = StringBuffer();
    final textBuf = StringBuffer();
    var receivedTranscript = false;
    final done = Completer<String>();
    StreamSubscription<GeminiLiveEvent>? sub;

    try {
      await helper.connect(
        apiKeys: orderedKeys,
        modelId: effectiveModel,
        systemPrompt: systemPrompt,
        functionDeclarations: const [],
        forceRefreshModelDiscovery: false,
      );

      sub = helper.events.listen((event) {
        if (done.isCompleted) return;
        switch (event) {
          case LiveOutputTranscriptEvent(:final text):
            receivedTranscript = true;
            transcriptBuf.write(text);
          case LiveOutputTextEvent(:final text):
            if (!receivedTranscript) {
              textBuf.write(text);
            }
          case LiveTurnCompleteEvent(
            :final interactionStatus,
            :final isGenerationOnly,
          ):
            if (!isGenerationOnly && interactionStatus != 'IN_PROGRESS') {
              final res = receivedTranscript
                  ? transcriptBuf.toString()
                  : textBuf.toString();
              done.complete(res.trim());
            }
          case LiveErrorEvent():
            final res = receivedTranscript
                ? transcriptBuf.toString()
                : textBuf.toString();
            done.complete(res.trim());
          case LiveConnectionClosedEvent(:final intentional):
            if (!intentional) {
              final res = receivedTranscript
                  ? transcriptBuf.toString()
                  : textBuf.toString();
              done.complete(res.trim());
            }
          default:
            break;
        }
      });

      helper.sendClientText(userPrompt, turnComplete: true);
      return await done.future.timeout(
        timeout,
        onTimeout: () => (receivedTranscript
                ? transcriptBuf.toString()
                : textBuf.toString())
            .trim(),
      );
    } catch (_) {
      return (receivedTranscript
              ? transcriptBuf.toString()
              : textBuf.toString())
          .trim();
    } finally {
      await sub?.cancel();
      await helper.dispose();
    }
  }

  /// Trả kết quả hàm về cho Gemini Live tiếp tục tổng hợp câu trả lời.
  void sendToolResponses(List<LiveFunctionResponse> responses) {
    if (responses.isEmpty) return;
    _sendJson({
      'toolResponse': {
        'functionResponses': responses.map((r) => r.toJson()).toList(),
      },
    });
  }

  Future<void> _cleanupSocketOnly() async {
    _isConnected = false;
    _isSetupDone = false;
    try {
      await _socketSub?.cancel();
      _socketSub = null;
      await _socket?.close();
      _socket = null;
    } catch (_) {}
  }

  Future<void> disconnect({bool intentional = true}) async {
    _intentionalClose = intentional;
    await _cleanupSocketOnly();
    if (intentional) {
      _events.add(const LiveConnectionClosedEvent(intentional: true));
    }
  }

  Future<void> dispose() async {
    await disconnect(intentional: true);
    await _events.close();
  }
}
