import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/api/capcut_tts_client.dart';
import '../../data/model/device_config.dart';
import '../../data/model/voice_model.dart';

class VoicePreviewState {
  final String? activeVoiceType;
  final bool isLoading;
  final bool isPlaying;
  final String? errorMessage;

  const VoicePreviewState({
    this.activeVoiceType,
    this.isLoading = false,
    this.isPlaying = false,
    this.errorMessage,
  });
}

/// Helper quản lý tải và phát âm thanh nghe thử cho các giọng đọc CapCut
class VoicePreviewHelper {
  /// Câu nói mẫu mặc định 100% thuần Việt, không dùng từ mượn tiếng Anh
  static const String defaultPreviewText =
      'Xin chào, đây là bản nghe thử giọng đọc lồng tiếng tiếng Việt.';

  final AudioPlayer _player = AudioPlayer();
  final ValueNotifier<VoicePreviewState> stateNotifier =
      ValueNotifier<VoicePreviewState>(const VoicePreviewState());

  StreamSubscription<PlayerState>? _playerSub;
  int _requestEpoch = 0;

  VoicePreviewHelper() {
    _player.setVolume(1.0);
    _playerSub = _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        stateNotifier.value = const VoicePreviewState();
      }
    });
  }

  Future<void> togglePreview({
    required VoiceItem voice,
    required String text,
  }) async {
    final cleanText = text.trim().isEmpty ? defaultPreviewText : text.trim();
    final currentState = stateNotifier.value;

    // Nếu đang phát hoặc đang tải chính giọng này -> bấm vào là dừng ngay
    if (currentState.activeVoiceType == voice.voiceType &&
        (currentState.isPlaying || currentState.isLoading)) {
      await stop();
      return;
    }

    // Dừng âm thanh cũ (không tăng epoch để chuẩn bị cho request mới)
    await _stopPlayback();
    final epoch = ++_requestEpoch;

    stateNotifier.value = VoicePreviewState(
      activeVoiceType: voice.voiceType,
      isLoading: true,
      isPlaying: false,
    );

    try {
      final cacheDir = await getTemporaryDirectory();
      final previewDir = Directory('${cacheDir.path}/voice_previews');
      if (!await previewDir.exists()) {
        await previewDir.create(recursive: true);
      }

      // Hash văn bản + voiceType để lưu và tái sử dụng file nghe thử
      final hash = md5
          .convert(utf8.encode('${voice.voiceType}_$cleanText'))
          .toString()
          .substring(0, 12);
      final previewFile =
          File('${previewDir.path}/${voice.voiceType}_$hash.mp3');

      if (!await previewFile.exists() || await previewFile.length() < 100) {
        final client = CapCutTtsClient(device: DeviceConfig().randomize());
        await client.generateSpeechToFile(
          text: cleanText,
          voiceType: voice.voiceType,
          resourceId: voice.resourceId,
          destFile: previewFile,
          timeoutMs: 15000,
        );
      }

      if (_requestEpoch != epoch) return; // Đã bị hủy hoặc có thao tác mới

      await _player.setFilePath(previewFile.path);
      await _player.play();

      if (_requestEpoch == epoch) {
        stateNotifier.value = VoicePreviewState(
          activeVoiceType: voice.voiceType,
          isLoading: false,
          isPlaying: true,
        );
      }
    } catch (e) {
      if (_requestEpoch == epoch) {
        stateNotifier.value = VoicePreviewState(
          errorMessage: 'Lỗi tải âm thanh nghe thử: $e',
        );
      }
    }
  }

  Future<void> _stopPlayback() async {
    try {
      await _player.stop();
    } catch (_) {}
  }

  Future<void> stop() async {
    _requestEpoch++;
    await _stopPlayback();
    stateNotifier.value = const VoicePreviewState();
  }

  void dispose() {
    _playerSub?.cancel();
    _player.dispose();
    stateNotifier.dispose();
  }
}
