import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/model/subtitle_document.dart';
import '../../data/model/subtitle_item.dart';
import 'audio_file_validator.dart';

class TtsCacheHelper {
  /// Tạo khóa định danh duy nhất cho tài liệu phụ đề (chuẩn như app gốc Android)
  static String getDocKey(SubtitleDocument doc) {
    if (doc.items.isEmpty) return 'empty';
    final first = doc.items.first;
    final last = doc.items.last;
    final firstText = first.getDisplayText('translated').trim().isNotEmpty
        ? first.getDisplayText('translated').trim()
        : first.originalText.trim();
    final lastText = last.getDisplayText('translated').trim().isNotEmpty
        ? last.getDisplayText('translated').trim()
        : last.originalText.trim();
    final prefix =
        firstText.length > 20 ? firstText.substring(0, 20) : firstText;
    final suffix = lastText.length > 20 ? lastText.substring(0, 20) : lastText;
    final signature =
        '${doc.items.length}_${first.startMs}_${prefix}_${last.endMs}_$suffix';
    return md5.convert(utf8.encode(signature)).toString();
  }

  /// Thư mục cache TTS riêng biệt của tài liệu: tts_cache/<docKey>/<voiceType>
  static Future<Directory> getCacheDir(
    SubtitleDocument doc, [
    String? voiceType,
  ]) async {
    final key = getDocKey(doc);
    final docs = await getApplicationDocumentsDirectory();
    final path = (voiceType != null && voiceType.isNotEmpty)
        ? '${docs.path}/tts_cache/$key/$voiceType'
        : '${docs.path}/tts_cache/$key';
    final dir = Directory(path);
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// File âm thanh cho từng câu: sub_<itemId>.mp3
  static Future<File> getAudioFile(
    SubtitleDocument doc,
    SubtitleItem item,
    String voiceType,
  ) async {
    final dir = await getCacheDir(doc, voiceType);
    return File('${dir.path}/sub_${item.id}.mp3');
  }

  /// Quét và liên kết các file audio có sẵn của tài liệu (hỗ trợ cả đường dẫn legacy)
  static Future<int> linkAudioFiles(
    SubtitleDocument doc,
    String voiceType,
  ) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = await getCacheDir(doc, voiceType);
    var linked = 0;

    for (final item in doc.items) {
      final file = File('${dir.path}/sub_${item.id}.mp3');
      if (await file.exists()) {
        final val = await AudioFileValidator.validate(file);
        if (val.isValid && val.durationMs > 0) {
          item.audioFilePath = file.path;
          item.audioDurationMs = val.durationMs;
          linked++;
          continue;
        }
      }

      // Tương thích ngược: kiểm tra trong thư mục legacy cũ tts_cache_<voiceType>
      final legacyDir = Directory('${docs.path}/tts_cache_$voiceType');
      if (await legacyDir.exists()) {
        final text = item.translatedText.trim().isNotEmpty
            ? item.translatedText.trim()
            : item.originalText.trim();
        final hash = md5.convert(utf8.encode(text)).toString();
        final legacyFile = File('${legacyDir.path}/sub_${item.id}_$hash.mp3');
        if (await legacyFile.exists()) {
          final val = await AudioFileValidator.validate(legacyFile);
          if (val.isValid && val.durationMs > 0) {
            try {
              await legacyFile.copy(file.path);
              item.audioFilePath = file.path;
            } catch (_) {
              item.audioFilePath = legacyFile.path;
            }
            item.audioDurationMs = val.durationMs;
            linked++;
            continue;
          }
        }
      }
    }
    return linked;
  }

  /// Xóa sạch thư mục cache âm thanh của riêng tài liệu này
  static Future<void> deleteDocCache(
    SubtitleDocument doc, [
    String? explicitDocKey,
  ]) async {
    final docs = await getApplicationDocumentsDirectory();
    final keys = <String>{};
    final key = getDocKey(doc);
    if (key.isNotEmpty && key != 'empty') keys.add(key);
    if (explicitDocKey != null &&
        explicitDocKey.isNotEmpty &&
        explicitDocKey != 'empty') {
      keys.add(explicitDocKey);
    }
    for (final k in keys) {
      final dir = Directory('${docs.path}/tts_cache/$k');
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  }
}
