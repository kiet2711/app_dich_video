import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
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

/// Đồng bộ track TTS độc lập với video bằng hai AudioPlayer luân phiên.
///
/// Player dự phòng luôn nạp trước câu kế tiếp. Khi timeline chạm startMs, việc
/// phát chỉ còn là gọi play(), tránh độ trễ mở file của AVPlayer trên iOS.
class TtsAudioScheduler {
  static const int lateStartToleranceMs = 100;
  static const int resyncThresholdMs = 180;

  final List<AudioPlayer> _players = [AudioPlayer(), AudioPlayer()];
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

  TtsAudioScheduler([this._document]);

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
      if (!player.playing &&
          player.processingState != ProcessingState.completed) {
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
    if (player.processingState != ProcessingState.completed) {
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
    AudioPlayer player,
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
    final driftMs = (player.position.inMilliseconds - expectedMs).abs();
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
}
