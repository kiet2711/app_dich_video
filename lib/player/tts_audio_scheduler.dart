import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import '../data/model/subtitle_document.dart';
import '../data/model/subtitle_item.dart';

class _PreparedAudio {
  final int itemId;
  final String path;
  final int durationMs;
  final double speed;

  const _PreparedAudio({
    required this.itemId,
    required this.path,
    required this.durationMs,
    required this.speed,
  });
}

class _VideoState {
  final int positionMs;
  final bool isPlaying;
  final bool isBuffering;
  final bool isScrubbing;
  final double playbackSpeed;

  const _VideoState({
    required this.positionMs,
    required this.isPlaying,
    required this.isBuffering,
    required this.isScrubbing,
    required this.playbackSpeed,
  });
}

abstract class _TtsPlayerBackend {
  bool get playing;
  bool get isCompleted;
  double get speed;
  Duration get position;

  Future<Duration?> setFilePath(String path);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setSpeed(double speed);
  Future<void> setVolume(double volume);
  Future<void> setVoiceTone({
    required double pitch,
    required double warmth,
    required double brightness,
  });
  Future<int> getExactPositionMs();
  Future<void> dispose();
}

class _JustAudioTtsPlayer implements _TtsPlayerBackend {
  final AndroidEqualizer? _equalizer;
  late final AudioPlayer _player;

  _JustAudioTtsPlayer({required bool enableAndroidEq})
    : _equalizer = enableAndroidEq ? AndroidEqualizer() : null {
    _player = _equalizer == null
        ? AudioPlayer()
        : AudioPlayer(
            audioPipeline: AudioPipeline(androidAudioEffects: [_equalizer]),
          );
  }

  @override
  bool get playing => _player.playing;

  @override
  bool get isCompleted => _player.processingState == ProcessingState.completed;

  @override
  double get speed => _player.speed;

  @override
  Duration get position => _player.position;

  @override
  Future<Duration?> setFilePath(String path) => _player.setFilePath(path);

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> setVoiceTone({
    required double pitch,
    required double warmth,
    required double brightness,
  }) async {
    try {
      await _player.setPitch(pitch);
    } catch (_) {}

    final eq = _equalizer;
    if (eq == null) return;
    try {
      final eqActive = warmth.abs() >= 0.01 || brightness.abs() >= 0.01;
      await eq.setEnabled(eqActive);
      if (!eqActive) return;
      final params = await eq.parameters.timeout(
        const Duration(milliseconds: 250),
      );
      for (final band in params.bands) {
        final gainDb = TtsAudioScheduler.computeEqualizerBandGainDb(
          centerFrequencyHz: band.centerFrequency,
          warmth: warmth,
          brightness: brightness,
          minDb: params.minDecibels,
          maxDb: params.maxDecibels,
        );
        await band.setGain(gainDb);
      }
    } catch (_) {}
  }

  @override
  Future<int> getExactPositionMs() async => _player.position.inMilliseconds;

  @override
  Future<void> dispose() => _player.dispose();
}

class _IosChannelTtsPlayer implements _TtsPlayerBackend {
  static const MethodChannel _channel = MethodChannel(
    'com.capcut.capsub/ios_tts_player',
  );
  static const List<double> _eqBandsHz = [60.0, 230.0, 910.0, 3600.0, 14000.0];
  static int _nextPlayerId = 1;
  static final Map<int, _IosChannelTtsPlayer> _instances = {};
  static bool _handlerRegistered = false;

  static void _ensureHandlerRegistered() {
    if (_handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onCompleted') {
        final args = call.arguments;
        if (args is Map) {
          final id = (args['playerId'] as num?)?.toInt();
          if (id != null) {
            _instances[id]?._handleNativeCompleted();
          }
        }
      }
    });
  }

  final int _playerId;
  final Stopwatch _playWatch = Stopwatch();
  int _basePositionMs = 0;
  int _durationMs = 0;
  double _speed = 1.0;
  bool _playing = false;
  bool _completed = false;
  bool _disposed = false;

  _IosChannelTtsPlayer() : _playerId = _nextPlayerId++ {
    _ensureHandlerRegistered();
    _instances[_playerId] = this;
  }

  void _handleNativeCompleted() {
    if (_disposed) return;
    _playing = false;
    _completed = true;
    _playWatch.stop();
    _playWatch.reset();
    _basePositionMs = _durationMs;
  }

  int _estimatedPositionMs() {
    final elapsedMs = (_playWatch.elapsedMilliseconds * _speed).round();
    final pos = _basePositionMs + elapsedMs;
    if (_durationMs > 0) return pos.clamp(0, _durationMs);
    return max(0, pos);
  }

  @override
  bool get playing => _playing;

  @override
  bool get isCompleted => _completed;

  @override
  double get speed => _speed;

  @override
  Duration get position => Duration(milliseconds: _estimatedPositionMs());

  @override
  Future<Duration?> setFilePath(String path) async {
    if (_disposed) return null;
    _playing = false;
    _completed = false;
    _playWatch.stop();
    _playWatch.reset();
    _basePositionMs = 0;
    final durMs = await _channel.invokeMethod<int>('setFilePath', {
      'playerId': _playerId,
      'path': path,
    });
    _durationMs = durMs ?? 0;
    return durMs != null ? Duration(milliseconds: durMs) : null;
  }

  @override
  Future<void> play() async {
    if (_disposed) return;
    if (_completed) {
      _basePositionMs = 0;
      _completed = false;
    }
    _playing = true;
    _playWatch.start();
    await _channel.invokeMethod('play', {'playerId': _playerId});
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    _basePositionMs = _estimatedPositionMs();
    _playWatch.stop();
    _playWatch.reset();
    _playing = false;
    await _channel.invokeMethod('pause', {'playerId': _playerId});
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    _playing = false;
    _completed = false;
    _playWatch.stop();
    _playWatch.reset();
    _basePositionMs = 0;
    await _channel.invokeMethod('stop', {'playerId': _playerId});
  }

  @override
  Future<void> seek(Duration position) async {
    if (_disposed) return;
    final targetMs = max(0, position.inMilliseconds);
    _basePositionMs = _durationMs > 0 ? targetMs.clamp(0, _durationMs) : targetMs;
    _completed = false;
    _playWatch.reset();
    if (_playing) _playWatch.start();
    await _channel.invokeMethod('seek', {
      'playerId': _playerId,
      'positionMs': _basePositionMs,
    });
  }

  @override
  Future<void> setSpeed(double speed) async {
    if (_disposed) return;
    if (_playing) {
      _basePositionMs = _estimatedPositionMs();
      _playWatch.reset();
      _playWatch.start();
    }
    _speed = speed;
    await _channel.invokeMethod('setSpeed', {
      'playerId': _playerId,
      'speed': speed,
    });
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_disposed) return;
    await _channel.invokeMethod('setVolume', {
      'playerId': _playerId,
      'volume': volume,
    });
  }

  @override
  Future<void> setVoiceTone({
    required double pitch,
    required double warmth,
    required double brightness,
  }) async {
    if (_disposed) return;
    final eqActive = warmth.abs() >= 0.01 || brightness.abs() >= 0.01;
    final gains = _eqBandsHz
        .map(
          (freq) => TtsAudioScheduler.computeEqualizerBandGainDb(
            centerFrequencyHz: freq,
            warmth: warmth,
            brightness: brightness,
            minDb: -15.0,
            maxDb: 15.0,
          ),
        )
        .toList(growable: false);
    await _channel.invokeMethod('setVoiceTone', {
      'playerId': _playerId,
      'pitch': pitch,
      'eqEnabled': eqActive,
      'bandGainsDb': gains,
    });
  }

  @override
  Future<int> getExactPositionMs() async {
    if (_disposed) return 0;
    final ms = await _channel.invokeMethod<int>('getPositionMs', {
      'playerId': _playerId,
    });
    if (ms != null) {
      _basePositionMs = ms;
      _playWatch.reset();
      if (_playing) _playWatch.start();
      return ms;
    }
    return _estimatedPositionMs();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _playing = false;
    _playWatch.stop();
    _instances.remove(_playerId);
    try {
      await _channel.invokeMethod('dispose', {'playerId': _playerId});
    } catch (_) {}
  }
}

/// Đồng bộ track TTS độc lập với video bằng hai AudioPlayer luân phiên.
///
/// Player dự phòng luôn nạp trước câu kế tiếp. Khi timeline chạm startMs, việc
/// phát chỉ còn là gọi play(), tránh độ trễ mở file của AVPlayer trên iOS.
class TtsAudioScheduler {
  static const int lateStartToleranceMs = 100;
  static const int resyncThresholdMs = 180;

  late final List<_TtsPlayerBackend> _players;
  final List<_PreparedAudio?> _prepared = [null, null];
  final List<int?> _preparingItemIds = [null, null];
  final List<int> _loadEpochs = [0, 0];

  SubtitleDocument? _document;
  int _currentPlayerIndex = -1;
  int _activeItemId = -1;
  int _lastPlayedItemId = -1;
  bool _explicitSeekPending = false;
  bool _needsResyncAfterInterruption = false;
  bool _isHandlingUpdate = false;
  _VideoState? _pendingVideoState;
  int _timelineEpoch = 0;
  bool _enabled = true;
  bool _disposed = false;
  double _volume = 1;
  double _pitch = 1.0;
  double _warmth = 0.0;
  double _brightness = 0.0;

  TtsAudioScheduler([this._document]) {
    _initPlayers();
  }

  TtsAudioScheduler.withTone(
    this._document, {
    double pitch = 1.0,
    double warmth = 0.0,
    double brightness = 0.0,
  }) : _pitch = pitch.clamp(0.75, 1.25),
       _warmth = warmth.clamp(-1.0, 1.0),
       _brightness = brightness.clamp(-1.0, 1.0) {
    _initPlayers();
  }

  void _initPlayers() {
    final useIosNative = !kIsWeb && Platform.isIOS;
    final useAndroidEq = !kIsWeb && Platform.isAndroid;
    _players = List<_TtsPlayerBackend>.generate(
      2,
      (_) => useIosNative
          ? _IosChannelTtsPlayer()
          : _JustAudioTtsPlayer(enableAndroidEq: useAndroidEq),
      growable: false,
    );
  }

  void setDocument(SubtitleDocument? document) {
    _document = document;
    _activeItemId = -1;
    _lastPlayedItemId = -1;
    _explicitSeekPending = false;
    _invalidateLoads();
    unawaited(stop());
  }

  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    if (!enabled) {
      _timelineEpoch++;
      _pendingVideoState = null;
      await stop();
    }
  }

  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0, 1);
    await Future.wait(_players.map((player) => player.setVolume(_volume)));
  }

  Future<void> setVoiceTone({
    double? pitch,
    double? warmth,
    double? brightness,
  }) async {
    if (pitch != null) _pitch = pitch.clamp(0.75, 1.25);
    if (warmth != null) _warmth = warmth.clamp(-1.0, 1.0);
    if (brightness != null) _brightness = brightness.clamp(-1.0, 1.0);
    if (_disposed) return;
    await Future.wait([_applyToneToPlayer(0), _applyToneToPlayer(1)]);
  }

  Future<void> _applyToneToPlayer(int index) async {
    if (_disposed || index < 0 || index >= _players.length) return;
    await _players[index].setVoiceTone(
      pitch: _pitch,
      warmth: _warmth,
      brightness: _brightness,
    );
  }

  /// Nạp trước câu đang chứa [positionMs], hoặc câu gần nhất sau vị trí này.
  /// Gọi trước khi video play để câu đầu không bị trễ do AVPlayer mở file.
  Future<void> warmUp(int positionMs) async {
    if (!_enabled || _disposed) return;
    final item = _itemAtOrAfter(positionMs);
    if (item != null) await _prepareItem(item, 0);
  }

  Future<void> onVideoStateUpdate({
    required int positionMs,
    required bool isPlaying,
    required bool isBuffering,
    required bool isScrubbing,
    required double playbackSpeed,
  }) async {
    _pendingVideoState = _VideoState(
      positionMs: positionMs,
      isPlaying: isPlaying,
      isBuffering: isBuffering,
      isScrubbing: isScrubbing,
      playbackSpeed: playbackSpeed,
    );
    if (_isHandlingUpdate) return;
    _isHandlingUpdate = true;
    try {
      while (_pendingVideoState != null) {
        final state = _pendingVideoState!;
        _pendingVideoState = null;
        await _handleVideoState(state);
      }
    } finally {
      _isHandlingUpdate = false;
    }
  }

  Future<void> _handleVideoState(_VideoState state) async {
    if (_disposed || !_enabled) return;
    final updateEpoch = _timelineEpoch;

    if (!state.isPlaying || state.isBuffering || state.isScrubbing) {
      if (state.isBuffering || state.isScrubbing) {
        _needsResyncAfterInterruption = true;
      }
      await pause();
      return;
    }

    final document = _document;
    if (document == null) return;
    final item = document.getActiveItem(state.positionMs);
    if (item == null || !_hasUsableAudio(item)) {
      if (_activeItemId != -1) await _stopCurrentAudio();
      _preloadNext(state.positionMs);
      return;
    }

    if (_activeItemId == item.id && _currentPlayerIndex >= 0) {
      final player = _players[_currentPlayerIndex];
      final prepared = _prepared[_currentPlayerIndex];
      if (prepared != null) {
        final effectiveSpeed = calculateAudioPlaybackSpeed(
          ttsSpeed: prepared.speed,
          videoSpeed: state.playbackSpeed,
        );
        if ((player.speed - effectiveSpeed).abs() > 0.001) {
          await player.setSpeed(effectiveSpeed);
        }
      }
      if (_needsResyncAfterInterruption) {
        _needsResyncAfterInterruption = false;
        await _resyncOnce(player, item, state.positionMs);
      }
      if (updateEpoch != _timelineEpoch) return;
      if (!player.playing && !player.isCompleted) {
        unawaited(player.play());
      }
      _preloadAfter(item);
      return;
    }

    if (_lastPlayedItemId == item.id && !_explicitSeekPending) return;

    var preparedIndex = _prepared.indexWhere(
      (prepared) =>
          prepared?.itemId == item.id && prepared?.path == item.audioFilePath,
    );
    if (preparedIndex == -1) {
      final standbyIndex = _currentPlayerIndex == 0 ? 1 : 0;
      unawaited(_prepareItem(item, standbyIndex));
      return;
    }

    final prepared = _prepared[preparedIndex]!;
    final timelineOffsetMs = max(0, state.positionMs - item.startMs);
    final sourceOffsetMs = calculateSourceOffsetMs(
      timelineOffsetMs: timelineOffsetMs,
      speed: prepared.speed,
      explicitSeek: _explicitSeekPending,
    );
    _explicitSeekPending = false;

    if (sourceOffsetMs >= prepared.durationMs) {
      _lastPlayedItemId = item.id;
      return;
    }

    final oldPlayerIndex = _currentPlayerIndex;
    if (oldPlayerIndex >= 0 && oldPlayerIndex != preparedIndex) {
      await _players[oldPlayerIndex].stop();
    }
    if (updateEpoch != _timelineEpoch) return;
    _currentPlayerIndex = preparedIndex;
    _activeItemId = item.id;
    _lastPlayedItemId = item.id;

    final player = _players[preparedIndex];
    if (sourceOffsetMs > 0) {
      await player.seek(Duration(milliseconds: sourceOffsetMs));
    } else if (player.position != Duration.zero) {
      await player.seek(Duration.zero);
    }
    await player.setSpeed(
      calculateAudioPlaybackSpeed(
        ttsSpeed: prepared.speed,
        videoSpeed: state.playbackSpeed,
      ),
    );
    await player.setVolume(_volume);
    unawaited(_applyToneToPlayer(preparedIndex));
    unawaited(player.play());
    _preloadAfter(item);
  }

  Future<void> onSeek(int targetPositionMs) async {
    _timelineEpoch++;
    _pendingVideoState = null;
    _explicitSeekPending = true;
    _needsResyncAfterInterruption = false;
    _activeItemId = -1;
    _lastPlayedItemId = -1;
    await Future.wait(_players.map((player) => player.stop()));
    _currentPlayerIndex = -1;

    final item = _document?.getActiveItem(targetPositionMs);
    if (item != null && _hasUsableAudio(item)) {
      final loadedIndex = _prepared.indexWhere(
        (prepared) => prepared?.itemId == item.id,
      );
      if (loadedIndex == -1) {
        await _prepareItem(item, 0);
      }
    } else {
      _preloadNext(targetPositionMs);
    }
  }

  Future<void> pause() async {
    if (_currentPlayerIndex >= 0 && _players[_currentPlayerIndex].playing) {
      await _players[_currentPlayerIndex].pause();
    }
  }

  Future<void> resume() async {
    if (!_enabled || _currentPlayerIndex < 0) return;
    final player = _players[_currentPlayerIndex];
    if (!player.isCompleted) {
      unawaited(player.play());
    }
  }

  Future<void> stop() async {
    await Future.wait(_players.map((player) => player.stop()));
    _currentPlayerIndex = -1;
    _activeItemId = -1;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _invalidateLoads();
    await Future.wait(_players.map((player) => player.dispose()));
  }

  Future<bool> _prepareItem(SubtitleItem item, int playerIndex) async {
    if (_disposed || !_enabled || !_hasUsableAudio(item)) return false;
    final path = item.audioFilePath!;
    final existing = _prepared[playerIndex];
    if (existing?.itemId == item.id && existing?.path == path) return true;
    if (_preparingItemIds[playerIndex] != null) return false;
    if (playerIndex == _currentPlayerIndex && _activeItemId != -1) return false;

    final file = File(path);
    if (!await file.exists()) {
      item.audioFilePath = null;
      return false;
    }

    final epoch = ++_loadEpochs[playerIndex];
    _preparingItemIds[playerIndex] = item.id;
    try {
      final player = _players[playerIndex];
      await player.stop();
      final duration = await player.setFilePath(path);
      if (_disposed || epoch != _loadEpochs[playerIndex]) return false;
      final durationMs = duration?.inMilliseconds ?? item.audioDurationMs;
      if (durationMs <= 0) return false;
      item.audioDurationMs = durationMs;
      final speed = calculatePlaybackSpeed(
        audioDurationMs: durationMs,
        subtitleDurationMs: item.endMs - item.startMs,
      );
      item.playbackSpeed = speed;
      await player.setSpeed(speed);
      await player.setVolume(_volume);
      await _applyToneToPlayer(playerIndex);
      _prepared[playerIndex] = _PreparedAudio(
        itemId: item.id,
        path: path,
        durationMs: durationMs,
        speed: speed,
      );
      return true;
    } catch (error) {
      debugPrint('TtsAudioScheduler prepare #${item.id} error: $error');
      _prepared[playerIndex] = null;
      return false;
    } finally {
      if (epoch == _loadEpochs[playerIndex]) {
        _preparingItemIds[playerIndex] = null;
      }
    }
  }

  Future<void> _resyncOnce(
    _TtsPlayerBackend player,
    SubtitleItem item,
    int videoPositionMs,
  ) async {
    final prepared = _prepared[_currentPlayerIndex];
    if (prepared == null) return;
    final expectedMs = calculateSourceOffsetMs(
      timelineOffsetMs: max(0, videoPositionMs - item.startMs),
      speed: prepared.speed,
      explicitSeek: true,
    ).clamp(0, prepared.durationMs);
    final actualMs = await player.getExactPositionMs();
    final driftMs = (actualMs - expectedMs).abs();
    if (driftMs > resyncThresholdMs && expectedMs < prepared.durationMs) {
      await player.seek(Duration(milliseconds: expectedMs));
    }
  }

  Future<void> _stopCurrentAudio() async {
    if (_currentPlayerIndex >= 0) {
      await _players[_currentPlayerIndex].stop();
    }
    _currentPlayerIndex = -1;
    _activeItemId = -1;
  }

  void _preloadAfter(SubtitleItem current) {
    final items = _document?.items;
    if (items == null) return;
    final index = items.indexWhere((item) => item.id == current.id);
    if (index == -1) return;
    for (var nextIndex = index + 1; nextIndex < items.length; nextIndex++) {
      final candidate = items[nextIndex];
      if (_hasUsableAudio(candidate)) {
        if (_prepared.any((prepared) => prepared?.itemId == candidate.id)) {
          return;
        }
        final standbyIndex = _currentPlayerIndex == 0 ? 1 : 0;
        unawaited(_prepareItem(candidate, standbyIndex));
        return;
      }
    }
  }

  void _preloadNext(int positionMs) {
    final item = _itemAtOrAfter(positionMs);
    if (item == null) return;
    if (_prepared.any((prepared) => prepared?.itemId == item.id)) return;
    final standbyIndex = _currentPlayerIndex == 0 ? 1 : 0;
    unawaited(_prepareItem(item, standbyIndex));
  }

  SubtitleItem? _itemAtOrAfter(int positionMs) {
    final items = _document?.items;
    if (items == null) return null;
    for (final item in items) {
      if (item.endMs > positionMs && _hasUsableAudio(item)) return item;
    }
    return null;
  }

  bool _hasUsableAudio(SubtitleItem item) =>
      item.audioFilePath != null && item.audioFilePath!.trim().isNotEmpty;

  void _invalidateLoads() {
    for (var index = 0; index < _loadEpochs.length; index++) {
      _loadEpochs[index]++;
      _preparingItemIds[index] = null;
      _prepared[index] = null;
    }
  }

  static double calculatePlaybackSpeed({
    required int audioDurationMs,
    required int subtitleDurationMs,
  }) {
    final safeSubtitleDuration = max(200, subtitleDurationMs);
    if (audioDurationMs <= safeSubtitleDuration || audioDurationMs <= 0) {
      return 1;
    }
    final factor = (audioDurationMs / safeSubtitleDuration).clamp(1.0, 2.2);
    return (factor * 10).round() / 10;
  }

  @visibleForTesting
  static double calculateAudioPlaybackSpeed({
    required double ttsSpeed,
    required double videoSpeed,
  }) {
    return ttsSpeed.clamp(0.5, 2.2) * videoSpeed.clamp(0.5, 2.0);
  }

  @visibleForTesting
  static int calculateSourceOffsetMs({
    required int timelineOffsetMs,
    required double speed,
    required bool explicitSeek,
  }) {
    final safeTimelineOffset = max(0, timelineOffsetMs);
    if (!explicitSeek && safeTimelineOffset <= lateStartToleranceMs) return 0;
    return (safeTimelineOffset * speed.clamp(0.5, 2.2)).round();
  }

  /// Quy đổi hai thông số Độ ấm (warmth) và Độ sáng (brightness) sang mức dB cho từng band EQ.
  @visibleForTesting
  static double computeEqualizerBandGainDb({
    required double centerFrequencyHz,
    required double warmth,
    required double brightness,
    required double minDb,
    required double maxDb,
  }) {
    final w = warmth.clamp(-1.0, 1.0);
    final b = brightness.clamp(-1.0, 1.0);
    double gain = 0.0;

    if (centerFrequencyHz <= 140) {
      // Dải trầm nền: tăng nhẹ khi tăng độ ấm
      gain = w * 4.0;
    } else if (centerFrequencyHz <= 450) {
      // Dải trung trầm (độ dày và độ ấm của giọng nói)
      gain = w * 6.0;
    } else if (centerFrequencyHz < 2200) {
      // Dải trung (900Hz - 2kHz): giảm nhẹ khi cần bớt chói/the thé hoặc làm ấm giọng
      final deHarsh = (b < 0 ? b * 2.5 : b * 1.5) - (w > 0 ? w * 1.8 : 0.0);
      gain = deHarsh;
    } else if (centerFrequencyHz < 6500) {
      // Dải 2.2kHz - 6.5kHz: vùng gây cảm giác "the thé", giảm mạnh khi kéo brightness < 0
      gain = b < 0 ? b * 8.5 : b * 5.0;
    } else {
      // Dải treble cao (>= 6.5kHz): độ sáng và độ xì âm
      gain = b < 0 ? b * 9.0 : b * 6.0;
    }

    return gain.clamp(minDb, maxDb).toDouble();
  }
}
