import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../ui/theme/app_theme.dart';

enum MediaSourceOption { photos, files }

class MediaSelection {
  const MediaSelection({
    required this.location,
    required this.name,
    required this.sizeBytes,
    required this.usesDirectUri,
  });

  final String location;
  final String name;
  final int sizeBytes;
  final bool usesDirectUri;
}

class MediaStorage {
  static const MethodChannel _channel = MethodChannel(
    'com.capcut.capsub/media',
  );

  static bool _isPickerActive = false;
  static DateTime? _suppressBackUntil;

  static bool get shouldSuppressBackMinimize {
    if (_isPickerActive) return true;
    final until = _suppressBackUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  static bool isContentUri(String value) {
    return Uri.tryParse(value)?.scheme.toLowerCase() == 'content';
  }

  /// Android hỗ trợ chọn từ Thư viện Video (Photo Picker) hoặc Tệp & Thư mục (SAF).
  /// iOS hỗ trợ Photos hoặc ứng dụng Tệp (Files).
  static Future<MediaSelection?> pickPersistentMedia({
    required bool videoOnly,
    List<String> allowedExtensions = const [],
    MediaSourceOption? sourceOption,
    BuildContext? context,
  }) async {
    MediaSourceOption? selectedOption = sourceOption;
    if (selectedOption == null &&
        context != null &&
        (Platform.isAndroid || Platform.isIOS)) {
      selectedOption = await showMediaSourceSheet(
        context,
        videoOnly: videoOnly,
      );
      if (selectedOption == null) {
        return null;
      }
    }

    if (Platform.isAndroid) {
      final sourceKey = selectedOption == MediaSourceOption.photos
          ? 'photos'
          : (selectedOption == MediaSourceOption.files
                ? 'files'
                : (videoOnly ? 'photos' : 'files'));

      _isPickerActive = true;
      final Map<String, dynamic>? picked;
      try {
        picked = await _channel.invokeMapMethod<String, dynamic>('pickMedia', {
          'videoOnly': videoOnly,
          'source': sourceKey,
        });
      } finally {
        _isPickerActive = false;
        _suppressBackUntil = DateTime.now().add(
          const Duration(milliseconds: 900),
        );
      }
      if (picked == null) return null;

      final uri = picked['uri'] as String? ?? '';
      if (!isContentUri(uri)) {
        throw StateError('Android không trả về URI media hợp lệ.');
      }

      final rawName = picked['name'] as String? ?? 'media.bin';
      final name = rawName.trim().isEmpty ? 'media.bin' : rawName.trim();
      final reportedSize = (picked['sizeBytes'] as num?)?.toInt() ?? 0;
      final persisted = picked['persisted'] == true;
      if (persisted) {
        return MediaSelection(
          location: uri,
          name: name,
          sizeBytes: reportedSize,
          usesDirectUri: true,
        );
      }

      final destination = await _createPersistentDestination(name);
      final copiedBytes = await _channel.invokeMethod<num>('copyContentUri', {
        'uri': uri,
        'outputPath': destination.path,
      });
      return MediaSelection(
        location: destination.path,
        name: name,
        sizeBytes: copiedBytes?.toInt() ?? await destination.length(),
        usesDirectUri: false,
      );
    }

    final effectiveExtensions = allowedExtensions.isNotEmpty
        ? allowedExtensions
        : (videoOnly
              ? const ['mp4', 'mov', 'm4v', 'mkv', 'webm']
              : const [
                  'mp4',
                  'mov',
                  'm4v',
                  'mkv',
                  'webm',
                  'mp3',
                  'm4a',
                  'aac',
                  'wav',
                  'flac',
                ]);

    final List<PlatformFile> files;
    if (selectedOption == MediaSourceOption.photos) {
      files = await FilePicker.pickFiles(type: FileType.video);
    } else {
      files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: effectiveExtensions,
      );
    }
    if (files.isEmpty || files.first.path == null) return null;

    final source = File(files.first.path!);
    final stored = await importForPersistentAccess(source, files.first.name);
    return MediaSelection(
      location: stored.path,
      name: files.first.name,
      sizeBytes: await stored.length(),
      usesDirectUri: false,
    );
  }

  /// Hiển thị Action Sheet lựa chọn giữa Thư viện Video (Ảnh/Gallery) và Tệp (Files)
  static Future<MediaSourceOption?> showMediaSourceSheet(
    BuildContext context, {
    bool videoOnly = false,
  }) async {
    final isAndroid = Platform.isAndroid;
    return showModalBottomSheet<MediaSourceOption>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final palette = AppThemePalette.of(ctx);
        final accent = palette.accentFor(AppTabId.studio);
        final secondary = palette.secondaryFor(AppTabId.studio);
        final readableAccent = palette.readableAccent(accent);
        final readableSecondary = palette.readableAccent(secondary);
        final hasGradient =
            palette.backgroundGradientFor(AppTabId.studio) != null;
        final cardBg = hasGradient ? palette.surface : palette.surfaceAlt;
        final cardShadows =
            hasGradient ? palette.cardShadows : const <BoxShadow>[];

        return Container(
          decoration: palette.sheetDecorationFor(AppTabId.studio, radius: 22),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: palette.textMuted.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Chọn nguồn media',
                        style: TextStyle(
                          color: palette.textPrimary,
                          fontSize: 16.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.close_rounded,
                          color: palette.textPrimary,
                          size: 20,
                        ),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  InkWell(
                    onTap: () => Navigator.pop(ctx, MediaSourceOption.photos),
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: palette.border, width: 1.1),
                        boxShadow: cardShadows,
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: secondary.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              Icons.video_library_rounded,
                              color: readableSecondary,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isAndroid
                                      ? 'Thư viện Video trên máy'
                                      : 'Video từ Photos',
                                  style: TextStyle(
                                    color: palette.textPrimary,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14.5,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  isAndroid
                                      ? 'Chọn trực tiếp video trong Ảnh / Gallery'
                                      : 'Chọn video từ ứng dụng Ảnh của máy',
                                  style: TextStyle(
                                    color: palette.textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: palette.textMuted,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  InkWell(
                    onTap: () => Navigator.pop(ctx, MediaSourceOption.files),
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: palette.border, width: 1.1),
                        boxShadow: cardShadows,
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              Icons.folder_open_rounded,
                              color: readableAccent,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  videoOnly
                                      ? 'Tệp video trong thư mục'
                                      : (isAndroid
                                            ? 'Tệp & Âm thanh (Thư mục)'
                                            : 'Tệp trên máy (Files)'),
                                  style: TextStyle(
                                    color: palette.textPrimary,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14.5,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  isAndroid
                                      ? 'Duyệt Tải về / Bộ nhớ máy (MP4, MKV, MP3, M4A...)'
                                      : 'Chọn từ iCloud Drive, Tải về hoặc Trên iPhone',
                                  style: TextStyle(
                                    color: palette.textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: palette.textMuted,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static Future<File> importForPersistentAccess(
    File source,
    String originalName,
  ) async {
    if (!await source.exists()) {
      throw StateError('Tệp media không còn tồn tại.');
    }

    final destination = await _createPersistentDestination(originalName);
    final persistentRoot = destination.parent.absolute.path;
    final sourcePath = source.absolute.path;
    if (sourcePath.startsWith('$persistentRoot${Platform.pathSeparator}')) {
      return source;
    }

    final sink = destination.openWrite();
    try {
      await sink.addStream(source.openRead());
      await sink.flush();
      await sink.close();
      return destination;
    } catch (_) {
      await sink.close();
      if (await destination.exists()) await destination.delete();
      rethrow;
    }
  }

  static Future<File> _createPersistentDestination(String originalName) async {
    final supportDir = await getApplicationSupportDirectory();
    final mediaDir = Directory(
      '${supportDir.path}${Platform.pathSeparator}media',
    );
    await mediaDir.create(recursive: true);

    final safeName = originalName
        .replaceAll(
          RegExp(r'[^a-zA-Z0-9._()\-\u00C0-\u024F\u1E00-\u1EFF]'),
          '_',
        )
        .replaceAll(RegExp(r'_+'), '_');
    final finalName = safeName.isEmpty ? 'media.bin' : safeName;
    return File(
      '${mediaDir.path}${Platform.pathSeparator}${DateTime.now().millisecondsSinceEpoch}_$finalName',
    );
  }
}
