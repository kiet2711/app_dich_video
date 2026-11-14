import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
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

/// Bộ phát âm thanh phản hồi 24kHz PCM từ Gemini Live qua 2 AudioPlayer luân phiên (hỗ trợ Android, iOS, Windows).
class LivePcmAudioOutput {
  static const int _sampleRate = 24000;

  final int firstSegmentBytes;
  final int normalSegmentBytes;
  final List<AudioPlayer> _players = [AudioPlayer(), AudioPlayer()];
  final BytesBuilder _pendingPcm = BytesBuilder(copy: false);
  final Queue<String> _segmentQueue = Queue<String>();

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
    this.firstSegmentBytes = 19200, // ~0.4s ở 24kHz 16-bit mono
    this.normalSegmentBytes = 57600, // ~1.2s để hạn chế ngắt nhịp
  });

  bool get isEnabled => _enabled;
  bool get isPlaying => _isPlaying;
  bool get isPaused => _isPaused;
  double get volume => _volume;
  double get playbackRate => _playbackRate;

  void setEnabled(bool enabled) {
    _enabled = enabled;
    if (!enabled) {
      unawaited(interrupt());
    }
  }

  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    if (_disposed) return;
    for (final player in _players) {
      try {
        await player.setVolume(_volume);
      } catch (_) {}
    }
  }

  Future<void> setPlaybackRate(double rate) async {
    _playbackRate = rate.clamp(0.75, 2.0);
    if (_disposed) return;
    for (final player in _players) {
      try {
        await player.setSpeed(_playbackRate);
      } catch (_) {}
    }
  }

  Future<void> setPaused(bool paused) async {
    if (_disposed || _isPaused == paused) return;
    _isPaused = paused;
    if (paused) {
      _pauseResumeCompleter ??= Completer<void>();
      for (final player in _players) {
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
    _pendingPcm.add(pcmBytes);

    final threshold = _hasStartedTurnSegment
        ? normalSegmentBytes
        : firstSegmentBytes;
    if (_pendingPcm.length >= threshold) {
      _hasStartedTurnSegment = true;
      await _flushBufferToQueue();
    }
  }

  /// Đẩy nốt phần âm thanh còn lại khi Gemini hoàn thành lượt nói (`turnComplete`).
  Future<void> flushTurn() async {
    if (_disposed || !_enabled) {
      _pendingPcm.clear();
      _hasStartedTurnSegment = false;
      return;
    }
    _hasStartedTurnSegment = false;
    if (_pendingPcm.length > 0) {
      await _flushBufferToQueue();
    }
  }

  Future<void> _flushBufferToQueue() async {
    if (_pendingPcm.length == 0 || !_enabled || _disposed) return;
    final raw = _pendingPcm.takeBytes();
    if (raw.isEmpty) return;

    final epoch = _playbackEpoch;
    try {
      final dir = await _ensureTempDir();
      if (epoch != _playbackEpoch || _disposed || !_enabled) return;

      final wavBytes = buildWavFromPcmBytes(raw, sampleRate: _sampleRate);
      final filePath =
          '${dir.path}${Platform.pathSeparator}seg_${_playbackEpoch}_${_segmentCounter++}.wav';
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
  }

  Future<void> _drainQueue(int epoch) async {
    if (_isDrainRunning) return;
    _isDrainRunning = true;
    _setPlaying(true);

    try {
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
        final player = _players[_activePlayerIdx % _players.length];
        _activePlayerIdx++;
        _currentPlayingPlayer = player;

        try {
          await player.setFilePath(path);
          if (epoch != _playbackEpoch || !_enabled || _disposed) {
            unawaited(_safeDeleteFile(path));
            break;
          }
          await player.setVolume(_volume);
          await player.setSpeed(_playbackRate);

          // Preload đoạn kế tiếp vào player còn lại để giảm khoảng trễ chuyển đoạn
          if (_segmentQueue.isNotEmpty) {
            final nextPath = _segmentQueue.first;
            final nextPlayer = _players[_activePlayerIdx % _players.length];
            unawaited(nextPlayer.setFilePath(nextPath).catchError((_) => null));
          }

          final completed = player.playerStateStream.firstWhere(
            (s) =>
                s.processingState == ProcessingState.completed ||
                s.processingState == ProcessingState.idle,
          );
          if (!_isPaused) {
            unawaited(player.play().catchError((_) => null));
          }
          await completed.timeout(
            const Duration(seconds: 30),
            onTimeout: () => player.playerState,
          );
        } catch (e) {
          debugPrint('[LivePcmAudioOutput] Lỗi phát segment: $e');
        } finally {
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

  /// Ngắt phát ngay lập tức khi người dùng nói chèn (barge-in) hoặc tắt loa.
  Future<void> interrupt() async {
    _playbackEpoch++;
    _isPaused = false;
    if (_pauseResumeCompleter != null && !_pauseResumeCompleter!.isCompleted) {
      _pauseResumeCompleter!.complete();
    }
    _pauseResumeCompleter = null;
    _pendingPcm.clear();
    _hasStartedTurnSegment = false;
    final stalePaths = _segmentQueue.toList();
    _segmentQueue.clear();
    _setPlaying(false);

    for (final player in _players) {
      try {
        await player.stop();
      } catch (_) {}
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
    for (final player in _players) {
      try {
        await player.dispose();
      } catch (_) {}
    }
    try {
      if (_tempDir != null && await _tempDir!.exists()) {
        await _tempDir!.delete(recursive: true);
      }
    } catch (_) {}
  }
}

