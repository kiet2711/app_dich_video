import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../data/model/subtitle_document.dart';
import '../data/model/subtitle_item.dart';

class TtsAudioScheduler {
  final AudioPlayer _player = AudioPlayer();
  SubtitleDocument? _document;

  int _lastPlayedItemId = -1;
  double _volume = 1.0;
  bool _isMuted = false;
  bool _isEnabled = true;

  TtsAudioScheduler() {
    _player.setVolume(_volume);
  }

  void setDocument(SubtitleDocument? doc) {
    _document = doc;
    _lastPlayedItemId = -1;
  }

  void setEnabled(bool enabled) {
    _isEnabled = enabled;
    if (!enabled) {
      _player.stop();
    }
  }

  void setVolume(double vol) {
    _volume = vol.clamp(0.0, 1.0);
    _player.setVolume(_isMuted ? 0.0 : _volume);
  }

  void setMuted(bool muted) {
    _isMuted = muted;
    _player.setVolume(_isMuted ? 0.0 : _volume);
  }

  void onPositionUpdate(int positionMs) {
    if (!_isEnabled || _document == null) return;

    final item = _document!.getActiveItem(positionMs);
    if (item == null) {
      return;
    }

    if (item.id != _lastPlayedItemId) {
      _lastPlayedItemId = item.id;
      _playItemAudio(item);
    }
  }

  Future<void> _playItemAudio(SubtitleItem item) async {
    final audioPath = item.audioFilePath;
    if (audioPath == null || audioPath.isEmpty) return;

    final file = File(audioPath);
    if (!await file.exists()) return;

    try {
      await _player.stop();
      await _player.setFilePath(audioPath);
      await _player.setSpeed(item.playbackSpeed);
      await _player.setPitch(1.0);
      await _player.setVolume(_isMuted ? 0.0 : _volume);
      await _player.play();
    } catch (e) {
      debugPrint('TtsAudioScheduler play error: $e');
    }
  }

  void onSeek() {
    _lastPlayedItemId = -1;
    _player.stop();
  }

  void pause() {
    _player.pause();
  }

  void resume() {
    if (_isEnabled && !_isMuted && _volume > 0) {
      _player.play();
    }
  }

  void dispose() {
    _player.dispose();
  }
}
