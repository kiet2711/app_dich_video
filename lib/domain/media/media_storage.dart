import 'dart:io';

import 'package:path_provider/path_provider.dart';

class MediaStorage {
  static Future<File> importForPersistentAccess(
    File source,
    String originalName,
  ) async {
    if (!await source.exists()) {
      throw StateError('Tệp media không còn tồn tại.');
    }

    final supportDir = await getApplicationSupportDirectory();
    final mediaDir = Directory(
      '${supportDir.path}${Platform.pathSeparator}media',
    );
    await mediaDir.create(recursive: true);

    final sourcePath = source.absolute.path;
    final persistentRoot = mediaDir.absolute.path;
    if (sourcePath.startsWith('$persistentRoot${Platform.pathSeparator}')) {
      return source;
    }

    final safeName = originalName
        .replaceAll(
          RegExp(r'[^a-zA-Z0-9._()\-\u00C0-\u024F\u1E00-\u1EFF]'),
          '_',
        )
        .replaceAll(RegExp(r'_+'), '_');
    final finalName = safeName.isEmpty ? 'media.bin' : safeName;
    final destination = File(
      '${mediaDir.path}${Platform.pathSeparator}${DateTime.now().millisecondsSinceEpoch}_$finalName',
    );

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
}
