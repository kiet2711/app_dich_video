import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

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

    final files = await FilePicker.pickFiles(
      type: videoOnly ? FileType.video : FileType.custom,
      allowedExtensions: videoOnly || allowedExtensions.isEmpty
          ? null
          : allowedExtensions,
    );
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
