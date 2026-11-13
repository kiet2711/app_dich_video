import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../ai_model_registry.dart';

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
  const LiveSetupCompleteEvent(this.resolvedModelId);
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
  const LiveTurnCompleteEvent();
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

/// Client WebSocket `BidiGenerateContent` cho Gemini Live API (`v1beta`).
/// Hỗ trợ auto-resolve model ID, xoay vòng API key, `sessionResumption`, `contextWindowCompression`,
/// và parse đồng thời cả Audio PCM 24kHz, Transcript chữ và Function Calling.
class GeminiLiveClient {
  static const String wsBaseUrl =
      'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';

  static final Map<String, List<String>> _discoveredBidiModelsCache = {};

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
  String _activeApiKey = '';
  String? _lastResumptionHandle;

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
  String? get lastResumptionHandle => _lastResumptionHandle;

  void clearResumptionHandle() {
    _lastResumptionHandle = null;
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

    // Nếu là biến thể Flash Live, thử khớp mờ tên chứa flash & live
    if (cleanReq.contains('flash') && cleanReq.contains('live')) {
      for (final m in normalizedAvailable) {
        if (m.contains('flash') && m.contains('live')) {
          return m;
        }
      }
    }
    return cleanReq;
  }

  /// Dò danh sách model hỗ trợ `bidiGenerateContent` của API key (có cache trong phiên).
  Future<List<String>> fetchBidiSupportedModels(String apiKey) async {
    final cleanKey = apiKey.trim();
    if (cleanKey.isEmpty) return const [];
    if (_discoveredBidiModelsCache.containsKey(cleanKey)) {
      return _discoveredBidiModelsCache[cleanKey]!;
    }

    try {
      final res = await _dio.get<dynamic>(
        'https://generativelanguage.googleapis.com/v1beta/models',
        queryParameters: {'key': cleanKey, 'pageSize': 100},
        options: Options(validateStatus: (s) => s != null && s < 500),
      );
      if (res.statusCode == 200 && res.data is Map) {
        final rawModels = (res.data as Map)['models'];
        if (rawModels is List) {
          final result = <String>[];
          for (final m in rawModels) {
            if (m is! Map) continue;
            final methods = (m['supportedGenerationMethods'] as List?) ?? [];
            final supportsBidi = methods.any(
              (x) => x.toString().toLowerCase().contains('bidigeneratecontent'),
            );
            if (supportsBidi) {
              final name = (m['name'] ?? '')
                  .toString()
                  .replaceFirst(RegExp(r'^models/'), '')
                  .trim();
              if (name.isNotEmpty) result.add(name);
            }
          }
          if (result.isNotEmpty) {
            _discoveredBidiModelsCache[cleanKey] = result;
            return result;
          }
        }
      }
    } catch (e) {
      debugPrint('[GeminiLive] Không tra được danh sách bidi models: $e');
    }
    return const [];
  }

  /// Tạo payload `setup` chuẩn cho WebSocket `BidiGenerateContent`.
  static Map<String, dynamic> buildSetupPayload({
    required String modelId,
    required String systemPrompt,
    required List<Map<String, dynamic>> functionDeclarations,
    String voiceName = 'Aoede',
    String? resumptionHandle,
    bool enableCompression = true,
  }) {
    final cleanModel = modelId.startsWith('models/')
        ? modelId
        : 'models/$modelId';
    return {
      'setup': {
        'model': cleanModel,
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          'temperature': 0.35,
          'speechConfig': {
            'voiceConfig': {
              'prebuiltVoiceConfig': {'voiceName': voiceName},
            },
          },
        },
        'systemInstruction': {
          'parts': [
            {'text': systemPrompt},
          ],
        },
        if (functionDeclarations.isNotEmpty)
          'tools': [
            {'functionDeclarations': functionDeclarations},
          ],
        'inputAudioTranscription': <String, dynamic>{},
        'outputAudioTranscription': <String, dynamic>{},
        if (enableCompression)
          'contextWindowCompression': {
            'slidingWindow': <String, dynamic>{},
          },
        if (resumptionHandle != null && resumptionHandle.trim().isNotEmpty)
          'sessionResumption': {'handle': resumptionHandle.trim()}
        else
          'sessionResumption': <String, dynamic>{},
      },
    };
  }

  /// Kết nối (hoặc kết nối lại) WebSocket tới Gemini Live API, tự xoay vòng key nếu gặp lỗi.
  Future<void> connect({
    required List<String> apiKeys,
    required String modelId,
    required String systemPrompt,
    required List<Map<String, dynamic>> functionDeclarations,
    String? resumptionHandle,
    String voiceName = 'Aoede',
  }) async {
    final validKeys = apiKeys
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (validKeys.isEmpty) {
      throw StateError(
        'Chưa có Gemini API Key. Hãy thêm key trong phần Cài đặt ➔ Gemini.',
      );
    }

    await disconnect(intentional: true);
    _intentionalClose = false;

    Object? lastError;
    for (final apiKey in validKeys) {
      final availableBidi = await fetchBidiSupportedModels(apiKey);
      final preferredModel = matchPreferredBidiModel(modelId, availableBidi);
      final candidates = <String>{
        preferredModel,
        ...(AiModelRegistry.liveModelCandidateIds[modelId] ?? [modelId]),
      }.toList();

      for (final candidateModel in candidates) {
        // Thử lần 1 với resumptionHandle (nếu có); nếu handle cũ hết hạn, tự thử lại sạch
        final handleAttempts =
            (resumptionHandle != null && resumptionHandle.trim().isNotEmpty)
            ? <String?>[resumptionHandle.trim(), null]
            : <String?>[null];

        for (final handle in handleAttempts) {
          try {
            await _connectSingleSocket(
              apiKey: apiKey,
              modelId: candidateModel,
              systemPrompt: systemPrompt,
              functionDeclarations: functionDeclarations,
              voiceName: voiceName,
              resumptionHandle: handle,
            );
            _activeApiKey = apiKey;
            _activeModelId = candidateModel;
            return;
          } catch (e) {
            lastError = e;
            debugPrint(
              '[GeminiLive] Kết nối thất bại ($candidateModel, key=...${apiKey.length > 4 ? apiKey.substring(apiKey.length - 4) : apiKey}): $e',
            );
          }
        }
      }
    }

    throw StateError(
      'Không thể kết nối Gemini Live API ($modelId): $lastError',
    );
  }

  Future<void> _connectSingleSocket({
    required String apiKey,
    required String modelId,
    required String systemPrompt,
    required List<Map<String, dynamic>> functionDeclarations,
    required String voiceName,
    String? resumptionHandle,
  }) async {
    final uri = Uri.parse('$wsBaseUrl?key=${Uri.encodeComponent(apiKey)}');
    final ws = await WebSocket.connect(uri.toString()).timeout(
      const Duration(seconds: 12),
    );

    _socket = ws;
    _isConnected = true;
    _isSetupDone = false;
    _setupCompleter = Completer<void>();

    _socketSub = ws.listen(
      (raw) => _handleRawServerMessage(raw, modelId),
      onError: (Object err) {
        if (!_intentionalClose) {
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
          _setupCompleter?.completeError(
            StateError(
              'WebSocket đóng trước setupComplete (code=$code, reason=$reason)',
            ),
          );
        }
        if (!wasIntentional) {
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
    );
    ws.add(jsonEncode(setupPayload));

    try {
      await _setupCompleter!.future.timeout(const Duration(seconds: 12));
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
  }) {
    final effectiveModel = modelId.isNotEmpty ? modelId : _activeModelId;

    if (json.containsKey('setupComplete')) {
      _isSetupDone = true;
      _activeModelId = effectiveModel;
      if (!(_setupCompleter?.isCompleted ?? true)) {
        _setupCompleter?.complete();
      }
      _events.add(LiveSetupCompleteEvent(effectiveModel));
    }

    final errorObj = json['error'];
    if (errorObj is Map) {
      final msg = (errorObj['message'] ?? errorObj.toString()).toString();
      _events.add(LiveErrorEvent(msg));
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
          if (c is! Map) continue;
          final rawArgs = c['args'];
          final argsMap = rawArgs is Map
              ? Map<String, dynamic>.from(rawArgs)
              : <String, dynamic>{};
          calls.add(
            LiveFunctionCall(
              id: (c['id'] ?? '').toString(),
              name: (c['name'] ?? '').toString(),
              args: argsMap,
            ),
          );
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
          for (final part in parts) {
            if (part is! Map) continue;
            // Bỏ qua phần suy luận nội bộ (`thought: true`) của Extended Thinking
            if (part['thought'] == true) continue;

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
        }
      }

      if (serverContent['turnComplete'] == true ||
          serverContent['generationComplete'] == true) {
        _events.add(const LiveTurnCompleteEvent());
      }
    }
  }

  void _handleRawServerMessage(dynamic raw, String modelId) {
    try {
      final text = raw is String ? raw : utf8.decode(raw as List<int>);
      if (text.trim().isEmpty) return;
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        handleDecodedServerJson(
          Map<String, dynamic>.from(decoded),
          modelId: modelId,
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

  /// Trả kết quả hàm về cho Gemini Live tiếp tục tổng hợp câu trả lời.
  void sendToolResponses(List<LiveFunctionResponse> responses) {
    if (responses.isEmpty) return;
    _sendJson({
      'toolResponse': {
        'functionResponses': responses.map((r) => r.toJson()).toList(),
      },
    });
  }

  String get activeApiKey => _activeApiKey;

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
