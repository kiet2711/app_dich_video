import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Trạng thái đồng bộ của trình phát media_kit tương thích với giao diện CapSub
class AppVideoPlayerValue {
  final bool isInitialized;
  final bool isPlaying;
  final bool isBuffering;
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
    this.isBuffering = false,
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
    bool? isBuffering,
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
      isBuffering: isBuffering ?? this.isBuffering,
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
  final int _bufferSizeMb;
  final bool hardwareDecode;
  AppVideoPlayerValue _value = const AppVideoPlayerValue();

  AppVideoPlayerValue get value => _value;

  final List<StreamSubscription> _subscriptions = [];
  bool _isDisposed = false;
  bool _inSilentStandby = false;
  bool _isFailoveringCdn = false;
  static bool _isAndroidEmulator = false;
  static bool _platformDetected = false;

  static bool get isAndroidEmulator => _isAndroidEmulator;

  /// Kiểm tra một lần xem app có đang chạy trên Android Emulator hay không
  /// để tránh ghi đè cấu hình máy thật.
  static Future<void> ensurePlatformDetected() async {
    if (_platformDetected || !Platform.isAndroid) {
      _platformDetected = true;
      return;
    }
    _platformDetected = true;
    try {
      final detected = await const MethodChannel('com.capcut.capsub/media')
          .invokeMethod<bool>('isEmulator');
      _isAndroidEmulator = detected ?? false;
      debugPrint('[AppPlayerController] isAndroidEmulator=$_isAndroidEmulator');
    } catch (_) {
      _isAndroidEmulator = false;
    }
  }

  List<({String videoUrl, String audioUrl})> _activeDashPairs = const [];
  Map<String, String> _activeDashHeaders = const {};
  int _activeDashPairIndex = 0;
  DateTime? _lastFailoverAt;
  bool get isDisposed => _isDisposed;
  Completer<void> _initCompleter = Completer<void>();
  late final Future<void> _baseOptionsFuture;
  final ValueNotifier<double?> videoAspectNotifier = ValueNotifier<double?>(
    null,
  );

  AppPlayerController({
    int? bufferSizeMb,
    bool silent = false,
    this.hardwareDecode = true,
  }) : _bufferSizeMb = (bufferSizeMb ?? 64).clamp(16, 256) {
    _inSilentStandby = silent;
    player = Player(
      configuration: PlayerConfiguration(
        title: 'CapSub MediaKit Player',
        bufferSize: _bufferSizeMb * 1024 * 1024,
        muted: silent,
      ),
    );
    final useEmulatorDirectSurface = Platform.isAndroid && _isAndroidEmulator;
    videoController = VideoController(
      player,
      configuration: VideoControllerConfiguration(
        vo: useEmulatorDirectSurface ? 'mediacodec_embed' : null,
        enableHardwareAcceleration: useEmulatorDirectSurface
            ? true
            : hardwareDecode,
        androidAttachSurfaceAfterVideoParameters: Platform.isAndroid
            ? false
            : null,
        hwdec: useEmulatorDirectSurface
            ? 'mediacodec'
            : (hardwareDecode
                  ? (Platform.isAndroid ? 'mediacodec,auto-safe' : 'auto')
                  : 'no'),
      ),
    );

    _listenToPlayerStreams();
    _baseOptionsFuture = _applyBaseMpvOptions();
  }

  /// Ghép DASH video + audio của Bilibili thành một nguồn `edl://` hợp nhất theo kiểu PiliPlus.
  /// Nhờ `mpv` mở song song cả hai track trong cùng demuxer timeline, việc tải nhanh hơn hẳn,
  /// không bị rớt audio rời khi tua và giữ đồng bộ hình/tiếng tuyệt đối.
  static String buildBilibiliEdlUri({
    required String videoUrl,
    String audioUrl = '',
  }) {
    final cleanV = videoUrl.trim();
    final cleanA = audioUrl.trim();
    if (cleanV.isEmpty || cleanA.isEmpty) return cleanV;
    final vLen = utf8.encode(cleanV).length;
    final aLen = utf8.encode(cleanA).length;
    return 'edl://!no_chapters;%$vLen%$cleanV;!new_stream;!no_chapters;%$aLen%$cleanA';
  }

  /// Nối danh sách phân đoạn `durl` nhiều phần thành một timeline `edl://` liên tục.
  static String buildMultiPartEdlUri(
    List<({String url, double? durationSec})> segments,
  ) {
    final valid = segments.where((s) => s.url.trim().isNotEmpty).toList();
    if (valid.isEmpty) return '';
    if (valid.length == 1) return valid.first.url.trim();
    final sb = StringBuffer('edl://!no_chapters;');
    for (final seg in valid) {
      final clean = seg.url.trim();
      final len = utf8.encode(clean).length;
      if (seg.durationSec != null && seg.durationSec! > 0) {
        sb.write('%$len%$clean,length=${seg.durationSec!.toStringAsFixed(3)};');
      } else {
        sb.write('%$len%$clean;');
      }
    }
    return sb.toString();
  }

  Future<void> _applyBaseMpvOptions() async {
    if (_isDisposed || player.platform is! NativePlayer) return;
    final native = player.platform as NativePlayer;
    try {
      if (Platform.isAndroid) {
        await native.setProperty('force-window', 'no');
        await native.setProperty('autosync', '30');
      }
      // Dùng đồng bộ theo đồng hồ audio (mặc định ổn định của mpv cho Android 90/120Hz),
      // tránh `display-resample` giật frame khi không có override display-fps.
      await native.setProperty('video-sync', 'audio');
      await native.setProperty('hr-seek', 'yes');
      // Cho phép bỏ qua frame trung gian khi tua xa để thanh tua phản hồi tức thì, không đứng hình.
      await native.setProperty('hr-seek-framedrop', 'yes');
    } catch (_) {}
  }

  Future<void> _applyStreamBufferProperties({
    required bool isLocalFile,
    bool silentStandby = false,
  }) async {
    await _baseOptionsFuture;
    if (_isDisposed || player.platform is! NativePlayer) return;
    final native = player.platform as NativePlayer;
    try {
      if (isLocalFile) {
        await native.setProperty('cache', 'no');
        return;
      }
      final forwardMb = _bufferSizeMb.clamp(24, 64);
      final backMb = (_bufferSizeMb ~/ 2).clamp(12, 32);
      await native.setProperty('cache', 'yes');
      // Giữ cache thuần trên RAM, tắt cache-on-disk để tránh khựng I/O bộ nhớ flash điện thoại.
      await native.setProperty('cache-on-disk', 'no');
      // KHÔNG đặt `demuxer-readahead-secs` riêng vì sẽ ghi đè `cache-secs`.
      // Để `hysteresis = 3s` trên `cache-secs = 30s` để mpv luôn nạp gối đầu liên tục ở mức 27s-30s,
      // không để cạn sát 0s rồi mới kéo lại mỗi vài giây.
      await native.setProperty('cache-secs', silentStandby ? '18' : '24');
      await native.setProperty('demuxer-hysteresis-secs', '3');
      await native.setProperty('cache-pause', 'yes');
      await native.setProperty('cache-pause-initial', 'yes');
      await native.setProperty(
        'cache-pause-wait',
        silentStandby ? '0.5' : '1.0',
      );
      await native.setProperty(
        'demuxer-max-bytes',
        '${forwardMb * 1024 * 1024}',
      );
      await native.setProperty(
        'demuxer-max-back-bytes',
        '${backMb * 1024 * 1024}',
      );
      await native.setProperty('network-timeout', '15');
    } catch (_) {}
  }

  Future<void> _applyNetworkStreamOptions({
    String? urlForHint,
    Map<String, String> headers = const {},
    String? decryptionKey,
  }) async {
    if (_isDisposed || player.platform is! NativePlayer) return;
    final native = player.platform as NativePlayer;
    try {
      final ua = headers['User-Agent'] ?? headers['user-agent'] ?? '';
      final referer = headers['Referer'] ?? headers['referer'] ?? '';
      if (ua.isNotEmpty) {
        await native.setProperty('user-agent', ua);
      }
      // Luôn gán hoặc xóa referrer theo nguồn hiện tại để không rò header Bilibili sang nguồn khác.
      await native.setProperty('referrer', referer);

      if (headers.isNotEmpty) {
        final headerStr = headers.entries
            .map((e) => '${e.key}: ${e.value}')
            .join('\r\n');
        await native.setProperty('http-header-fields', headerStr);
      } else {
        await native.setProperty('http-header-fields', '');
      }

      final lowerUrl = (urlForHint ?? '').toLowerCase();
      final needsHlsOrCenc =
          (decryptionKey != null && decryptionKey.isNotEmpty) ||
          lowerUrl.contains('.m3u8');
      if (needsHlsOrCenc) {
        final lavfOptions = <String>[
          'seg_max_retry=3',
          'strict=experimental',
          'allowed_extensions=ALL',
          'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
        ];
        if (decryptionKey != null && decryptionKey.isNotEmpty) {
          lavfOptions.add('decryption_key=$decryptionKey');
        }
        await native.setProperty('demuxer-lavf-o', lavfOptions.join(','));
      } else if (lowerUrl.startsWith('http://') ||
          lowerUrl.startsWith('https://')) {
        // Tự động nối lại HTTP Range nếu CDN rớt kết nối giữa chừng thay vì khựng đứng chờ timeout.
        await native.setProperty(
          'demuxer-lavf-o',
          'reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=2,reconnect_max_retries=5',
        );
      } else {
        await native.setProperty('demuxer-lavf-o', '');
      }
    } catch (_) {}
  }

  void _resetCompleterAndState() {
    _initCompleter = Completer<void>();
    videoAspectNotifier.value = null;
    _value = AppVideoPlayerValue(playbackSpeed: _value.playbackSpeed);
    notifyListeners();
  }

  void _completeInitializedIfReady(Duration dur) {
    if (_isDisposed || dur <= Duration.zero) return;
    _value = _value.copyWith(
      duration: dur,
      isInitialized: true,
      hasError: false,
    );
    if (!_initCompleter.isCompleted) {
      _initCompleter.complete();
    }
    notifyListeners();
  }

  void _listenToPlayerStreams() {
    _subscriptions.add(
      player.stream.playing.listen((playing) {
        if (_isDisposed || _value.isPlaying == playing) return;
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
        if (_isDisposed || dur <= Duration.zero) return;
        _completeInitializedIfReady(dur);
      }),
    );

    _subscriptions.add(
      player.stream.width.listen((w) {
        if (_isDisposed || w == null || w <= 0) return;
        final h = player.state.height ?? 0;
        final size = Size(w.toDouble(), h > 0 ? h.toDouble() : 1080);
        final ratio = h > 0 ? (w / h) : (16 / 9);
        if (h > 0 && ratio > 0 && videoAspectNotifier.value != ratio) {
          videoAspectNotifier.value = ratio;
        }
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
        if (w > 0 && ratio > 0 && videoAspectNotifier.value != ratio) {
          videoAspectNotifier.value = ratio;
        }
        _value = _value.copyWith(
          size: size,
          aspectRatio: ratio > 0 ? ratio : (16 / 9),
        );
        notifyListeners();
      }),
    );

    _subscriptions.add(
      player.stream.buffering.listen((buffering) {
        if (_isDisposed || _value.isBuffering == buffering) return;
        _value = _value.copyWith(isBuffering: buffering);
        notifyListeners();
      }),
    );

    _subscriptions.add(
      player.stream.rate.listen((rate) {
        if (_isDisposed || _value.playbackSpeed == rate) return;
        _value = _value.copyWith(playbackSpeed: rate);
        notifyListeners();
      }),
    );

    _subscriptions.add(
      player.stream.error.listen((err) {
        if (_isDisposed || err.trim().isEmpty) return;
        final lower = err.toLowerCase();
        final isTransientNetErr =
            lower.contains('tcp:') ||
            lower.contains('ffurl_read') ||
            lower.contains('failed to open https://') ||
            lower.contains('can not open external file');
        if (isTransientNetErr && hasBackupBilibiliCdn) {
          unawaited(failoverNextBilibiliCdn());
          return;
        }
        _value = _value.copyWith(hasError: true, errorDescription: err);
        notifyListeners();
      }),
    );
  }

  bool get hasBackupBilibiliCdn =>
      _activeDashPairs.length > 1 &&
      _activeDashPairIndex + 1 < _activeDashPairs.length;

  /// Tự động chuyển sang cặp CDN Bilibili dự phòng ngay tại vị trí đang xem nếu CDN hiện tại đứt TCP hoặc khựng quá lâu.
  Future<bool> failoverNextBilibiliCdn() async {
    if (_isDisposed || _isFailoveringCdn || !hasBackupBilibiliCdn) {
      return false;
    }
    final now = DateTime.now();
    if (_lastFailoverAt != null &&
        now.difference(_lastFailoverAt!) < const Duration(seconds: 4)) {
      return false;
    }
    _isFailoveringCdn = true;
    _lastFailoverAt = now;
    try {
      final nextIndex = _activeDashPairIndex + 1;
      if (nextIndex >= _activeDashPairs.length) return false;
      final pair = _activeDashPairs[nextIndex];
      final resumePos = player.state.position;
      final wasPlaying = player.state.playing || _value.isPlaying;
      _activeDashPairIndex = nextIndex;
      await openBilibiliDash(
        videoUrl: pair.videoUrl,
        audioUrl: pair.audioUrl,
        headers: _activeDashHeaders,
        startPosition: resumePos > Duration.zero ? resumePos : null,
        play: wasPlaying,
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      _isFailoveringCdn = false;
    }
  }

  /// Chờ cho đến khi media được nạp xong và xác định được độ dài / kích thước
  Future<void> initialize({
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (_value.isInitialized && _value.duration > Duration.zero) return;
    if (!_isDisposed && player.state.duration > Duration.zero) {
      _completeInitializedIfReady(player.state.duration);
      return;
    }
    try {
      await _initCompleter.future.timeout(timeout);
    } catch (_) {
      if (!_isDisposed && player.state.duration > Duration.zero) {
        _completeInitializedIfReady(player.state.duration);
        return;
      }
      throw TimeoutException(
        'Không tải được thông tin video trong thời gian quy định (${timeout.inSeconds}s)',
      );
    }
  }

  /// Phát luồng Bilibili DASH bằng `edl://` hợp nhất video & audio ngay từ bước mở stream.
  Future<void> openBilibiliDash({
    required String videoUrl,
    required String audioUrl,
    Map<String, String> headers = const {},
    Duration? startPosition,
    bool play = false,
  }) async {
    if (_isDisposed) return;
    await _applyStreamBufferProperties(isLocalFile: false);
    await _applyNetworkStreamOptions(urlForHint: videoUrl, headers: headers);
    final edlUri = buildBilibiliEdlUri(videoUrl: videoUrl, audioUrl: audioUrl);
    await player.open(
      Media(
        edlUri,
        httpHeaders: headers.isEmpty ? null : headers,
        start: (startPosition != null && startPosition > Duration.zero)
            ? startPosition
            : null,
      ),
      play: play,
    );
  }

  /// Thử lần lượt các cặp DASH CDN dự phòng rồi fallback sang `durl` trên CÙNG một instance Player
  /// (tránh tạo/hủy nhiều VideoController gây nghẽn MediaCodec dẫn tới đen màn hình còn tiếng).
  Future<String> openBilibiliCandidates({
    List<({String videoUrl, String audioUrl})> dashPairs = const [],
    List<String> fallbackMuxedUrls = const [],
    String? fallbackMuxedEdl,
    Map<String, String> headers = const {},
    Duration? startPosition,
    bool play = false,
    Duration perCandidateTimeout = const Duration(seconds: 10),
  }) async {
    Object? lastError;
    _activeDashPairs = List.unmodifiable(dashPairs);
    _activeDashHeaders = Map.unmodifiable(headers);
    _activeDashPairIndex = 0;

    for (var i = 0; i < dashPairs.length; i++) {
      if (_isDisposed) break;
      final pair = dashPairs[i];
      _activeDashPairIndex = i;
      try {
        _resetCompleterAndState();
        await openBilibiliDash(
          videoUrl: pair.videoUrl,
          audioUrl: pair.audioUrl,
          headers: headers,
          startPosition: startPosition,
          play: play,
        );
        await initialize(timeout: perCandidateTimeout);
        if (_value.hasError && player.state.duration <= Duration.zero) {
          throw StateError(_value.errorDescription ?? 'DASH playback failed');
        }
        return pair.videoUrl;
      } catch (e) {
        lastError = e;
      }
    }

    _activeDashPairs = const [];
    _activeDashPairIndex = 0;

    final muxCandidates = <String>[
      if (fallbackMuxedEdl != null && fallbackMuxedEdl.isNotEmpty)
        fallbackMuxedEdl,
      ...fallbackMuxedUrls.where((u) => u.trim().isNotEmpty),
    ];

    for (final url in muxCandidates) {
      if (_isDisposed) break;
      try {
        _resetCompleterAndState();
        await openNetwork(
          url,
          headers: headers,
          startPosition: startPosition,
          play: play,
        );
        await initialize(timeout: perCandidateTimeout);
        return url;
      } catch (e) {
        lastError = e;
      }
    }

    throw lastError ??
        StateError('Không thể khởi tạo bất kỳ luồng phát Bilibili nào.');
  }

  /// Chuyển đổi nguồn phát media mà không cần hủy controller hay tái tạo texture
  Future<void> switchMedia({
    String? networkUrl,
    File? file,
    Uri? contentUri,
    String? dashVideoUrl,
    String? dashAudioUrl,
    List<({String videoUrl, String audioUrl})>? bilibiliDashPairs,
    List<String> bilibiliFallbackUrls = const [],
    String? bilibiliFallbackEdl,
    Duration? startPosition,
    String? decryptionKey,
    Map<String, String> headers = const {},
    bool play = false,
    bool silentStandby = false,
  }) async {
    if (_isDisposed) return;
    try {
      await player.pause();
    } catch (_) {}

    if (silentStandby) {
      _inSilentStandby = true;
      try {
        await player.setVolume(0.0);
        if (player.platform is NativePlayer) {
          final native = player.platform as NativePlayer;
          await native.setProperty('mute', 'yes');
        }
      } catch (_) {}
    } else if (_inSilentStandby) {
      _inSilentStandby = false;
      try {
        if (player.platform is NativePlayer) {
          final native = player.platform as NativePlayer;
          await native.setProperty('mute', 'no');
        }
        await player.setVolume(100.0);
      } catch (_) {}
    }

    final isLocal = file != null || contentUri != null;
    await _applyStreamBufferProperties(
      isLocalFile: isLocal,
      silentStandby: silentStandby,
    );

    if ((bilibiliDashPairs != null && bilibiliDashPairs.isNotEmpty) ||
        (bilibiliFallbackUrls.isNotEmpty) ||
        (bilibiliFallbackEdl != null && bilibiliFallbackEdl.isNotEmpty)) {
      await openBilibiliCandidates(
        dashPairs: bilibiliDashPairs ?? const [],
        fallbackMuxedUrls: bilibiliFallbackUrls,
        fallbackMuxedEdl: bilibiliFallbackEdl,
        headers: headers,
        startPosition: startPosition,
        play: play,
      );
      return;
    }

    _resetCompleterAndState();

    if (dashVideoUrl != null && dashVideoUrl.isNotEmpty) {
      await openBilibiliDash(
        videoUrl: dashVideoUrl,
        audioUrl: dashAudioUrl ?? '',
        headers: headers,
        startPosition: startPosition,
        play: play,
      );
    } else if (file != null) {
      await openFile(file, play: play);
    } else if (contentUri != null) {
      await openContentUri(contentUri, play: play);
    } else if (networkUrl != null && networkUrl.isNotEmpty) {
      await openNetwork(
        networkUrl,
        headers: headers,
        decryptionKey: decryptionKey,
        startPosition: startPosition,
        play: play,
      );
    }

    if (silentStandby) {
      try {
        await player.setVolume(0.0);
        if (player.platform is NativePlayer) {
          final native = player.platform as NativePlayer;
          await native.setProperty('mute', 'yes');
        }
      } catch (_) {}
    }

    if (_isDisposed) return;

    if (player.state.duration > Duration.zero) {
      _completeInitializedIfReady(player.state.duration);
    } else {
      unawaited(
        player.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 6))
            .then(_completeInitializedIfReady)
            .catchError((_) {}),
      );
    }

    if (play && !_isDisposed && !player.state.playing) {
      await player.play();
    }
  }

  /// Kích hoạt phát video có tiếng (thoát khỏi chế độ standby yên lặng)
  /// Giữ nguyên audio track và demuxer cache đang mở sẵn để phát ngay không khựng frame.
  Future<void> unmuteAndPlay({
    double rate = 1.0,
    PlaylistMode playlistMode = PlaylistMode.loop,
  }) async {
    if (_isDisposed) return;
    _inSilentStandby = false;
    try {
      if (player.platform is NativePlayer) {
        final native = player.platform as NativePlayer;
        await native.setProperty('mute', 'no');
      }
      await Future.wait([
        setVolume(1.0),
        player.setPlaylistMode(playlistMode),
        player.setRate(rate),
      ]);
      await player.play();
    } catch (e) {
      debugPrint('[AppPlayerController] unmuteAndPlay lỗi: $e');
    }
  }

  /// Tạm dừng và tắt tiếng nhẹ nhàng (không hạ cấp cache hay tháo track âm thanh)
  Future<void> muteAndPause() async {
    if (_isDisposed) return;
    _inSilentStandby = true;
    try {
      await Future.wait([player.pause(), setVolume(0.0)]);
      if (player.platform is NativePlayer) {
        final native = player.platform as NativePlayer;
        unawaited(native.setProperty('mute', 'yes'));
      }
    } catch (_) {}
  }

  /// Phát video qua link mạng thông thường (MP4, HLS/M3U8, Bilibili durl EDL)
  Future<void> openNetwork(
    String url, {
    Map<String, String> headers = const {},
    String? decryptionKey,
    Duration? startPosition,
    bool play = false,
  }) async {
    if (_isDisposed) return;
    _activeDashPairs = const [];
    _activeDashPairIndex = 0;
    await _applyStreamBufferProperties(isLocalFile: false);
    await _applyNetworkStreamOptions(
      urlForHint: url,
      headers: headers,
      decryptionKey: decryptionKey,
    );
    await player.open(
      Media(
        url,
        httpHeaders: headers.isEmpty ? null : headers,
        start: (startPosition != null && startPosition > Duration.zero)
            ? startPosition
            : null,
      ),
      play: play,
    );
  }

  /// Phát file video cục bộ trên máy
  Future<void> openFile(File file, {bool play = false}) async {
    if (_isDisposed) return;
    _activeDashPairs = const [];
    _activeDashPairIndex = 0;
    await _applyStreamBufferProperties(isLocalFile: true);
    await _applyNetworkStreamOptions();
    final uri = Uri.file(file.path);
    await player.open(Media(uri.toString()), play: play);
  }

  /// Phát Content URI (Android)
  Future<void> openContentUri(Uri uri, {bool play = false}) async {
    if (_isDisposed) return;
    _activeDashPairs = const [];
    _activeDashPairIndex = 0;
    await _applyStreamBufferProperties(isLocalFile: true);
    await _applyNetworkStreamOptions();
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
    videoAspectNotifier.dispose();
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
