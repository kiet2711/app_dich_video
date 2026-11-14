import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Đóng gói mảng PCM raw (16-bit LE) thành định dạng WAV chuẩn RIFF để phát ổn định đa nền tảng.
Uint8List buildWavFromPcmBytes(
  Uint8List pcmBytes, {
  int sampleRate = 24000,
  int channels = 1,
  int bitsPerSample = 16,
}) {
  final byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
  final blockAlign = channels * (bitsPerSample ~/ 8);
  final dataLength = pcmBytes.lengthInBytes;
  final totalLength = 36 + dataLength;

  final buffer = Uint8List(44 + dataLength);
  final view = ByteData.view(buffer.buffer);

  // "RIFF"
  buffer[0] = 0x52;
  buffer[1] = 0x49;
  buffer[2] = 0x46;
  buffer[3] = 0x46;
  view.setUint32(4, totalLength, Endian.little);
  // "WAVE"
  buffer[8] = 0x57;
  buffer[9] = 0x41;
  buffer[10] = 0x56;
  buffer[11] = 0x45;
  // "fmt "
  buffer[12] = 0x66;
  buffer[13] = 0x6D;
  buffer[14] = 0x74;
  buffer[15] = 0x20;
  view.setUint32(16, 16, Endian.little); // PCM subchunk size
  view.setUint16(20, 1, Endian.little); // Linear PCM
  view.setUint16(22, channels, Endian.little);
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, byteRate, Endian.little);
  view.setUint16(32, blockAlign, Endian.little);
  view.setUint16(34, bitsPerSample, Endian.little);
  // "data"
  buffer[36] = 0x64;
  buffer[37] = 0x61;
  buffer[38] = 0x74;
  buffer[39] = 0x61;
  view.setUint32(40, dataLength, Endian.little);

  if (dataLength > 0) {
    buffer.setRange(44, 44 + dataLength, pcmBytes);
  }
  return buffer;
}

/// Bộ thu âm Micro luồng PCM 16kHz 16-bit mono gửi trực tiếp lên Gemini Live API.
class LiveMicRecorder {
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _audioSub;
  StreamSubscription<Amplitude>? _ampSub;
  bool _isRecording = false;
  bool _disposed = false;

  bool get isRecording => _isRecording;

  Future<bool> hasPermission() async {
    try {
      _recorder ??= AudioRecorder();
      return await _recorder!.hasPermission();
    } catch (e) {
      debugPrint('[LiveMicRecorder] Lỗi kiểm tra quyền mic: $e');
      return false;
    }
  }

  /// Bắt đầu thu luồng PCM 16kHz mono. Trả về `true` nếu mở mic thành công.
  Future<bool> startStreaming({
    required void Function(Uint8List pcmChunk) onPcmData,
    void Function(double normalizedLevel)? onAmplitude,
    void Function(Object error)? onError,
  }) async {
    if (_disposed) return false;
    await stop();

    try {
      _recorder ??= AudioRecorder();
      final permitted = await _recorder!.hasPermission();
      if (!permitted) return false;

      const config = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 256000,
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
      );

      final stream = await _recorder!.startStream(config);
      _isRecording = true;

      _audioSub = stream.listen(
        (chunk) {
          if (chunk.isNotEmpty && _isRecording) {
            onPcmData(chunk);
          }
        },
        onError: (Object err) {
          debugPrint('[LiveMicRecorder] Lỗi stream mic: $err');
          onError?.call(err);
        },
        onDone: () {
          _isRecording = false;
        },
      );

      if (onAmplitude != null) {
        _ampSub = _recorder!
            .onAmplitudeChanged(const Duration(milliseconds: 90))
            .listen((amp) {
              // dBFS thường trong khoảng [-60, 0] -> chuẩn hóa về [0.0, 1.0]
              final clamped = amp.current.clamp(-60.0, 0.0);
              final level = ((clamped + 60.0) / 60.0).clamp(0.0, 1.0);
              onAmplitude(level);
            }, onError: (_) {});
      }

      return true;
    } catch (e) {
      _isRecording = false;
      debugPrint('[LiveMicRecorder] Không thể bắt đầu thu mic: $e');
      onError?.call(e);
      return false;
    }
  }

  Future<void> stop() async {
    _isRecording = false;
    try {
      await _ampSub?.cancel();
      _ampSub = null;
      await _audioSub?.cancel();
      _audioSub = null;
      if (_recorder != null && await _recorder!.isRecording()) {
        await _recorder!.stop();
      }
    } catch (e) {
      debugPrint('[LiveMicRecorder] Lỗi dừng thu mic: $e');
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    try {
      await _recorder?.dispose();
    } catch (_) {}
    _recorder = null;
  }
}

/// Bộ phát âm thanh phản hồi 24kHz PCM từ Gemini Live.
///
/// Trên Android (`AudioTrack` MODE_STREAM) và iOS (`AVAudioEngine` + `AVAudioPlayerNode`),
/// PCM 24kHz được phát nối tiếp trực tiếp trên RAM thành một luồng liên tục, không
/// cắt file WAV 0.8s và không làm đứt/lặp giọng khi tải lại `AudioPlayer`.
/// Trên nền tảng khác (vd Windows desktop), tự động fallback sang hàng đợi WAV đã
/// khóa thứ tự FIFO và reset trạng thái `just_audio` sạch sẽ sau từng đoạn.
class LivePcmAudioOutput {
  static const int _sampleRate = 24000;
  static const int _nativeStartCushionBytes = 5760; // ~120ms ở 24kHz 16-bit mono
  static const Duration _nativeStartFlushDelay = Duration(milliseconds: 110);
  static const String nativeChannelName = 'com.capcut.capsub/live_audio';

  final int firstSegmentBytes;
  final int normalSegmentBytes;
  final MethodChannel _nativeChannel;
  final bool _preferNativeStream;

  List<AudioPlayer>? _fallbackPlayers;
  final BytesBuilder _pendingPcm = BytesBuilder(copy: false);
  final Queue<String> _segmentQueue = Queue<String>();

  Future<void> _nativeChain = Future<void>.value();
  Future<void> _flushChain = Future<void>.value();
  Timer? _nativeStartFlushTimer;
  bool _nativeFallbackActivated = false;
  bool _nativeConfigured = false;
  bool _hasStartedNativeTurn = false;

  bool _enabled = false;
  bool _isPlaying = false;
  bool _isPaused = false;
  bool _isDrainRunning = false;
  bool _hasStartedTurnSegment = false;
  bool _disposed = false;
  int _playbackEpoch = 0;
  int _segmentCounter = 0;
  int _activePlayerIdx = 0;
  AudioPlayer? _currentPlayingPlayer;
  double _volume = 1.0;
  double _playbackRate = 1.0;
  Completer<void>? _pauseResumeCompleter;
  Directory? _tempDir;
  VoidCallback? onPlaybackStateChanged;

  LivePcmAudioOutput({
    this.firstSegmentBytes = 19200, // ~0.4s ở 24kHz 16-bit mono (fallback)
    this.normalSegmentBytes = 57600, // ~1.2s để hạn chế ngắt nhịp (fallback)
    MethodChannel? nativeChannel,
    bool? enableNativeStream,
  }) : _nativeChannel = nativeChannel ?? const MethodChannel(nativeChannelName),
       _preferNativeStream =
           enableNativeStream ?? (Platform.isIOS || Platform.isAndroid) {
    if (_preferNativeStream) {
      _nativeChannel.setMethodCallHandler(_handleNativeCallback);
    }
  }

  bool get _usingNativeStream =>
      _preferNativeStream && !_nativeFallbackActivated;

  bool get isEnabled => _enabled;
  bool get isPlaying => _isPlaying;
  bool get isPaused => _isPaused;
  double get volume => _volume;
  double get playbackRate => _playbackRate;

  Future<dynamic> _handleNativeCallback(MethodCall call) async {
    if (_disposed) return null;
    if (call.method == 'onPlaybackStateChanged') {
      final playing = call.arguments == true;
      if (!playing) {
        _hasStartedNativeTurn = false;
      }
      _setPlaying(playing);
    }
    return null;
  }

  List<AudioPlayer> _ensureFallbackPlayers() {
    return _fallbackPlayers ??= <AudioPlayer>[
      AudioPlayer(
        handleInterruptions: false,
        androidApplyAudioAttributes: false,
        handleAudioSessionActivation: false,
      ),
      AudioPlayer(
        handleInterruptions: false,
        androidApplyAudioAttributes: false,
        handleAudioSessionActivation: false,
      ),
    ];
  }

  void setEnabled(bool enabled) {
    _enabled = enabled;
    if (!enabled) {
      unawaited(interrupt());
    }
  }

  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    if (_disposed) return;
    if (_usingNativeStream) {
      await _invokeNativeSafe('setVolume', {'volume': _volume});
    }
    final players = _fallbackPlayers;
    if (players != null) {
      for (final player in players) {
        try {
          await player.setVolume(_volume);
        } catch (_) {}
      }
    }
  }

  Future<void> setPlaybackRate(double rate) async {
    _playbackRate = rate.clamp(0.75, 2.0);
    if (_disposed) return;
    if (_usingNativeStream) {
      await _invokeNativeSafe('setPlaybackRate', {'rate': _playbackRate});
    }
    final players = _fallbackPlayers;
    if (players != null) {
      for (final player in players) {
        try {
          await player.setSpeed(_playbackRate);
        } catch (_) {}
      }
    }
  }

  Future<void> setPaused(bool paused) async {
    if (_disposed || _isPaused == paused) return;
    _isPaused = paused;
    if (_usingNativeStream) {
      await _invokeNativeSafe('setPaused', {'paused': paused});
      if (_usingNativeStream) {
        if (paused) {
          _setPlaying(false);
        }
        return;
      }
    }

    final players = _fallbackPlayers;
    if (players == null) return;
    if (paused) {
      _pauseResumeCompleter ??= Completer<void>();
      for (final player in players) {
        try {
          if (player.playing) {
            await player.pause();
          }
        } catch (_) {}
      }
    } else {
      if (_pauseResumeCompleter != null &&
          !_pauseResumeCompleter!.isCompleted) {
        _pauseResumeCompleter!.complete();
      }
      _pauseResumeCompleter = null;
      if (_isDrainRunning && _enabled) {
        final currentPlayer = _currentPlayingPlayer;
        if (currentPlayer != null) {
          try {
            if (currentPlayer.processingState != ProcessingState.idle &&
                currentPlayer.processingState != ProcessingState.completed) {
              await currentPlayer.setVolume(_volume);
              await currentPlayer.setSpeed(_playbackRate);
              unawaited(currentPlayer.play().catchError((_) => null));
            }
          } catch (_) {}
        }
      }
    }
  }

  Future<Directory> _ensureTempDir() async {
    if (_tempDir != null && await _tempDir!.exists()) {
      return _tempDir!;
    }
    final base = await getTemporaryDirectory();
    final dir = Directory(
      '${base.path}${Platform.pathSeparator}hg_live_audio',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _tempDir = dir;
    return dir;
  }

  /// Nạp thêm chunk PCM 24kHz nhận từ Gemini Live.
  Future<void> enqueuePcmChunk(Uint8List pcmBytes) async {
    if (_disposed || !_enabled || pcmBytes.isEmpty) return;

    if (_usingNativeStream) {
      _pendingPcm.add(pcmBytes);
      if (_hasStartedNativeTurn ||
          _pendingPcm.length >= _nativeStartCushionBytes) {
        _hasStartedNativeTurn = true;
        _nativeStartFlushTimer?.cancel();
        _nativeStartFlushTimer = null;
        final batch = _pendingPcm.takeBytes();
        if (batch.isNotEmpty) {
          await _enqueueNativeBatch(batch);
        }
      } else {
        _nativeStartFlushTimer ??= Timer(_nativeStartFlushDelay, () {
          _nativeStartFlushTimer = null;
          if (_disposed || !_enabled || !_usingNativeStream) return;
          if (_pendingPcm.length > 0) {
            _hasStartedNativeTurn = true;
            final batch = _pendingPcm.takeBytes();
            if (batch.isNotEmpty) {
              unawaited(_enqueueNativeBatch(batch));
            }
          }
        });
      }
      return;
    }

    await _enqueueFallbackChunk(pcmBytes);
  }

  Future<void> _enqueueFallbackChunk(Uint8List pcmBytes) async {
    if (_disposed || !_enabled || pcmBytes.isEmpty) return;
    _pendingPcm.add(pcmBytes);

    final threshold = _hasStartedTurnSegment
        ? normalSegmentBytes
        : firstSegmentBytes;
    if (_pendingPcm.length >= threshold) {
      _hasStartedTurnSegment = true;
      await _scheduleFallbackFlush();
    }
  }

  /// Đẩy nốt phần âm thanh còn lại khi Gemini hoàn thành lượt nói (`turnComplete`).
  Future<void> flushTurn() async {
    if (_disposed || !_enabled) {
      _pendingPcm.clear();
      _hasStartedTurnSegment = false;
      _hasStartedNativeTurn = false;
      _nativeStartFlushTimer?.cancel();
      _nativeStartFlushTimer = null;
      return;
    }

    if (_usingNativeStream) {
      _nativeStartFlushTimer?.cancel();
      _nativeStartFlushTimer = null;
      _hasStartedNativeTurn = false;
      if (_pendingPcm.length > 0) {
        final batch = _pendingPcm.takeBytes();
        if (batch.isNotEmpty) {
          await _enqueueNativeBatch(batch);
        }
      }
      return;
    }

    _hasStartedTurnSegment = false;
    if (_pendingPcm.length > 0) {
      await _scheduleFallbackFlush();
    }
  }

  Future<void> _enqueueNativeBatch(Uint8List pcmBytes) {
    final epoch = _playbackEpoch;
    final op = _nativeChain.then((_) async {
      if (epoch != _playbackEpoch || _disposed || !_enabled) return;
      if (!_usingNativeStream) {
        await _enqueueFallbackChunk(pcmBytes);
        return;
      }
      try {
        if (!_nativeConfigured) {
          await _nativeChannel.invokeMethod('start', {
            'sampleRate': _sampleRate,
            'volume': _volume,
            'rate': _playbackRate,
          });
          _nativeConfigured = true;
          if (_isPaused) {
            await _nativeChannel.invokeMethod('setPaused', {'paused': true});
          }
        }
        if (epoch != _playbackEpoch || _disposed || !_enabled) return;
        await _nativeChannel.invokeMethod('enqueuePcm', {
          'pcm': pcmBytes,
          'sampleRate': _sampleRate,
        });
      } on MissingPluginException {
        _nativeFallbackActivated = true;
        _nativeConfigured = false;
        await _enqueueFallbackChunk(pcmBytes);
        await flushTurn();
      } catch (e) {
        debugPrint('[LivePcmAudioOutput] Lỗi stream PCM native: $e');
      }
    });
    _nativeChain = op.catchError((_) {});
    return op;
  }

  Future<void> _invokeNativeSafe(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    try {
      await _nativeChannel.invokeMethod(method, args);
    } on MissingPluginException {
      _nativeFallbackActivated = true;
      _nativeConfigured = false;
    } catch (e) {
      debugPrint('[LivePcmAudioOutput] Lỗi gọi native $method: $e');
    }
  }

  Future<void> _scheduleFallbackFlush() {
    if (_pendingPcm.length == 0 || !_enabled || _disposed) {
      return Future<void>.value();
    }
    final raw = _pendingPcm.takeBytes();
    if (raw.isEmpty) return Future<void>.value();
    final epoch = _playbackEpoch;

    // Tuần tự hóa ghi WAV để hàng đợi giữ đúng thứ tự thời gian tuyệt đối.
    final op = _flushChain.then((_) async {
      if (epoch != _playbackEpoch || _disposed || !_enabled) return;
      try {
        final dir = await _ensureTempDir();
        if (epoch != _playbackEpoch || _disposed || !_enabled) return;

        final wavBytes = buildWavFromPcmBytes(raw, sampleRate: _sampleRate);
        final filePath =
            '${dir.path}${Platform.pathSeparator}seg_${epoch}_${_segmentCounter++}.wav';
        await File(filePath).writeAsBytes(wavBytes, flush: false);

        if (epoch != _playbackEpoch || _disposed || !_enabled) {
          unawaited(_safeDeleteFile(filePath));
          return;
        }

        _segmentQueue.add(filePath);
        if (!_isDrainRunning) {
          unawaited(_drainQueue(epoch));
        }
      } catch (e) {
        debugPrint('[LivePcmAudioOutput] Lỗi ghi WAV segment: $e');
      }
    });
    _flushChain = op.catchError((_) {});
    return op;
  }

  Future<void> _drainQueue(int epoch) async {
    if (_isDrainRunning) return;
    _isDrainRunning = true;
    _setPlaying(true);

    try {
      final players = _ensureFallbackPlayers();
      while (_segmentQueue.isNotEmpty &&
          epoch == _playbackEpoch &&
          _enabled &&
          !_disposed) {
        while (_isPaused &&
            epoch == _playbackEpoch &&
            _enabled &&
            !_disposed) {
          final waiter = _pauseResumeCompleter ??= Completer<void>();
          await waiter.future;
        }
        if (_segmentQueue.isEmpty ||
            epoch != _playbackEpoch ||
            !_enabled ||
            _disposed) {
          break;
        }
        final path = _segmentQueue.removeFirst();
        final player = players[_activePlayerIdx % players.length];
        _activePlayerIdx++;
        _currentPlayingPlayer = player;

        try {
          // Dừng dứt điểm để just_audio reset cờ `playing = false`, tránh setFilePath tự phát đè/lặp.
          await player.stop();
          if (epoch != _playbackEpoch || !_enabled || _disposed) {
            unawaited(_safeDeleteFile(path));
            break;
          }
          await player.setFilePath(path);
          if (epoch != _playbackEpoch || !_enabled || _disposed) {
            unawaited(_safeDeleteFile(path));
            break;
          }
          await player.setVolume(_volume);
          await player.setSpeed(_playbackRate);

          final completed = player.processingStateStream.firstWhere(
            (state) => state == ProcessingState.completed,
          );
          if (!_isPaused) {
            unawaited(player.play().catchError((_) => null));
          }
          await completed.timeout(
            const Duration(seconds: 30),
            onTimeout: () => player.processingState,
          );
        } catch (e) {
          debugPrint('[LivePcmAudioOutput] Lỗi phát segment fallback: $e');
        } finally {
          try {
            await player.stop();
          } catch (_) {}
          if (identical(_currentPlayingPlayer, player)) {
            _currentPlayingPlayer = null;
          }
          unawaited(_safeDeleteFile(path));
        }
      }
    } finally {
      _isDrainRunning = false;
      if (_segmentQueue.isEmpty || epoch != _playbackEpoch || !_enabled) {
        _setPlaying(false);
      }
    }
  }

  void _setPlaying(bool playing) {
    if (_isPlaying == playing) return;
    _isPlaying = playing;
    onPlaybackStateChanged?.call();
  }

  /// Ngắt phát ngay lập tức khi người dùng nói chèn (barge-in), tua video hoặc tắt loa.
  Future<void> interrupt() async {
    _playbackEpoch++;
    _isPaused = false;
    if (_pauseResumeCompleter != null && !_pauseResumeCompleter!.isCompleted) {
      _pauseResumeCompleter!.complete();
    }
    _pauseResumeCompleter = null;
    _nativeStartFlushTimer?.cancel();
    _nativeStartFlushTimer = null;
    _pendingPcm.clear();
    _hasStartedTurnSegment = false;
    _hasStartedNativeTurn = false;
    final stalePaths = _segmentQueue.toList();
    _segmentQueue.clear();
    _setPlaying(false);

    if (_usingNativeStream) {
      await _invokeNativeSafe('interrupt');
    }

    final players = _fallbackPlayers;
    if (players != null) {
      for (final player in players) {
        try {
          await player.stop();
        } catch (_) {}
      }
    }
    for (final p in stalePaths) {
      unawaited(_safeDeleteFile(p));
    }
  }

  Future<void> _safeDeleteFile(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await interrupt();
    if (_preferNativeStream) {
      await _invokeNativeSafe('dispose');
      _nativeChannel.setMethodCallHandler(null);
    }
    final players = _fallbackPlayers;
    _fallbackPlayers = null;
    if (players != null) {
      for (final player in players) {
        try {
          await player.dispose();
        } catch (_) {}
      }
    }
    try {
      if (_tempDir != null && await _tempDir!.exists()) {
        await _tempDir!.delete(recursive: true);
      }
    } catch (_) {}
  }
}

