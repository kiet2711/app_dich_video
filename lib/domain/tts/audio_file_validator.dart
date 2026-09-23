import 'dart:io';
import 'dart:typed_data';

class AudioValidationResult {
  final bool isValid;
  final int durationMs;
  final String reason;

  const AudioValidationResult({
    required this.isValid,
    this.durationMs = 0,
    this.reason = '',
  });
}

/// Tiện ích kiểm định file âm thanh TTS siêu nhẹ và bộ nhớ đệm (Cache) kết quả.
/// Tránh việc tạo hàng chục instance AudioPlayer native song song gây tràn RAM và cạn kiệt luồng native.
class AudioFileValidator {
  static const int minAudioBytes = 128;

  // Bộ nhớ đệm kết quả kiểm định để tránh đọc file/giải mã liên tục
  static final Map<String, AudioValidationResult> _cache = {};

  static Future<AudioValidationResult> validate(File file) async {
    if (!await file.exists()) {
      return const AudioValidationResult(
        isValid: false,
        reason: 'Chưa nhận được file âm thanh',
      );
    }

    final length = await file.length();
    if (length < minAudioBytes) {
      return const AudioValidationResult(
        isValid: false,
        reason: 'File âm thanh rỗng hoặc tải chưa đủ',
      );
    }

    final stat = await file.stat();
    final cacheKey =
        '${file.path}:$length:${stat.modified.millisecondsSinceEpoch}';
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey]!;
    }

    final duration = _parseMp3DurationFast(file, length);
    if (duration != null && duration > 0) {
      final res = AudioValidationResult(isValid: true, durationMs: duration);
      _cache[cacheKey] = res;
      return res;
    }

    // Nếu không đọc được header (rất hiếm đối với CapCut MP3), ước tính tương đối nếu file đủ lớn
    if (length >= 1024) {
      final approxMs = ((length * 8) / (128 * 1000) * 1000).round();
      final res = AudioValidationResult(isValid: true, durationMs: approxMs);
      _cache[cacheKey] = res;
      return res;
    }

    return const AudioValidationResult(
      isValid: false,
      reason: 'File âm thanh không hợp lệ hoặc duration bằng 0',
    );
  }

  static void invalidate(File file) {
    _cache.removeWhere((key, _) => key.startsWith(file.path));
  }

  static void clearCache() {
    _cache.clear();
  }

  /// Parser siêu nhẹ đọc frame header MP3 trong vài micro-giây, không tốn RAM, không dùng native player
  static int? _parseMp3DurationFast(File file, int totalLength) {
    try {
      final raf = file.openSync(mode: FileMode.read);
      try {
        final readSize = totalLength < 8192 ? totalLength : 8192;
        final header = Uint8List(readSize);
        raf.readIntoSync(header);

        int offset = 0;
        // Bỏ qua ID3v2 header nếu có ("ID3")
        if (header.length >= 10 &&
            header[0] == 0x49 &&
            header[1] == 0x44 &&
            header[2] == 0x33) {
          final size = ((header[6] & 0x7F) << 21) |
              ((header[7] & 0x7F) << 14) |
              ((header[8] & 0x7F) << 7) |
              (header[9] & 0x7F);
          offset = 10 + size;
        }

        Uint8List audioData;
        if (offset + 100 > header.length) {
          if (offset >= totalLength) return null;
          raf.setPositionSync(offset);
          final remaining = totalLength - offset;
          final chunk = remaining < 4096 ? remaining : 4096;
          audioData = Uint8List(chunk);
          raf.readIntoSync(audioData);
          offset = 0;
        } else {
          audioData = header;
        }

        for (int i = offset; i < audioData.length - 4; i++) {
          if (audioData[i] == 0xFF && (audioData[i + 1] & 0xE0) == 0xE0) {
            final b1 = audioData[i + 1];
            final b2 = audioData[i + 2];
            final b3 = audioData[i + 3];

            final versionBits = (b1 >> 3) & 0x03;
            final layerBits = (b1 >> 1) & 0x03;
            if (layerBits != 1) continue; // Layer III

            final bitrateIdx = (b2 >> 4) & 0x0F;
            final sampleRateIdx = (b2 >> 2) & 0x03;
            final channelMode = (b3 >> 6) & 0x03;

            int bitrate = 0;
            if (versionBits == 3) {
              const bitrates = [
                0,
                32,
                40,
                48,
                56,
                64,
                80,
                96,
                112,
                128,
                160,
                192,
                224,
                256,
                320,
                0,
              ];
              bitrate = bitrates[bitrateIdx];
            } else {
              const bitrates = [
                0,
                8,
                16,
                24,
                32,
                40,
                48,
                56,
                64,
                80,
                96,
                112,
                128,
                144,
                160,
                0,
              ];
              bitrate = bitrates[bitrateIdx];
            }

            int sampleRate = 0;
            if (versionBits == 3) {
              const rates = [44100, 48000, 32000, 0];
              sampleRate = rates[sampleRateIdx];
            } else if (versionBits == 2) {
              const rates = [22050, 24000, 16000, 0];
              sampleRate = rates[sampleRateIdx];
            } else if (versionBits == 0) {
              const rates = [11025, 12000, 8000, 0];
              sampleRate = rates[sampleRateIdx];
            }

            if (bitrate <= 0 || sampleRate <= 0) continue;

            // Kiểm tra Xing / Info header nếu là VBR
            final xingOffset = i +
                4 +
                (versionBits == 3
                    ? (channelMode == 3 ? 17 : 32)
                    : (channelMode == 3 ? 9 : 17));
            if (xingOffset + 12 < audioData.length) {
              final isXing = audioData[xingOffset] == 0x58 &&
                  audioData[xingOffset + 1] == 0x69 &&
                  audioData[xingOffset + 2] == 0x6E &&
                  audioData[xingOffset + 3] == 0x67;
              final isInfo = audioData[xingOffset] == 0x49 &&
                  audioData[xingOffset + 1] == 0x6E &&
                  audioData[xingOffset + 2] == 0x66 &&
                  audioData[xingOffset + 3] == 0x6F;
              if (isXing || isInfo) {
                final flags = (audioData[xingOffset + 4] << 24) |
                    (audioData[xingOffset + 5] << 16) |
                    (audioData[xingOffset + 6] << 8) |
                    audioData[xingOffset + 7];
                if ((flags & 0x01) != 0) {
                  final frames = (audioData[xingOffset + 8] << 24) |
                      (audioData[xingOffset + 9] << 16) |
                      (audioData[xingOffset + 10] << 8) |
                      audioData[xingOffset + 11];
                  final samplesPerFrame = versionBits == 3 ? 1152 : 576;
                  final durMs = (frames * samplesPerFrame * 1000 / sampleRate)
                      .round();
                  if (durMs > 0) return durMs;
                }
              }
            }

            // CBR duration
            final audioBytes = totalLength - offset;
            final durMs = ((audioBytes * 8) / (bitrate * 1000) * 1000).round();
            if (durMs > 0) return durMs;
          }
        }
      } finally {
        raf.closeSync();
      }
    } catch (_) {}
    return null;
  }
}
