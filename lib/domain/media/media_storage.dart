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

  static bool isContentUri(String value) {
    return Uri.tryParse(value)?.scheme.toLowerCase() == 'content';
  }

  /// Android giữ URI do Storage Access Framework cấp để đọc trực tiếp file gốc.
  /// Nếu nhà cung cấp không cho giữ quyền lâu dài, app mới tạo bản sao dự phòng.
  /// iOS vẫn sao chép vào Application Support vì URL của document picker có thể
  /// chỉ truy cập được tạm thời.
  static Future<MediaSelection?> pickPersistentMedia({
    required bool videoOnly,
    List<String> allowedExtensions = const [],
    MediaSourceOption? sourceOption,
    BuildContext? context,
  }) async {
    if (Platform.isAndroid) {
      final picked = await _channel.invokeMapMethod<String, dynamic>(
        'pickMedia',
        {'videoOnly': videoOnly},
      );
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

    MediaSourceOption? selectedOption = sourceOption;
    if (selectedOption == null && context != null && Platform.isIOS) {
      selectedOption = await showMediaSourceSheet(
        context,
        videoOnly: videoOnly,
      );
      if (selectedOption == null) {
        return null;
      }
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

  /// Hiển thị Action Sheet lựa chọn giữa Photos (Thư viện ảnh) và Ứng dụng Tệp (Files)
  static Future<MediaSourceOption?> showMediaSourceSheet(
    BuildContext context, {
    bool videoOnly = false,
  }) async {
    return showModalBottomSheet<MediaSourceOption>(
      context: context,
      backgroundColor: AppColors.darkCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Chọn nguồn media',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.grey, size: 20),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: AppColors.cardBorder),
                ),
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.primaryEmerald.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.video_library_rounded,
                    color: AppColors.primaryEmerald,
                    size: 22,
                  ),
                ),
                title: const Text(
                  'Video từ Photos',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                subtitle: const Text(
                  'Chọn video từ ứng dụng Ảnh của máy',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
                onTap: () => Navigator.pop(ctx, MediaSourceOption.photos),
              ),
              const SizedBox(height: 10),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: AppColors.cardBorder),
                ),
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.folder_open_rounded,
                    color: Colors.blueAccent,
                    size: 22,
                  ),
                ),
                title: Text(
                  videoOnly ? 'Tệp video (Files)' : 'Tệp trên máy (Files)',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                subtitle: const Text(
                  'Chọn từ iCloud Drive, Tải về hoặc Trên iPhone',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
                onTap: () => Navigator.pop(ctx, MediaSourceOption.files),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
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
