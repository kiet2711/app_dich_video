import 'dart:io';
import 'package:path_provider/path_provider.dart';

import '../../data/repository/history_repository.dart';
import '../media/video_cache_manager.dart';

enum StorageCategory {
  video,
  audio,
  subtitle,
  temp,
}

class StorageFileItem {
  final String path;
  final String displayName;
  final String description;
  final int sizeBytes;
  final StorageCategory category;
  final DateTime modifiedAt;
  final bool isSafeToClean;
  final bool isDirectory;

  const StorageFileItem({
    required this.path,
    required this.displayName,
    required this.description,
    required this.sizeBytes,
    required this.category,
    required this.modifiedAt,
    this.isSafeToClean = false,
    this.isDirectory = false,
  });

  String get formattedSize {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    if (sizeBytes < 1024 * 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class StorageScanResult {
  final List<StorageFileItem> items;
  final int totalSizeBytes;
  final int videoSizeBytes;
  final int audioSizeBytes;
  final int subtitleSizeBytes;
  final int tempSizeBytes;
  final int safeCleanSizeBytes;

  const StorageScanResult({
    required this.items,
    required this.totalSizeBytes,
    required this.videoSizeBytes,
    required this.audioSizeBytes,
    required this.subtitleSizeBytes,
    required this.tempSizeBytes,
    required this.safeCleanSizeBytes,
  });

  String get formattedTotal => format(totalSizeBytes);
  String get formattedVideo => format(videoSizeBytes);
  String get formattedAudio => format(audioSizeBytes);
  String get formattedSubtitle => format(subtitleSizeBytes);
  String get formattedTemp => format(tempSizeBytes);
  String get formattedSafeClean => format(safeCleanSizeBytes);

  static String format(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class StorageCleanerService {
  /// Quét toàn diện bộ nhớ ứng dụng và phân loại thông minh
  static Future<StorageScanResult> scanStorage() async {
    final items = <StorageFileItem>[];

    // 1. Quét Video Cache & Media (Application Support)
    try {
      final cacheDir = await VideoCacheManager.getCacheDirectory();
      if (await cacheDir.exists()) {
        final list = cacheDir.listSync();
        for (final entity in list) {
          if (entity is File) {
            final stat = entity.statSync();
            final name = entity.path.split(RegExp(r'[/\\]')).last;
            final isPart = name.endsWith('.part');

            if (isPart) {
              items.add(
                StorageFileItem(
                  path: entity.path,
                  displayName: name.replaceAll('.part', ''),
                  description: 'File video đang tải dở dang (Rác)',
                  sizeBytes: stat.size,
                  category: StorageCategory.temp,
                  modifiedAt: stat.modified,
                  isSafeToClean: true,
                ),
              );
            } else {
              String desc = 'Video offline tải về';
              String dispName = name;
              if (name.startsWith('bili_')) {
                final match = RegExp(r'bili_([^_]+)_p(\d+)').firstMatch(name);
                if (match != null) {
                  dispName = 'Bilibili: ${match.group(1)} (P${match.group(2)})';
                  desc = 'Video Bilibili xem offline không lag';
                }
              } else if (name.startsWith('hg_')) {
                final match = RegExp(r'hg_([^_]+)_ep(\d+)').firstMatch(name);
                if (match != null) {
                  dispName = 'Phim Hồng Quả: Tập ${match.group(2)}';
                  desc = 'Tập phim bộ Hồng Quả đã tải về máy';
                }
              }

              items.add(
                StorageFileItem(
                  path: entity.path,
                  displayName: dispName,
                  description: desc,
                  sizeBytes: stat.size,
                  category: StorageCategory.video,
                  modifiedAt: stat.modified,
                  isSafeToClean: false,
                ),
              );
            }
          }
        }
      }

      final supportDir = await getApplicationSupportDirectory();
      final mediaDir = Directory('${supportDir.path}${Platform.pathSeparator}media');
      if (await mediaDir.exists()) {
        for (final f in mediaDir.listSync().whereType<File>()) {
          final stat = f.statSync();
          final name = f.path.split(RegExp(r'[/\\]')).last;
          items.add(
            StorageFileItem(
              path: f.path,
              displayName: name,
              description: 'Bản sao video đã nhập vào app',
              sizeBytes: stat.size,
              category: StorageCategory.video,
              modifiedAt: stat.modified,
              isSafeToClean: false,
            ),
          );
        }
      }
    } catch (_) {}

    // 2. Quét Âm thanh & Lồng tiếng AI (TTS Cache trong Documents)
    try {
      final docDir = await getApplicationDocumentsDirectory();

      // Thư mục tts_cache chuẩn
      final ttsDir = Directory('${docDir.path}${Platform.pathSeparator}tts_cache');
      if (await ttsDir.exists()) {
        for (final docFolder in ttsDir.listSync().whereType<Directory>()) {
          final folderName = docFolder.path.split(RegExp(r'[/\\]')).last;
          int folderSize = 0;
          DateTime lastMod = DateTime.fromMillisecondsSinceEpoch(0);
          int fileCount = 0;

          final files = docFolder.listSync(recursive: true);
          for (final f in files) {
            if (f is File) {
              final stat = f.statSync();
              folderSize += stat.size;
              fileCount++;
              if (stat.modified.isAfter(lastMod)) lastMod = stat.modified;
            }
          }

          if (folderSize > 0) {
            items.add(
              StorageFileItem(
                path: docFolder.path,
                displayName: 'Lồng tiếng AI ($fileCount câu thoại)',
                description: 'Bộ nhớ đệm giọng đọc TTS: $folderName',
                sizeBytes: folderSize,
                category: StorageCategory.audio,
                modifiedAt: lastMod,
                isDirectory: true,
                isSafeToClean: false,
              ),
            );
          }
        }
      }

      // Thư mục legacy tts_cache_*
      for (final entity in docDir.listSync()) {
        final name = entity.path.split(RegExp(r'[/\\]')).last;
        if (entity is Directory && name.startsWith('tts_cache_')) {
          int size = 0;
          for (final f in entity.listSync(recursive: true).whereType<File>()) {
            size += f.statSync().size;
          }
          if (size > 0) {
            items.add(
              StorageFileItem(
                path: entity.path,
                displayName: 'Cache TTS cũ ($name)',
                description: 'Bộ nhớ đệm âm thanh giọng đọc phiên bản cũ',
                sizeBytes: size,
                category: StorageCategory.audio,
                modifiedAt: entity.statSync().modified,
                isDirectory: true,
                isSafeToClean: true,
              ),
            );
          }
        }
      }
    } catch (_) {}

    // 3. Quét Phụ đề & Kịch bản (Subtitles trong Documents)
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final subDir = Directory('${docDir.path}${Platform.pathSeparator}subtitles');
      if (await subDir.exists()) {
        for (final f in subDir.listSync().whereType<File>()) {
          final stat = f.statSync();
          final name = f.path.split(RegExp(r'[/\\]')).last;
          final isSrt = name.endsWith('.srt');
          final isJson = name.endsWith('.json');

          if (isSrt || isJson) {
            items.add(
              StorageFileItem(
                path: f.path,
                displayName: name,
                description: isSrt
                    ? 'Tệp phụ đề SRT hoàn chỉnh'
                    : 'Kịch bản phụ đề CapSub chi tiết',
                sizeBytes: stat.size,
                category: StorageCategory.subtitle,
                modifiedAt: stat.modified,
                isSafeToClean: false,
              ),
            );
          }
        }
      }

      final savedDir = Directory('${docDir.path}${Platform.pathSeparator}saved_subtitles');
      if (await savedDir.exists()) {
        for (final f in savedDir.listSync().whereType<File>()) {
          final stat = f.statSync();
          final name = f.path.split(RegExp(r'[/\\]')).last;
          items.add(
            StorageFileItem(
              path: f.path,
              displayName: name,
              description: 'Phụ đề đã xuất / lưu trữ',
              sizeBytes: stat.size,
              category: StorageCategory.subtitle,
              modifiedAt: stat.modified,
              isSafeToClean: false,
            ),
          );
        }
      }

      final checkpointDir = Directory('${docDir.path}${Platform.pathSeparator}translation_checkpoints');
      if (await checkpointDir.exists()) {
        for (final f in checkpointDir.listSync().whereType<File>()) {
          final stat = f.statSync();
          final name = f.path.split(RegExp(r'[/\\]')).last;
          items.add(
            StorageFileItem(
              path: f.path,
              displayName: name,
              description: 'Bản dịch tạm (Checkpoint) để khôi phục khi ngắt quãng',
              sizeBytes: stat.size,
              category: StorageCategory.temp,
              modifiedAt: stat.modified,
              isSafeToClean: true,
            ),
          );
        }
      }
    } catch (_) {}

    // 4. Quét Bộ nhớ đệm tạm (Temporary Directory)
    try {
      final tempDir = await getTemporaryDirectory();
      if (await tempDir.exists()) {
        for (final entity in tempDir.listSync()) {
          if (entity is File) {
            final stat = entity.statSync();
            final name = entity.path.split(RegExp(r'[/\\]')).last;
            items.add(
              StorageFileItem(
                path: entity.path,
                displayName: name,
                description: 'Bộ nhớ tạm hệ thống (iOS picker / trích xuất âm thanh)',
                sizeBytes: stat.size,
                category: StorageCategory.temp,
                modifiedAt: stat.modified,
                isSafeToClean: true,
              ),
            );
          } else if (entity is Directory) {
            int folderSize = 0;
            int count = 0;
            for (final f in entity.listSync(recursive: true).whereType<File>()) {
              folderSize += f.statSync().size;
              count++;
            }
            if (folderSize > 0) {
              final name = entity.path.split(RegExp(r'[/\\]')).last;
              items.add(
                StorageFileItem(
                  path: entity.path,
                  displayName: '$name ($count files)',
                  description: 'Thư mục phiên xử lý tạm thời',
                  sizeBytes: folderSize,
                  category: StorageCategory.temp,
                  modifiedAt: entity.statSync().modified,
                  isDirectory: true,
                  isSafeToClean: true,
                ),
              );
            }
          }
        }
      }
    } catch (_) {}

    // Sắp xếp mặc định: Dung lượng lớn nhất lên đầu để người dùng dễ tối ưu bộ nhớ
    items.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));

    // Thống kê tổng hợp
    var total = 0;
    var vid = 0;
    var aud = 0;
    var sub = 0;
    var tmp = 0;
    var safe = 0;

    for (final it in items) {
      total += it.sizeBytes;
      if (it.isSafeToClean) safe += it.sizeBytes;
      switch (it.category) {
        case StorageCategory.video:
          vid += it.sizeBytes;
          break;
        case StorageCategory.audio:
          aud += it.sizeBytes;
          break;
        case StorageCategory.subtitle:
          sub += it.sizeBytes;
          break;
        case StorageCategory.temp:
          tmp += it.sizeBytes;
          break;
      }
    }

    return StorageScanResult(
      items: items,
      totalSizeBytes: total,
      videoSizeBytes: vid,
      audioSizeBytes: aud,
      subtitleSizeBytes: sub,
      tempSizeBytes: tmp,
      safeCleanSizeBytes: safe,
    );
  }

  /// Xóa danh sách các mục được chọn
  static Future<int> deleteItems(List<StorageFileItem> items) async {
    int freedBytes = 0;
    final historyRepo = await HistoryRepository.getInstance();

    for (final it in items) {
      try {
        if (it.isDirectory) {
          final dir = Directory(it.path);
          if (await dir.exists()) {
            await dir.delete(recursive: true);
            freedBytes += it.sizeBytes;
          }
        } else {
          final file = File(it.path);
          if (await file.exists()) {
            final len = await file.length();
            await file.delete();
            freedBytes += len;

            // Nếu xóa video đã cache, kiểm tra cập nhật lại history nếu cần
            if (it.category == StorageCategory.video) {
              final historyItems = historyRepo.getHistory();
              for (final h in historyItems) {
                if (h.videoPath == it.path) {
                  // Cập nhật lại đường dẫn video trong lịch sử nếu file offline bị xoá
                  await historyRepo.updateVideoPath(it.path, '');
                }
              }
            }
          }
        }
      } catch (_) {}
    }

    return freedBytes;
  }

  /// Dọn nhanh thông minh (Chỉ dọn rác tạm, file dở dang .part, cache cũ)
  static Future<int> smartCleanJunk(StorageScanResult scanResult) async {
    final junkItems = scanResult.items.where((it) => it.isSafeToClean).toList();
    return deleteItems(junkItems);
  }
}
