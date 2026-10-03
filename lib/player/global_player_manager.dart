import 'package:flutter/foundation.dart';

import '../data/model/subtitle_document.dart';
import '../domain/media/hongguo_resolver.dart';

enum PlayerDisplayMode {
  hidden,
  mini,
  full,
}

class PlaybackRequest {
  final String videoPath;
  final SubtitleDocument? document;
  final String? title;
  final int initialPositionMs;
  final Future<void> Function(int positionMs)? onPlaybackPositionChanged;
  final HongguoDramaDetail? dramaDetail;
  final int? currentEpisodeIndex;
  final bool? initialTtsEnabled;
  final int requestId;

  PlaybackRequest({
    required this.videoPath,
    this.document,
    this.title,
    this.initialPositionMs = 0,
    this.onPlaybackPositionChanged,
    this.dramaDetail,
    this.currentEpisodeIndex,
    this.initialTtsEnabled,
    required this.requestId,
  });
}

class GlobalPlayerManager extends ChangeNotifier {
  static final GlobalPlayerManager instance = GlobalPlayerManager._();
  GlobalPlayerManager._();

  PlaybackRequest? _currentRequest;
  PlaybackRequest? get currentRequest => _currentRequest;

  PlayerDisplayMode _mode = PlayerDisplayMode.hidden;
  PlayerDisplayMode get mode => _mode;

  bool get isPlayingAny => _mode != PlayerDisplayMode.hidden && _currentRequest != null;
  bool get isFullScreen => _mode == PlayerDisplayMode.full;
  bool get isMiniPlayer => _mode == PlayerDisplayMode.mini;

  void openPlayer({
    required String videoPath,
    SubtitleDocument? document,
    String? title,
    int initialPositionMs = 0,
    Future<void> Function(int positionMs)? onPlaybackPositionChanged,
    HongguoDramaDetail? dramaDetail,
    int? currentEpisodeIndex,
    bool? initialTtsEnabled,
  }) {
    _currentRequest = PlaybackRequest(
      videoPath: videoPath,
      document: document,
      title: title,
      initialPositionMs: initialPositionMs,
      onPlaybackPositionChanged: onPlaybackPositionChanged,
      dramaDetail: dramaDetail,
      currentEpisodeIndex: currentEpisodeIndex,
      initialTtsEnabled: initialTtsEnabled,
      requestId: DateTime.now().microsecondsSinceEpoch,
    );
    _mode = PlayerDisplayMode.full;
    notifyListeners();
  }

  void minimize() {
    if (_mode == PlayerDisplayMode.full) {
      _mode = PlayerDisplayMode.mini;
      notifyListeners();
    }
  }

  void expand() {
    if (_mode == PlayerDisplayMode.mini) {
      _mode = PlayerDisplayMode.full;
      notifyListeners();
    }
  }

  void close() {
    _mode = PlayerDisplayMode.hidden;
    _currentRequest = null;
    notifyListeners();
  }

  void updateRequest(PlaybackRequest newRequest) {
    _currentRequest = newRequest;
    notifyListeners();
  }
}
