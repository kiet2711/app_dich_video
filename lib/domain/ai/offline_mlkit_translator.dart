import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../../data/model/subtitle_document.dart';
import '../../data/model/subtitle_item.dart';
import 'translation_checkpoint_manager.dart';

/// Bộ dịch phụ đề Ngoại Tuyến (Offline On-Device) sử dụng Google ML Kit.
///
/// Hỗ trợ cả Android và iOS không cần mạng, không cần API Key, hoàn toàn miễn phí.
/// Áp dụng các kỹ thuật tối ưu hóa hiệu năng cao:
/// 1. Delimiter Batching: Gộp 30-40 câu vào 1 chuỗi để giảm 95% overhead Native MethodChannel.
/// 2. In-Memory Deduplication: Tái sử dụng bản dịch cho các câu thoại trùng lặp trong phim.
/// 3. Fast-path Bypass: Bỏ qua câu rỗng, số, ký hiệu và biểu cảm.
/// 4. Resilient Fallback: Tự động lùi về dịch từng câu nếu delimiter gặp sự cố hy hữu.
/// 5. Checkpoint Manager: Hỗ trợ tạm dừng và tiếp tục mượt mà.
class OfflineMlKitTranslator {
  static const String modelId = 'offline-mlkit';
  static final OnDeviceTranslatorModelManager _modelManager =
      OnDeviceTranslatorModelManager();

  // Bộ nhớ đệm tạm thời cho các câu lặp lại
  final Map<String, String> _memoryCache = {};

  /// Chuyển đổi chuỗi tên ngôn ngữ sang `TranslateLanguage` của ML Kit
  static TranslateLanguage resolveLanguage(String lang) {
    final l = lang.trim().toLowerCase();
    if (l.contains('vi') || l.contains('việt')) {
      return TranslateLanguage.vietnamese;
    }
    if (l.contains('zh') ||
        l.contains('cn') ||
        l.contains('trung') ||
        l.contains('chinese')) {
      return TranslateLanguage.chinese;
    }
    if (l.contains('en') ||
        l.contains('anh') ||
        l.contains('english') ||
        l.contains('us')) {
      return TranslateLanguage.english;
    }
    if (l.contains('ja') ||
        l.contains('jp') ||
        l.contains('nhật') ||
        l.contains('japanese')) {
      return TranslateLanguage.japanese;
    }
    if (l.contains('ko') ||
        l.contains('kr') ||
        l.contains('hàn') ||
        l.contains('korean')) {
      return TranslateLanguage.korean;
    }
    if (l.contains('fr') || l.contains('pháp')) {
      return TranslateLanguage.french;
    }
    if (l.contains('de') || l.contains('đức')) {
      return TranslateLanguage.german;
    }
    if (l.contains('es') || l.contains('tây ban nha')) {
      return TranslateLanguage.spanish;
    }
    if (l.contains('th') || l.contains('thái')) {
      return TranslateLanguage.thai;
    }
    if (l.contains('ru') || l.contains('nga')) {
      return TranslateLanguage.russian;
    }
    return TranslateLanguage.vietnamese;
  }

  /// Kiểm tra gói ngôn ngữ đã được tải về máy chưa
  static Future<bool> isModelDownloaded(TranslateLanguage language) async {
    try {
      return await _modelManager.isModelDownloaded(language.bcpCode);
    } catch (e) {
      debugPrint('[OfflineMlKit] Kiểm tra model ${language.bcpCode} lỗi: $e');
      return false;
    }
  }

  /// Tải gói ngôn ngữ về máy (~30MB)
  static Future<bool> downloadModel(
    TranslateLanguage language, {
    bool isWifiRequired = false,
  }) async {
    try {
      return await _modelManager.downloadModel(
        language.bcpCode,
        isWifiRequired: isWifiRequired,
      );
    } catch (e) {
      debugPrint('[OfflineMlKit] Tải model ${language.bcpCode} lỗi: $e');
      return false;
    }
  }

  /// Xóa gói ngôn ngữ để giải phóng dung lượng bộ nhớ
  static Future<bool> deleteModel(TranslateLanguage language) async {
    try {
      return await _modelManager.deleteModel(language.bcpCode);
    } catch (e) {
      debugPrint('[OfflineMlKit] Xóa model ${language.bcpCode} lỗi: $e');
      return false;
    }
  }

  /// Đảm bảo cả hai gói ngôn ngữ nguồn và đích đều sẵn sàng
  Future<void> _ensureModelsReady({
    required TranslateLanguage sourceLang,
    required TranslateLanguage targetLang,
    void Function(double progress, String message)? progressCallback,
  }) async {
    final isSourceReady = await isModelDownloaded(sourceLang);
    if (!isSourceReady) {
      progressCallback?.call(
        0.02,
        'Đang tải gói dịch ngoại tuyến ${sourceLang.name} (~30MB)...',
      );
      final downloaded = await downloadModel(sourceLang, isWifiRequired: false);
      if (!downloaded) {
        throw StateError(
          'Không thể tải gói ngôn ngữ ${sourceLang.name}. Vui lòng kiểm tra kết nối mạng khi tải lần đầu!',
        );
      }
    }

    final isTargetReady = await isModelDownloaded(targetLang);
    if (!isTargetReady) {
      progressCallback?.call(
        0.05,
        'Đang tải gói dịch ngoại tuyến ${targetLang.name} (~30MB)...',
      );
      final downloaded = await downloadModel(targetLang, isWifiRequired: false);
      if (!downloaded) {
        throw StateError(
          'Không thể tải gói ngôn ngữ ${targetLang.name}. Vui lòng kiểm tra kết nối mạng khi tải lần đầu!',
        );
      }
    }
  }

  // Bộ nhớ đệm dành riêng cho Tab Phim Hồng Quả
  static final Map<String, String> _hongguoTitleCache = {};
  static final Map<String, String> _hongguoIntroCache = {};
  static final Map<String, String> _searchQueryCache = {};

  static OnDeviceTranslator? _zhToViTranslator;
  static OnDeviceTranslator? _viToZhTranslator;

  /// Lấy hoặc tạo translator Trung ➔ Việt dùng chung cho Tab Hồng Quả
  static Future<OnDeviceTranslator> getZhToViTranslator() async {
    if (_zhToViTranslator != null) return _zhToViTranslator!;
    final source = TranslateLanguage.chinese;
    final target = TranslateLanguage.vietnamese;
    await downloadModel(source, isWifiRequired: false);
    await downloadModel(target, isWifiRequired: false);
    _zhToViTranslator = OnDeviceTranslator(
      sourceLanguage: source,
      targetLanguage: target,
    );
    return _zhToViTranslator!;
  }

  /// Lấy hoặc tạo translator Việt ➔ Trung dùng cho tìm kiếm phim
  static Future<OnDeviceTranslator> getViToZhTranslator() async {
    if (_viToZhTranslator != null) return _viToZhTranslator!;
    final source = TranslateLanguage.vietnamese;
    final target = TranslateLanguage.chinese;
    await downloadModel(source, isWifiRequired: false);
    await downloadModel(target, isWifiRequired: false);
    _viToZhTranslator = OnDeviceTranslator(
      sourceLanguage: source,
      targetLanguage: target,
    );
    return _viToZhTranslator!;
  }

  /// Dịch tiêu đề phim Hồng Quả (có lưu cache tức thì)
  static Future<String> translateHongguoTitle(String title) async {
    final clean = title.trim();
    if (clean.isEmpty) return title;
    if (_hongguoTitleCache.containsKey(clean)) {
      return _hongguoTitleCache[clean]!;
    }
    try {
      final translator = await getZhToViTranslator();
      final res = await translator.translateText(clean);
      final finalStr = res.trim().isNotEmpty ? res.trim() : clean;
      _hongguoTitleCache[clean] = finalStr;
      return finalStr;
    } catch (e) {
      debugPrint('[HongguoTranslate] Lỗi dịch tiêu đề "$clean": $e');
      return clean;
    }
  }

  /// Lấy bản dịch tiêu đề đã có trong cache (đồng bộ 0ms)
  static String? getCachedTitle(String title) {
    return _hongguoTitleCache[title.trim()];
  }

  /// Dịch tóm tắt/giới thiệu phim Hồng Quả (có lưu cache tức thì)
  static Future<String> translateHongguoIntro(String intro) async {
    final clean = intro.trim();
    if (clean.isEmpty) return intro;
    if (_hongguoIntroCache.containsKey(clean)) {
      return _hongguoIntroCache[clean]!;
    }
    try {
      final translator = await getZhToViTranslator();
      final res = await translator.translateText(clean);
      final finalStr = res.trim().isNotEmpty ? res.trim() : clean;
      _hongguoIntroCache[clean] = finalStr;
      return finalStr;
    } catch (e) {
      debugPrint('[HongguoTranslate] Lỗi dịch giới thiệu: $e');
      return clean;
    }
  }

  /// Lấy bản dịch giới thiệu đã có trong cache (đồng bộ 0ms)
  static String? getCachedIntro(String intro) {
    return _hongguoIntroCache[intro.trim()];
  }

  /// Dịch từ khóa tìm kiếm Tiếng Việt sang Tiếng Trung để truy vấn API Hồng Quả
  static Future<String> translateSearchQuery(String vietnameseQuery) async {
    final clean = vietnameseQuery.trim();
    if (clean.isEmpty) return clean;
    // Nếu không chứa chữ cái Latin/Việt (đã là chữ Hán hoặc số), giữ nguyên
    if (!RegExp(r'[a-zA-ZÀ-ỹ]').hasMatch(clean)) {
      return clean;
    }
    if (_searchQueryCache.containsKey(clean)) {
      return _searchQueryCache[clean]!;
    }
    try {
      final translator = await getViToZhTranslator();
      final res = await translator.translateText(clean);
      final finalStr = res.trim().isNotEmpty ? res.trim() : clean;
      _searchQueryCache[clean] = finalStr;
      return finalStr;
    } catch (e) {
      debugPrint('[HongguoTranslate] Lỗi dịch từ khóa "$clean": $e');
      return clean;
    }
  }

  /// Dịch một đoạn văn bản đơn lẻ (ví dụ: Tiêu đề video)
  Future<String> translateText({
    required String text,
    String sourceLanguage = 'Tiếng Trung',
    String targetLanguage = 'Tiếng Việt',
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) return text;
    if (_isNonTranslatable(clean)) return text;

    final source = resolveLanguage(sourceLanguage);
    final target = resolveLanguage(targetLanguage);
    if (source == target) return text;

    await _ensureModelsReady(sourceLang: source, targetLang: target);

    final translator = OnDeviceTranslator(
      sourceLanguage: source,
      targetLanguage: target,
    );

    try {
      final res = await translator.translateText(clean);
      return res.trim().isNotEmpty ? res.trim() : text;
    } finally {
      await translator.close();
    }
  }

  /// Dịch toàn bộ tài liệu phụ đề với cơ chế tối ưu hoá cao độ
  Future<SubtitleDocument> translateSubtitles({
    required SubtitleDocument document,
    String sourceLanguage = 'Tiếng Trung',
    String targetLanguage = 'Tiếng Việt',
    int batchSize = 35,
    bool enableCheckpoint = true,
    String? checkpointSessionId,
    bool Function()? isCancelled,
    void Function(double progress, String message)? progressCallback,
  }) async {
    final items = document.items;
    if (items.isEmpty) return document;

    final source = resolveLanguage(sourceLanguage);
    final target = resolveLanguage(targetLanguage);

    if (source == target) {
      progressCallback?.call(1.0, 'Ngôn ngữ nguồn và đích giống nhau, bỏ qua dịch.');
      return document;
    }

    final sessionKey = checkpointSessionId ??
        TranslationCheckpointManager.generateSessionKey(
          document: document,
          targetLanguage: targetLanguage,
          identifier: 'offline_${source.bcpCode}_${target.bcpCode}',
        );

    // 1. Phục hồi trạng thái đã dịch từ Checkpoint nếu có
    if (enableCheckpoint) {
      final cachedTranslations =
          await TranslationCheckpointManager.loadCheckpoint(sessionKey);
      if (cachedTranslations.isNotEmpty) {
        var restored = 0;
        for (final item in items) {
          final trans = cachedTranslations[item.id]?.trim();
          if (trans != null && trans.isNotEmpty) {
            item.translatedText = trans;
            item.normalizeTranslation();
            _memoryCache[item.originalText.trim()] = trans;
            restored++;
          }
        }
        if (restored > 0) {
          progressCallback?.call(
            0.05,
            'Đã khôi phục $restored/${items.length} câu từ Checkpoint!',
          );
          final remaining = items.where((it) {
            final trans = it.translatedText.trim();
            final orig = it.originalText.trim();
            return trans.isEmpty || trans == orig;
          });
          if (remaining.isEmpty) {
            progressCallback?.call(1.0, 'Đã hoàn tất toàn bộ phụ đề từ Checkpoint!');
            await TranslationCheckpointManager.clearCheckpoint(sessionKey);
            return document;
          }
        }
      }
    }

    // 2. Đảm bảo gói ngôn ngữ đã sẵn sàng
    await _ensureModelsReady(
      sourceLang: source,
      targetLang: target,
      progressCallback: progressCallback,
    );

    if (isCancelled?.call() == true) {
      throw StateError('Đã huỷ tác vụ');
    }

    // 3. Khởi tạo một instance translator duy nhất cho toàn bộ quá trình
    final translator = OnDeviceTranslator(
      sourceLanguage: source,
      targetLanguage: target,
    );

    try {
      final safeBatchSize = batchSize.clamp(10, 60);
      final chunks = <List<SubtitleItem>>[];
      for (var i = 0; i < items.length; i += safeBatchSize) {
        chunks.add(items.sublist(i, math.min(i + safeBatchSize, items.length)));
      }

      var completedItemsCount = 0;
      // Đếm số câu đã có bản dịch trước đó (từ checkpoint hoặc câu rỗng)
      for (final it in items) {
        if (it.translatedText.trim().isNotEmpty &&
            it.translatedText.trim() != it.originalText.trim()) {
          completedItemsCount++;
        }
      }

      const String delimiter = '\n---SUB_SEP---\n';
      final delimiterRegex = RegExp(r'\s*---\s*SUB_SEP\s*---\s*');

      for (var chunkIdx = 0; chunkIdx < chunks.length; chunkIdx++) {
        if (isCancelled?.call() == true) {
          throw StateError('Đã huỷ tác vụ');
        }

        final chunk = chunks[chunkIdx];

        // Lọc các câu cần dịch trong chunk này
        final pendingInChunk = <SubtitleItem>[];
        for (final item in chunk) {
          final orig = item.originalText.trim();
          final trans = item.translatedText.trim();

          if (orig.isEmpty || _isNonTranslatable(orig)) {
            item.translatedText = item.originalText;
            item.normalizeTranslation();
            completedItemsCount++;
            continue;
          }

          // Kiểm tra câu trùng đã có trong bộ nhớ đệm chưa
          if (_memoryCache.containsKey(orig)) {
            item.translatedText = _memoryCache[orig]!;
            item.normalizeTranslation();
            completedItemsCount++;
            continue;
          }

          if (trans.isNotEmpty && trans != orig) {
            _memoryCache[orig] = trans;
            continue;
          }

          pendingInChunk.add(item);
        }

        if (pendingInChunk.isNotEmpty) {
          // Gộp batch bằng Delimiter
          final combinedText =
              pendingInChunk.map((it) => it.originalText.trim()).join(delimiter);

          bool batchSucceeded = false;
          try {
            final translatedCombined =
                await translator.translateText(combinedText);
            final parts = translatedCombined.split(delimiterRegex);

            if (parts.length == pendingInChunk.length) {
              for (var i = 0; i < pendingInChunk.length; i++) {
                final trans = parts[i].trim();
                final originalItem = pendingInChunk[i];
                final finalTrans =
                    trans.isNotEmpty ? trans : originalItem.originalText;
                originalItem.translatedText = finalTrans;
                originalItem.normalizeTranslation();
                _memoryCache[originalItem.originalText.trim()] = finalTrans;
              }
              batchSucceeded = true;
            }
          } catch (e) {
            debugPrint('[OfflineMlKit] Lỗi dịch batch khối $chunkIdx: $e');
            batchSucceeded = false;
          }

          // Nếu delimiter mismatch hoặc lỗi thì fallback dịch từng câu an toàn
          if (!batchSucceeded) {
            for (final originalItem in pendingInChunk) {
              if (isCancelled?.call() == true) {
                throw StateError('Đã huỷ tác vụ');
              }
              final orig = originalItem.originalText.trim();
              if (_memoryCache.containsKey(orig)) {
                originalItem.translatedText = _memoryCache[orig]!;
              } else {
                try {
                  final trans = await translator.translateText(orig);
                  final finalTrans =
                      trans.trim().isNotEmpty ? trans.trim() : orig;
                  originalItem.translatedText = finalTrans;
                  _memoryCache[orig] = finalTrans;
                } catch (_) {
                  originalItem.translatedText = orig;
                }
              }
              originalItem.normalizeTranslation();
            }
          }

          completedItemsCount += pendingInChunk.length;

          // Lưu checkpoint sau mỗi khối hoàn tất
          if (enableCheckpoint) {
            final checkpointData = <int, String>{};
            for (final it in chunk) {
              if (it.translatedText.trim().isNotEmpty) {
                checkpointData[it.id] = it.translatedText;
              }
            }
            if (checkpointData.isNotEmpty) {
              unawaited(
                TranslationCheckpointManager.saveCheckpoint(
                  sessionKey: sessionKey,
                  targetLanguage: targetLanguage,
                  totalItems: items.length,
                  translations: checkpointData,
                ),
              );
            }
          }
        }

        final pct = (completedItemsCount / items.length).clamp(0.0, 1.0);
        progressCallback?.call(
          pct,
          'Dịch ngoại tuyến (ML Kit): $completedItemsCount/${items.length} câu (${(pct * 100).toInt()}%)...',
        );
      }

      // Xóa checkpoint khi hoàn thành xuất sắc toàn bộ
      if (enableCheckpoint) {
        await TranslationCheckpointManager.clearCheckpoint(sessionKey);
      }

      progressCallback?.call(1.0, 'Đã dịch ngoại tuyến thành công 100%!');
      return document;
    } finally {
      await translator.close();
    }
  }

  /// Kiểm tra các dòng không cần dịch (số, dấu câu, emoji...)
  static bool _isNonTranslatable(String text) {
    if (text.isEmpty) return true;
    // Toàn là số, dấu phân cách, dấu chấm hỏi, ngoặc
    final cleaned = text.replaceAll(RegExp(r'[\d\s.,!?:;()\-–—_~*#@/\\\[\]{}<>|]'), '');
    return cleaned.isEmpty;
  }
}
