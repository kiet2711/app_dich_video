import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Trạng thái đồng bộ của trình phát media_kit tương thích với giao diện CapSub
class AppVideoPlayerValue {
  final bool isInitialized;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final Size size;
  final double aspectRatio;
  final double playbackSpeed;
  final bool hasError;
  final String? errorDescription;

  const AppVideoPlayerValue({
    this.isInitialized = false,
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.size = const Size(1920, 1080),
    this.aspectRatio = 16 / 9,
    this.playbackSpeed = 1.0,
    this.hasError = false,
    this.errorDescription,
  });

  AppVideoPlayerValue copyWith({
    bool? isInitialized,
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    Size? size,
    double? aspectRatio,
    double? playbackSpeed,
    bool? hasError,
    String? errorDescription,
  }) {
    return AppVideoPlayerValue(
      isInitialized: isInitialized ?? this.isInitialized,
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      size: size ?? this.size,
      aspectRatio: aspectRatio ?? this.aspectRatio,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      hasError: hasError ?? this.hasError,
      errorDescription: errorDescription ?? this.errorDescription,
    );
  }
}

/// Controller điều khiển media_kit cung cấp interface tương thích cho video_player_screen
class AppPlayerController extends ChangeNotifier {
  late final Player player;
  late final VideoController videoController;
  AppVideoPlayerValue _value = const AppVideoPlayerValue();

  AppVideoPlayerValue get value => _value;

  final List<StreamSubscription> _subscriptions = [];
  bool _isDisposed = false;
  final Completer<void> _initCompleter = Completer<void>();

  AppPlayerController() {
    player = Player(
      configuration: const PlayerConfiguration(
        title: 'CapSub MediaKit Player',
        bufferSize: 32 * 1024 * 1024, // 32MB cache đệm
      ),
    );
    videoController = VideoController(player);

    _listenToPlayerStreams();
  }

  void _listenToPlayerStreams() {
    _subscriptions.add(
      player.stream.playing.listen((playing) {
        if (_isDisposed) return;
        _value = _value.copyWith(isPlaying: playing);
        notifyListeners();
      }),
    );

    _subscriptions.add(
      player.stream.position.listen((pos) {
        if (_isDisposed) return;
        _value = _value.copyWith(position: pos);
        notifyListeners();
      }),
    );

    _subscriptions.add(
      player.stream.duration.listen((dur) {
        if (_isDisposed) return;
        if (dur > Duration.zero) {
          _value = _value.copyWith(
            duration: dur,
            isInitialized: true,
          );
          if (!_initCompleter.isCompleted) {
            _initCompleter.complete();
          }
          notifyListeners();
        }
      }),
    );

    _subscriptions.add(
      player.stream.width.listen((w) {
        if (_isDisposed || w == null || w <= 0) return;
        final h = player.state.height ?? 0;
        final size = Size(w.toDouble(), h > 0 ? h.toDouble() : 1080);
        final ratio = h > 0 ? (w / h) : (16 / 9);
        _value = _value.copyWith(
          size: size,
          aspectRatio: ratio > 0 ? ratio : (16 / 9),
        );
        notifyListeners();
      }),
    );

    _subscriptions.add(
      player.stream.height.listen((h) {
        if (_isDisposed || h == null || h <= 0) return;
        final w = player.state.width ?? 0;
        final size = Size(w > 0 ? w.toDouble() : 1920, h.toDouble());
        final ratio = w > 0 ? (w / h) : (16 / 9);
        _value = _value.copyWith(
          size: size,
          aspectRatio: ratio > 0 ? ratio : (16 / 9),
        );
        notifyListeners();
      }),
    );

    _subscriptions.add(
      player.stream.rate.listen((rate) {
        if (_isDisposed) return;
        _value = _value.copyWith(playbackSpeed: rate);
        notifyListeners();
      }),
    );

    _subscriptions.add(
      player.stream.error.listen((err) {
        if (_isDisposed) return;
        _value = _value.copyWith(
          hasError: true,
          errorDescription: err,
        );
        notifyListeners();
      }),
    );
  }

  /// Chờ cho đến khi media được nạp xong và xác định được độ dài / kích thước
  Future<void> initialize({Duration timeout = const Duration(seconds: 25)}) async {
    if (_value.isInitialized) return;
    try {
      await _initCompleter.future.timeout(timeout);
    } catch (_) {
      // Nếu timeout mà video vẫn có thể play, đánh dấu initialized
      if (!_isDisposed) {
        _value = _value.copyWith(isInitialized: true);
        notifyListeners();
      }
    }
  }

  /// Phát luồng Bilibili DASH (Video và Audio phân đoạn song song)
  Future<void> openBilibiliDash({
    required String videoUrl,
    required String audioUrl,
    Map<String, String> headers = const {},
  }) async {
    if (headers.isNotEmpty && player.platform is NativePlayer) {
      final headerStr = headers.entries.map((e) => '${e.key}: ${e.value}').join('\r\n');
      final nativePlayer = player.platform as NativePlayer;
      await nativePlayer.setProperty('http-header-fields', headerStr);
    }

    // Nạp luồng video chính
    await player.open(
      Media(
        videoUrl,
        httpHeaders: headers,
      ),
      play: false,
    );

    // Ghép luồng âm thanh rời (tự động đồng bộ PTS)
    if (audioUrl.isNotEmpty && player.platform is NativePlayer) {
      final nativePlayer = player.platform as NativePlayer;
      await nativePlayer.command(['audio-add', audioUrl, 'select']);
    }
  }

  /// Phát video qua link mạng thông thường (MP4, HLS/M3U8)
  Future<void> openNetwork(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    if (headers.isNotEmpty && player.platform is NativePlayer) {
      final headerStr = headers.entries.map((e) => '${e.key}: ${e.value}').join('\r\n');
      final nativePlayer = player.platform as NativePlayer;
      await nativePlayer.setProperty('http-header-fields', headerStr);
    }
    await player.open(
      Media(url, httpHeaders: headers),
      play: false,
    );
  }

  /// Phát file video cục bộ trên máy
  Future<void> openFile(File file) async {
    final uri = Uri.file(file.path);
    await player.open(
      Media(uri.toString()),
      play: false,
    );
  }

  /// Phát Content URI (Android)
  Future<void> openContentUri(Uri uri) async {
    await player.open(
      Media(uri.toString()),
      play: false,
    );
  }

  Future<void> play() async {
    if (!_isDisposed) await player.play();
  }

  Future<void> pause() async {
    if (!_isDisposed) await player.pause();
  }

  Future<void> seekTo(Duration position) async {
    if (!_isDisposed) await player.seek(position);
  }

  Future<void> setPlaybackSpeed(double speed) async {
    if (!_isDisposed) await player.setRate(speed);
  }

  /// Volume trong video_player là 0.0 - 1.0, còn media_kit là 0.0 - 100.0
  Future<void> setVolume(double volume) async {
    if (!_isDisposed) {
      final clamped = volume.clamp(0.0, 1.0) * 100.0;
      await player.setVolume(clamped);
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    player.dispose();
    super.dispose();
  }
}

/// Widget hiển thị bề mặt video media_kit sạch sẽ (không dính điều khiển mặc định)
class AppVideoPlayer extends StatelessWidget {
  final AppPlayerController controller;

  const AppVideoPlayer(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    return Video(
      controller: controller.videoController,
      controls: NoVideoControls,
    );
  }
}
