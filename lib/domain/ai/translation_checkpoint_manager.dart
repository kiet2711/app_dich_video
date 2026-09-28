import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/model/subtitle_document.dart';
import '../../data/model/subtitle_item.dart';

class TranslationCheckpointDraft {
  final String sessionKey;
  final String filePath;
  final String videoPath;
  final String title;
  final int durationMs;
  final String sourceLanguage;
  final String targetLanguage;
  final SubtitleDocument sourceDocument;
  final Map<int, String> translations;
  final DateTime updatedAt;
  final int totalItems;
  final int translatedCount;

  const TranslationCheckpointDraft({
    required this.sessionKey,
    required this.filePath,
    required this.videoPath,
    required this.title,
    required this.durationMs,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.sourceDocument,
    required this.translations,
    required this.updatedAt,
    required this.totalItems,
    required this.translatedCount,
  });

  double get progress => totalItems > 0 ? (translatedCount / totalItems).clamp(0.0, 1.0) : 0.0;
  int get progressPercent => (progress * 100).toInt();

  factory TranslationCheckpointDraft.fromJson(Map<String, dynamic> json, String filePath) {
    final sessionKey = json['sessionKey']?.toString() ?? '';
    final videoPath = json['videoPath']?.toString() ?? '';
    final title = json['title']?.toString() ?? (videoPath.split(RegExp(r'[/\\]')).last);
    final durationMs = int.tryParse(json['durationMs']?.toString() ?? '0') ?? 0;
    final sourceLanguage = json['sourceLanguage']?.toString() ?? 'zh-CN';
    final targetLanguage = json['targetLanguage']?.toString() ?? 'vi-VN';
    final totalItems = int.tryParse(json['totalItems']?.toString() ?? '0') ?? 0;
    final updatedMs = int.tryParse(json['updatedAt']?.toString() ?? '0') ?? 0;
    final updatedAt = updatedMs > 0 ? DateTime.fromMillisecondsSinceEpoch(updatedMs) : DateTime.now();

    final translations = <int, String>{};
    if (json['translations'] is Map) {
      final rawMap = json['translations'] as Map;
      for (final entry in rawMap.entries) {
        final id = int.tryParse(entry.key.toString());
        final text = entry.value?.toString().trim() ?? '';
        if (id != null && text.isNotEmpty) {
          translations[id] = text;
        }
      }
    }

    final items = <SubtitleItem>[];
    if (json['sourceItems'] is List) {
      for (final rawItem in json['sourceItems'] as List) {
        if (rawItem is Map) {
          final id = int.tryParse(rawItem['id']?.toString() ?? '0') ?? 0;
          final startMs = int.tryParse(rawItem['startMs']?.toString() ?? '0') ?? 0;
          final endMs = int.tryParse(rawItem['endMs']?.toString() ?? '0') ?? 0;
          final orig = rawItem['originalText']?.toString() ?? '';
          final trans = translations[id] ?? rawItem['translatedText']?.toString() ?? '';
          items.add(
            SubtitleItem(
              id: id,
              startMs: startMs,
              endMs: endMs,
              originalText: orig,
              translatedText: trans,
            ),
          );
        }
      }
    }

    return TranslationCheckpointDraft(
      sessionKey: sessionKey,
      filePath: filePath,
      videoPath: videoPath,
      title: title,
      durationMs: durationMs,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
      sourceDocument: SubtitleDocument(items),
      translations: translations,
      updatedAt: updatedAt,
      totalItems: totalItems > 0 ? totalItems : items.length,
      translatedCount: translations.length,
    );
  }
}

class TranslationCheckpointManager {
  static const String _folderName = 'translation_checkpoints';

  /// Lấy thư mục lưu trữ checkpoint cục bộ
  static Future<Directory> getCheckpointDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_folderName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Sinh mã sessionKey duy nhất và ổn định cho bộ phụ đề
  static String generateSessionKey({
    required SubtitleDocument document,
    required String targetLanguage,
    String? identifier,
  }) {
    if (identifier != null && identifier.trim().isNotEmpty) {
      final seed = '${identifier.trim()}_$targetLanguage';
      return md5.convert(utf8.encode(seed)).toString();
    }

    if (document.isEmpty) return 'empty_doc';

    final first = document.items.first;
    final last = document.items.last;
    final seed = '${document.items.length}_${first.startMs}_${first.originalText}_${last.endMs}_${last.originalText}_$targetLanguage';
    return md5.convert(utf8.encode(seed)).toString();
  }

  /// Tải checkpoint bản dịch đã lưu theo sessionKey (`Map<id, translation>`)
  static Future<Map<int, String>> loadCheckpoint(String sessionKey) async {
    if (sessionKey.trim().isEmpty) return const {};

    try {
      final dir = await getCheckpointDirectory();
      final file = File('${dir.path}/$sessionKey.json');
      if (!await file.exists()) return const {};

      final content = await file.readAsString();
      if (content.trim().isEmpty) return const {};

      final data = jsonDecode(content);
      final translations = <int, String>{};

      if (data is Map && data['translations'] is Map) {
        final rawMap = data['translations'] as Map;
        for (final entry in rawMap.entries) {
          final id = int.tryParse(entry.key.toString());
          final text = entry.value?.toString().trim() ?? '';
          if (id != null && text.isNotEmpty) {
            translations[id] = text;
          }
        }
      }

      return translations;
    } catch (_) {
      return const {};
    }
  }

  /// Tải thông tin chi tiết đầy đủ của Draft để phục hồi cả STT cues và videoPath
  static Future<TranslationCheckpointDraft?> loadDraft(String sessionKey) async {
    if (sessionKey.trim().isEmpty) return null;

    try {
      final dir = await getCheckpointDirectory();
      final file = File('${dir.path}/$sessionKey.json');
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      if (content.trim().isEmpty) return null;

      final data = jsonDecode(content);
      if (data is Map) {
        return TranslationCheckpointDraft.fromJson(Map<String, dynamic>.from(data), file.path);
      }
    } catch (_) {}
    return null;
  }

  /// Lưu trạng thái ban đầu của Draft ngay sau khi CapCut STT nhận diện xong lời thoại
  static Future<void> saveInitialDraft({
    required String sessionKey,
    required String videoPath,
    required String title,
    required int durationMs,
    required String sourceLanguage,
    required String targetLanguage,
    required SubtitleDocument sourceDocument,
  }) async {
    if (sessionKey.trim().isEmpty || sourceDocument.isEmpty) return;

    try {
      final dir = await getCheckpointDirectory();
      final targetFile = File('${dir.path}/$sessionKey.json');
      final tempFile = File('${dir.path}/$sessionKey.json.tmp');

      final sourceItemsList = sourceDocument.items.map((it) => {
        'id': it.id,
        'startMs': it.startMs,
        'endMs': it.endMs,
        'originalText': it.originalText,
        'translatedText': it.translatedText,
      }).toList();

      final payload = {
        'sessionKey': sessionKey,
        'videoPath': videoPath,
        'title': title,
        'durationMs': durationMs,
        'sourceLanguage': sourceLanguage,
        'targetLanguage': targetLanguage,
        'totalItems': sourceDocument.items.length,
        'translatedCount': 0,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'sourceItems': sourceItemsList,
        'translations': <String, String>{},
      };

      await tempFile.writeAsString(jsonEncode(payload), flush: true);
      if (await targetFile.exists()) {
        await targetFile.delete();
      }
      await tempFile.rename(targetFile.path);
    } catch (_) {}
  }

  /// Lưu trạng thái checkpoint sau mỗi batch thành công (bảo lưu metadata và ghi an toàn qua file tạm)
  static Future<void> saveCheckpoint({
    required String sessionKey,
    required String targetLanguage,
    required int totalItems,
    required Map<int, String> translations,
  }) async {
    if (sessionKey.trim().isEmpty || translations.isEmpty) return;

    try {
      final dir = await getCheckpointDirectory();
      final targetFile = File('${dir.path}/$sessionKey.json');
      final tempFile = File('${dir.path}/$sessionKey.json.tmp');

      Map<String, dynamic> existingPayload = {};
      if (await targetFile.exists()) {
        try {
          final oldContent = await targetFile.readAsString();
          final parsed = jsonDecode(oldContent);
          if (parsed is Map) {
            existingPayload = Map<String, dynamic>.from(parsed);
          }
        } catch (_) {}
      }

      final stringKeyMap = <String, String>{};
      for (final entry in translations.entries) {
        if (entry.value.trim().isNotEmpty) {
          stringKeyMap[entry.key.toString()] = entry.value.trim();
        }
      }

      existingPayload['sessionKey'] = sessionKey;
      existingPayload['targetLanguage'] = targetLanguage;
      existingPayload['totalItems'] = totalItems;
      existingPayload['translatedCount'] = stringKeyMap.length;
      existingPayload['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
      existingPayload['translations'] = stringKeyMap;

      await tempFile.writeAsString(jsonEncode(existingPayload), flush: true);
      if (await targetFile.exists()) {
        await targetFile.delete();
      }
      await tempFile.rename(targetFile.path);
    } catch (_) {}
  }

  /// Xóa checkpoint khi dịch xong hoàn chỉnh 100%
  static Future<void> clearCheckpoint(String sessionKey) async {
    if (sessionKey.trim().isEmpty) return;

    try {
      final dir = await getCheckpointDirectory();
      final targetFile = File('${dir.path}/$sessionKey.json');
      if (await targetFile.exists()) {
        await targetFile.delete();
      }
      final tempFile = File('${dir.path}/$sessionKey.json.tmp');
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    } catch (_) {}
  }

  /// Tìm phiên dịch dang dở gần đây nhất chưa hoàn thành (để hiển thị trên Home Screen)
  static Future<TranslationCheckpointDraft?> getLatestDraft() async {
    try {
      final dir = await getCheckpointDirectory();
      if (!await dir.exists()) return null;

      final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
      if (files.isEmpty) return null;

      files.sort((a, b) {
        try {
          return b.statSync().modified.compareTo(a.statSync().modified);
        } catch (_) {
          return 0;
        }
      });

      for (final f in files) {
        try {
          final content = f.readAsStringSync();
          final data = jsonDecode(content);
          if (data is Map) {
            final draft = TranslationCheckpointDraft.fromJson(Map<String, dynamic>.from(data), f.path);
            if (draft.totalItems > 0 && draft.translatedCount < draft.totalItems) {
              return draft;
            }
          }
        } catch (_) {}
      }
    } catch (_) {}
    return null;
  }

  /// Quét tất cả các file checkpoint hiện có
  static Future<List<TranslationCheckpointDraft>> getAllCheckpoints() async {
    final results = <TranslationCheckpointDraft>[];
    try {
      final dir = await getCheckpointDirectory();
      if (!await dir.exists()) return results;

      final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json'));
      for (final f in files) {
        try {
          final content = f.readAsStringSync();
          final data = jsonDecode(content);
          if (data is Map) {
            results.add(TranslationCheckpointDraft.fromJson(Map<String, dynamic>.from(data), f.path));
          }
        } catch (_) {}
      }
    } catch (_) {}
    return results;
  }

  /// Tự động dọn dẹp các checkpoint quá hạn (mặc định > 7 ngày)
  static Future<void> pruneOldCheckpoints({Duration maxAge = const Duration(days: 7)}) async {
    try {
      final dir = await getCheckpointDirectory();
      if (!await dir.exists()) return;

      final now = DateTime.now();
      final files = dir.listSync().whereType<File>();
      for (final f in files) {
        final stat = f.statSync();
        if (now.difference(stat.modified) > maxAge) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}
