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
  Completer<void> _initCompleter = Completer<void>();

  AppPlayerController({int? bufferSizeMb, bool silent = false}) {
    final mb = (bufferSizeMb ?? 64).clamp(16, 256);
    player = Player(
      configuration: PlayerConfiguration(
        title: 'CapSub MediaKit Player',
        bufferSize: mb * 1024 * 1024,
        muted: silent,
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
          _value = _value.copyWith(duration: dur, isInitialized: true);
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
        _value = _value.copyWith(hasError: true, errorDescription: err);
        notifyListeners();
      }),
    );
  }

  bool _hasRealVideoTrack(Tracks tracks) {
    return tracks.video.any((track) => track.id != 'auto' && track.id != 'no');
  }

  bool _hasRealAudioTrack(Tracks tracks) {
    return tracks.audio.any((track) => track.id != 'auto' && track.id != 'no');
  }

  /// Chờ mpv nạp xong demuxer video trước khi gắn audio DASH rời.
  /// Nếu gắn audio ngay sau `open`, lệnh có thể bị reset bởi quá trình load video.
  Future<void> _waitForPrimaryVideoTrack() async {
    if (_hasRealVideoTrack(player.state.tracks)) return;
    await player.stream.tracks
        .firstWhere(_hasRealVideoTrack)
        .timeout(const Duration(seconds: 10));
  }

  Future<void> _attachBilibiliAudio(String audioUrl) async {
    if (audioUrl.isEmpty || _isDisposed) return;

    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        await player.setAudioTrack(
          AudioTrack.uri(audioUrl, title: 'Bilibili DASH audio'),
        );

        if (!_hasRealAudioTrack(player.state.tracks)) {
          await player.stream.tracks
              .firstWhere(_hasRealAudioTrack)
              .timeout(const Duration(seconds: 4));
        }
        return;
      } catch (error) {
        lastError = error;
        if (attempt < 3) {
          await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
        }
      }
    }

    throw StateError('Không thể gắn audio DASH Bilibili: $lastError');
  }

  /// Chờ cho đến khi media được nạp xong và xác định được độ dài / kích thước
  Future<void> initialize({
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (_value.isInitialized && _value.duration > Duration.zero) return;
    try {
      await _initCompleter.future.timeout(timeout);
    } catch (_) {
      // Nếu timeout mà player đã đọc được duration hợp lệ từ stream mpv thì chấp nhận
      if (!_isDisposed && player.state.duration > Duration.zero) {
        _value = _value.copyWith(
          duration: player.state.duration,
          isInitialized: true,
        );
        notifyListeners();
        return;
      }
      // Ngược lại, nếu hết thời gian mà duration vẫn = 0 (do nghẽn tải metadata MP4 lớn hoặc link chết),
      // ném TimeoutException để caller biết mà tự động chuyển sang luồng dự phòng (DASH)
      throw TimeoutException(
        'Không tải được thông tin video trong thời gian quy định (${timeout.inSeconds}s)',
      );
    }
  }

  /// Phát luồng Bilibili DASH (Video và Audio phân đoạn song song)
  Future<void> openBilibiliDash({
    required String videoUrl,
    required String audioUrl,
    Map<String, String> headers = const {},
  }) async {
    if (headers.isNotEmpty && player.platform is NativePlayer) {
      final headerStr = headers.entries
          .map((e) => '${e.key}: ${e.value}')
          .join('\r\n');
      final nativePlayer = player.platform as NativePlayer;
      await nativePlayer.setProperty('http-header-fields', headerStr);
    }

    // Nạp luồng video chính
    await player.open(Media(videoUrl, httpHeaders: headers), play: false);

    // Chờ video load ổn định rồi mới ghép audio để tránh mpv reset mất track.
    if (audioUrl.isNotEmpty && player.platform is NativePlayer) {
      await _waitForPrimaryVideoTrack();
      await _attachBilibiliAudio(audioUrl);
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
    bool silentStandby = false,
  }) async {
    if (_isDisposed) return;
    try {
      await player.pause();
    } catch (_) {}

    // Mỗi nguồn media phải có vòng đời khởi tạo riêng. Giữ lại duration,
    // kích thước hoặc Completer của nguồn trước sẽ khiến UI hiển thị sai tỷ lệ,
    // thanh tiến trình cũ và initialize() trả về quá sớm.
    _initCompleter = Completer<void>();
    _value = AppVideoPlayerValue(playbackSpeed: _value.playbackSpeed);
    notifyListeners();

    if (silentStandby) {
      try {
        await player.setVolume(0.0);
        if (player.platform is NativePlayer) {
          final native = player.platform as NativePlayer;
          await native.setProperty('mute', 'yes');
          await native.setProperty('aid', 'no');
          await native.setProperty('demuxer-readahead-secs', '1');
        }
        await player.setAudioTrack(AudioTrack.no());
      } catch (_) {}
    } else {
      try {
        if (player.platform is NativePlayer) {
          final native = player.platform as NativePlayer;
          await native.setProperty('demuxer-readahead-secs', '10');
          await native.setProperty('mute', 'no');
          await native.setProperty('aid', 'auto');
        }
        await player.setAudioTrack(AudioTrack.auto());
        await player.setVolume(100.0);
      } catch (_) {}
    }

    if (dashVideoUrl != null && dashVideoUrl.isNotEmpty) {
      await openBilibiliDash(
        videoUrl: dashVideoUrl,
        audioUrl: dashAudioUrl ?? '',
        headers: headers,
      );
    } else if (file != null) {
      await openFile(file, play: play);
    } else if (contentUri != null) {
      await openContentUri(contentUri, play: play);
    } else if (networkUrl != null && networkUrl.isNotEmpty) {
      await openNetwork(networkUrl, headers: headers, play: play);
    }

    if (silentStandby) {
      try {
        await player.setAudioTrack(AudioTrack.no());
        await player.setVolume(0.0);
        if (player.platform is NativePlayer) {
          final native = player.platform as NativePlayer;
          await native.setProperty('mute', 'yes');
          await native.setProperty('aid', 'no');
        }
      } catch (_) {}
    }

    if (player.state.duration > Duration.zero) {
      _value = _value.copyWith(
        duration: player.state.duration,
        isInitialized: true,
      );
      if (!_initCompleter.isCompleted) {
        _initCompleter.complete();
      }
      notifyListeners();
    } else {
      unawaited(
        player.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 4))
            .then((dur) {
              if (!_isDisposed) {
                _value = _value.copyWith(duration: dur, isInitialized: true);
                if (!_initCompleter.isCompleted) {
                  _initCompleter.complete();
                }
                notifyListeners();
              }
            })
            .catchError((_) {}),
      );
    }

    if (play && !_isDisposed && !player.state.playing) {
      await player.play();
    }
  }

  /// Kích hoạt phát video có tiếng (thoát khỏi chế độ standby yên lặng)
  Future<void> unmuteAndPlay({
    double rate = 1.0,
    PlaylistMode playlistMode = PlaylistMode.loop,
  }) async {
    if (_isDisposed) return;
    try {
      if (player.platform is NativePlayer) {
        final native = player.platform as NativePlayer;
        await native.setProperty('demuxer-readahead-secs', '10');
        await native.setProperty('mute', 'no');
        await native.setProperty('aid', 'auto');
      }
      await player.setAudioTrack(AudioTrack.auto());
      await setVolume(1.0);
      await player.setPlaylistMode(playlistMode);
      await player.setRate(rate);
      await player.play();
    } catch (e) {
      debugPrint('[AppPlayerController] unmuteAndPlay lỗi: $e');
    }
  }

  /// Tạm dừng và tắt tiếng hoàn toàn (đưa vào trạng thái standby yên lặng)
  Future<void> muteAndPause() async {
    if (_isDisposed) return;
    try {
      await player.pause();
      await setVolume(0.0);
      if (player.platform is NativePlayer) {
        final native = player.platform as NativePlayer;
        await native.setProperty('mute', 'yes');
        await native.setProperty('aid', 'no');
        await native.setProperty('demuxer-readahead-secs', '1');
      }
      await player.setAudioTrack(AudioTrack.no());
    } catch (_) {}
  }

  /// Phát video qua link mạng thông thường (MP4, HLS/M3U8)
  Future<void> openNetwork(
    String url, {
    Map<String, String> headers = const {},
    bool play = false,
  }) async {
    if (player.platform is NativePlayer) {
      final nativePlayer = player.platform as NativePlayer;
      if (headers.isNotEmpty) {
        final headerStr = headers.entries
            .map((e) => '${e.key}: ${e.value}')
            .join('\r\n');
        await nativePlayer.setProperty('http-header-fields', headerStr);
      } else {
        await nativePlayer.setProperty('http-header-fields', '');
      }
    }
    await player.open(Media(url, httpHeaders: headers), play: play);
  }

  /// Phát file video cục bộ trên máy
  Future<void> openFile(File file, {bool play = false}) async {
    final uri = Uri.file(file.path);
    await player.open(Media(uri.toString()), play: play);
  }

  /// Phát Content URI (Android)
  Future<void> openContentUri(Uri uri, {bool play = false}) async {
    await player.open(Media(uri.toString()), play: play);
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
