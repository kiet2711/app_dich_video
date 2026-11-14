import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../../media/audio_extractor.dart' show AudioExtractor;

/// Mô tả nguồn âm thanh dùng để trích xuất luồng PCM 16kHz cho Live Translate.
class LiveAudioSource {
  final String mediaPath;
  final Map<String, String> headers;
  final String sourceLabel;

  const LiveAudioSource({
    required this.mediaPath,
    this.headers = const {},
    this.sourceLabel = '',
  });

  bool get isValid => mediaPath.trim().isNotEmpty;

  bool isSameSource(LiveAudioSource? other) {
    if (other == null) return false;
    return mediaPath.trim() == other.mediaPath.trim();
  }
}

/// Một đoạn PCM 16kHz mono 16-bit LE gắn mốc thời gian trong video.
class LivePcmChunk {
  final Uint8List pcmBytes;
  final int startMs;
  final int endMs;
  final bool eof;

  const LivePcmChunk({
    required this.pcmBytes,
    required this.startMs,
    required this.endMs,
    required this.eof,
  });
}

/// Giao diện trừu tượng giúp đọc PCM theo mốc thời gian (dễ test bằng fake reader).
abstract class LivePcmAudioReader {
  Future<int> open(LiveAudioSource source, {int startMs = 0});
  Future<LivePcmChunk> readChunk({int durationMs = 250});
  Future<int> seekTo(int positionMs);
  Future<void> close();
}

/// Triển khai mặc định qua MethodChannel native Android (`MediaExtractor` + `MediaCodec`) & iOS (`AVAssetReader` / `AVAssetExportSession`).
class MethodChannelLivePcmAudioReader implements LivePcmAudioReader {
  String? _streamId;

  @override
  Future<int> open(LiveAudioSource source, {int startMs = 0}) async {
    await close();
    try {
      final res = await AudioExtractor.openPcmStream(
        mediaPath: source.mediaPath,
        headers: source.headers,
        startMs: startMs,
      );
      _streamId = res.streamId;
      return res.durationMs;
    } on MissingPluginException {
      throw UnsupportedError(
        'Trích xuất âm thanh trực tiếp hiện hỗ trợ trên Android và iOS.',
      );
    } on PlatformException catch (e) {
      throw StateError(e.message ?? 'Không mở được luồng âm thanh ($e).');
    }
  }

  @override
  Future<LivePcmChunk> readChunk({int durationMs = 250}) async {
    final id = _streamId;
    if (id == null || id.isEmpty) {
      return LivePcmChunk(
        pcmBytes: Uint8List(0),
        startMs: 0,
        endMs: 0,
        eof: true,
      );
    }
    try {
      final res = await AudioExtractor.readPcmChunk(
        streamId: id,
        durationMs: durationMs,
      );
      return LivePcmChunk(
        pcmBytes: res.pcmBytes,
        startMs: res.startMs,
        endMs: res.endMs,
        eof: res.eof,
      );
    } on PlatformException catch (e) {
      throw StateError(e.message ?? 'Lỗi đọc luồng âm thanh PCM ($e).');
    }
  }

  @override
  Future<int> seekTo(int positionMs) async {
    final id = _streamId;
    if (id == null || id.isEmpty) return positionMs;
    return AudioExtractor.seekPcmStream(
      streamId: id,
      positionMs: positionMs,
    );
  }

  @override
  Future<void> close() async {
    final id = _streamId;
    _streamId = null;
    if (id == null || id.isEmpty) return;
    try {
      await AudioExtractor.closePcmStream(id);
    } catch (_) {}
  }
}

/// Tính biên độ RMS cho luồng PCM 16-bit signed little-endian (0..32768).
double computePcm16Rms(Uint8List pcmBytes) {
  final sampleCount = pcmBytes.length ~/ 2;
  if (sampleCount <= 0) return 0;
  final bd = ByteData.sublistView(pcmBytes);
  var sumSquares = 0.0;
  for (var i = 0; i < sampleCount; i++) {
    final sample = bd.getInt16(i * 2, Endian.little).toDouble();
    sumSquares += sample * sample;
  }
  return math.sqrt(sumSquares / sampleCount);
}

class VadGateDecision {
  final List<Uint8List> framesToSend;
  final bool shouldSendStreamEnd;
  final bool skippedSilence;
  final double rms;

  const VadGateDecision({
    required this.framesToSend,
    required this.shouldSendStreamEnd,
    required this.skippedSilence,
    required this.rms,
  });
}

/// Bộ lọc khoảng lặng (Local VAD) giúp tránh đốt ~25 token/giây cho đoạn im lặng trên giới hạn 20k TPM.
class PcmSilenceGate {
  final double speechRmsThreshold;
  final int preRollFrameCount;
  final int hangoverMs;
  bool enabled;

  final Queue<Uint8List> _preRoll = Queue<Uint8List>();
  bool _isInSpeech = false;
  int _silenceRunMs = 0;
  bool _pendingStreamEndFlush = false;

  PcmSilenceGate({
    this.speechRmsThreshold = 135.0,
    this.preRollFrameCount = 1,
    this.hangoverMs = 900,
    this.enabled = true,
  });

  void reset() {
    _preRoll.clear();
    _isInSpeech = false;
    _silenceRunMs = 0;
    _pendingStreamEndFlush = false;
  }

  VadGateDecision evaluate(Uint8List pcmBytes, int chunkDurationMs) {
    if (pcmBytes.isEmpty) {
      return const VadGateDecision(
        framesToSend: [],
        shouldSendStreamEnd: false,
        skippedSilence: false,
        rms: 0,
      );
    }

    final rms = computePcm16Rms(pcmBytes);
    if (!enabled) {
      _isInSpeech = true;
      _silenceRunMs = 0;
      _pendingStreamEndFlush = true;
      return VadGateDecision(
        framesToSend: [pcmBytes],
        shouldSendStreamEnd: false,
        skippedSilence: false,
        rms: rms,
      );
    }

    final safeDur = chunkDurationMs.clamp(20, 2000);
    if (rms >= speechRmsThreshold) {
      final out = <Uint8List>[];
      while (_preRoll.isNotEmpty) {
        out.add(_preRoll.removeFirst());
      }
      out.add(pcmBytes);
      _isInSpeech = true;
      _silenceRunMs = 0;
      _pendingStreamEndFlush = true;
      return VadGateDecision(
        framesToSend: out,
        shouldSendStreamEnd: false,
        skippedSilence: false,
        rms: rms,
      );
    }

    if (_isInSpeech) {
      _silenceRunMs += safeDur;
      if (_silenceRunMs <= hangoverMs) {
        return VadGateDecision(
          framesToSend: [pcmBytes],
          shouldSendStreamEnd: false,
          skippedSilence: false,
          rms: rms,
        );
      }
      // Đã hết đuôi câu -> ngắt truyền im lặng và gửi audioStreamEnd để Gemini trả bản dịch ngay.
      _isInSpeech = false;
      final shouldFlush = _pendingStreamEndFlush;
      _pendingStreamEndFlush = false;
      _pushPreRoll(pcmBytes);
      return VadGateDecision(
        framesToSend: const [],
        shouldSendStreamEnd: shouldFlush,
        skippedSilence: true,
        rms: rms,
      );
    }

    _pushPreRoll(pcmBytes);
    return VadGateDecision(
      framesToSend: const [],
      shouldSendStreamEnd: false,
      skippedSilence: true,
      rms: rms,
    );
  }

  void _pushPreRoll(Uint8List pcmBytes) {
    if (preRollFrameCount <= 0) return;
    _preRoll.addLast(pcmBytes);
    while (_preRoll.length > preRollFrameCount) {
      _preRoll.removeFirst();
    }
  }
}
