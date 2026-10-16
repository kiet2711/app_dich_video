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
  bool get isDisposed => _isDisposed;
  final Completer<void> _initCompleter = Completer<void>();

  String? _currentDashVideoUrl;
  String? get currentDashVideoUrl => _currentDashVideoUrl;
  String? _currentDashAudioUrl;
  String? get currentDashAudioUrl => _currentDashAudioUrl;
  Map<String, String> _currentDashHeaders = const {};

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

    _subscriptions.add(
      player.stream.tracks.listen((tracks) {
        if (_isDisposed) return;
        // Tự động kiểm tra và kích hoạt lại track âm thanh nếu mpv vừa load xong video demuxer
        if (_currentDashAudioUrl != null && _currentDashAudioUrl!.isNotEmpty) {
          _ensureAudioTrackActive();
        }
      }),
    );
  }

  /// Đảm bảo luồng âm thanh rời (DASH) được gắn kết và chọn phát đúng cách
  Future<void> _ensureAudioTrackActive() async {
    if (_isDisposed || _currentDashAudioUrl == null || _currentDashAudioUrl!.isEmpty) return;
    try {
      final audioTracks = player.state.tracks.audio;
      final currentAudioTrack = player.state.track.audio;

      // 1. Nếu mpv đã có track âm thanh nhưng chưa được chọn hoặc đang là 'no'
      if (audioTracks.isNotEmpty) {
        final activeTrack = audioTracks.firstWhere(
          (t) => t.id != 'no' && t.id != 'auto',
          orElse: () => audioTracks.first,
        );
        if (currentAudioTrack.id == 'no' || currentAudioTrack.id != activeTrack.id) {
          await player.setAudioTrack(activeTrack);
        }
      } else {
        // 2. Nếu mpv chưa có audio track (bị reset do loadfile video chính), gửi lệnh add lại
        if (player.platform is NativePlayer) {
          final nativePlayer = player.platform as NativePlayer;
          if (_currentDashHeaders.isNotEmpty) {
            final headerStr = _currentDashHeaders.entries.map((e) => '${e.key}: ${e.value}').join('\r\n');
            await nativePlayer.setProperty('http-header-fields', headerStr);
          }
          await nativePlayer.command(['audio-add', _currentDashAudioUrl!, 'select']);
        }
      }
    } catch (e) {
      debugPrint('[AppPlayerController] Lỗi kiểm tra kích hoạt âm thanh DASH: $e');
    }
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
    // Demuxer video đã sẵn sàng: xác thực và gắn kết lại audio track nếu cần
    if (_currentDashAudioUrl != null) {
      await _ensureAudioTrackActive();
    }
  }

  /// Phát luồng Bilibili DASH (Video và Audio phân đoạn song song)
  Future<void> openBilibiliDash({
    required String videoUrl,
    required String audioUrl,
    Map<String, String> headers = const {},
  }) async {
    _currentDashVideoUrl = videoUrl;
    _currentDashAudioUrl = audioUrl;
    _currentDashHeaders = headers;

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
      try {
        await nativePlayer.command(['audio-add', audioUrl, 'select']);
      } catch (_) {}
    }
  }

  /// Chuyển đổi nguồn phát media mà không cần hủy controller hay tái tạo texture
  Future<void> switchMedia({
    String? networkUrl,
    File? file,
    Uri? contentUri,
    String? dashVideoUrl,
    String? dashAudioUrl,
    Map<String, String> headers = const {},
    bool play = false,
  }) async {
    if (_isDisposed) return;
    try {
      await player.pause();
    } catch (_) {}

    _currentDashVideoUrl = null;
    _currentDashAudioUrl = null;
    _currentDashHeaders = const {};

    _value = _value.copyWith(
      position: Duration.zero,
      isPlaying: false,
      hasError: false,
      errorDescription: null,
    );
    notifyListeners();

    if (dashVideoUrl != null && dashVideoUrl.isNotEmpty) {
      await openBilibiliDash(
        videoUrl: dashVideoUrl,
        audioUrl: dashAudioUrl ?? '',
        headers: headers,
      );
    } else if (file != null) {
      await openFile(file);
    } else if (contentUri != null) {
      await openContentUri(contentUri);
    } else if (networkUrl != null && networkUrl.isNotEmpty) {
      await openNetwork(networkUrl, headers: headers);
    }

    if (player.state.duration > Duration.zero) {
      _value = _value.copyWith(duration: player.state.duration);
      if (_currentDashAudioUrl != null) {
        await _ensureAudioTrackActive();
      }
    } else {
      try {
        final dur = await player.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 4));
        _value = _value.copyWith(duration: dur);
        if (_currentDashAudioUrl != null) {
          await _ensureAudioTrackActive();
        }
      } catch (_) {}
    }

    if (play && !_isDisposed) {
      await this.play();
    }
  }

  /// Phát video qua link mạng thông thường (MP4, HLS/M3U8)
  Future<void> openNetwork(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    _currentDashVideoUrl = null;
    _currentDashAudioUrl = null;
    _currentDashHeaders = const {};
    if (player.platform is NativePlayer) {
      final nativePlayer = player.platform as NativePlayer;
      if (headers.isNotEmpty) {
        final headerStr = headers.entries.map((e) => '${e.key}: ${e.value}').join('\r\n');
        await nativePlayer.setProperty('http-header-fields', headerStr);
      } else {
        await nativePlayer.setProperty('http-header-fields', '');
      }
    }
    await player.open(
      Media(url, httpHeaders: headers),
      play: false,
    );
  }

  /// Phát file video cục bộ trên máy
  Future<void> openFile(File file) async {
    _currentDashVideoUrl = null;
    _currentDashAudioUrl = null;
    _currentDashHeaders = const {};
    final uri = Uri.file(file.path);
    await player.open(
      Media(uri.toString()),
      play: false,
    );
  }

  /// Phát Content URI (Android)
  Future<void> openContentUri(Uri uri) async {
    _currentDashVideoUrl = null;
    _currentDashAudioUrl = null;
    _currentDashHeaders = const {};
    await player.open(
      Media(uri.toString()),
      play: false,
    );
  }

  Future<void> play() async {
    if (!_isDisposed) {
      if (_currentDashAudioUrl != null) {
        await _ensureAudioTrackActive();
      }
      await player.play();
    }
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
