import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/repository/settings_repository.dart';

class CustomFontManager {
  static final Set<String> _loadedFamilies = <String>{};

  /// Thư mục lưu trữ fonts tùy chỉnh của ứng dụng
  static Future<Directory> getFontsDirectory() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final fontsDir = Directory('${docsDir.path}/fonts');
    if (!fontsDir.existsSync()) {
      await fontsDir.create(recursive: true);
    }
    return fontsDir;
  }

  /// Nạp tất cả các phông chữ đã lưu vào Flutter engine khi khởi động
  static Future<void> loadAllSavedFonts(SettingsRepository settings) async {
    final fontsDir = await getFontsDirectory();
    final customList = List<String>.from(settings.customFonts);
    final validFamilies = <String>[];

    for (final family in customList) {
      final ttf = File('${fontsDir.path}/$family.ttf');
      final otf = File('${fontsDir.path}/$family.otf');
      File? targetFile;

      if (ttf.existsSync()) {
        targetFile = ttf;
      } else if (otf.existsSync()) {
        targetFile = otf;
      }

      if (targetFile != null && targetFile.existsSync()) {
        final success = await _loadFontFile(family, targetFile);
        if (success) {
          validFamilies.add(family);
        }
      }
    }

    if (validFamilies.length != customList.length) {
      settings.customFonts = validFamilies;
      if (!validFamilies.contains(settings.selectedFontFamily)) {
        settings.selectedFontFamily = '';
      }
    }
  }

  /// Nạp một file font vào Flutter engine
  static Future<bool> _loadFontFile(String familyName, File file) async {
    if (_loadedFamilies.contains(familyName)) {
      return true;
    }
    try {
      final fontBytes = await file.readAsBytes();
      if (fontBytes.length < 1024) return false;

      final fontLoader = FontLoader(familyName);
      fontLoader.addFont(Future.value(ByteData.view(fontBytes.buffer)));
      await fontLoader.load();
      _loadedFamilies.add(familyName);
      debugPrint('CustomFontManager: Đã nạp phông chữ "$familyName"');
      return true;
    } catch (e) {
      debugPrint('CustomFontManager: Lỗi khi nạp phông chữ "$familyName": $e');
      return false;
    }
  }

  /// Chọn file font từ máy (.ttf, .otf) và nhập vào app
  static Future<String?> pickAndImportFont(SettingsRepository settings) async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['ttf', 'otf'],
      );

      if (files.isEmpty) {
        return null;
      }

      final picked = files.first;
      final rawName = picked.name;
      final ext = rawName.contains('.')
          ? rawName.split('.').last.toLowerCase()
          : 'ttf';

      if (ext != 'ttf' && ext != 'otf') {
        throw const FormatException('Chỉ hỗ trợ định dạng phông chữ .ttf và .otf');
      }

      // Chuẩn hóa tên family
      final baseName = rawName.substring(0, rawName.lastIndexOf('.'));
      final familyName = baseName
          .replaceAll(RegExp(r'[^a-zA-Z0-9_\-\s]'), '')
          .trim();

      if (familyName.isEmpty) {
        throw const FormatException('Tên file phông chữ không hợp lệ');
      }

      final fontsDir = await getFontsDirectory();
      final destination = File('${fontsDir.path}/$familyName.$ext');

      if (picked.path != null && picked.path!.isNotEmpty) {
        await File(picked.path!).copy(destination.path);
      } else {
        throw const FormatException('Không thể đọc dữ liệu file phông chữ');
      }

      // Nạp font vào runtime
      final success = await _loadFontFile(familyName, destination);
      if (!success) {
        if (destination.existsSync()) destination.deleteSync();
        throw const FormatException('Không thể giải mã file phông chữ');
      }

      // Lưu vào danh sách settings
      final currentFonts = List<String>.from(settings.customFonts);
      if (!currentFonts.contains(familyName)) {
        currentFonts.add(familyName);
        settings.customFonts = currentFonts;
      }
      settings.selectedFontFamily = familyName;
      return familyName;
    } catch (e) {
      debugPrint('CustomFontManager.pickAndImportFont error: $e');
      rethrow;
    }
  }

  /// Xóa font tùy chỉnh đã nhập
  static Future<void> deleteFont(
    String familyName,
    SettingsRepository settings,
  ) async {
    try {
      final fontsDir = await getFontsDirectory();
      final ttf = File('${fontsDir.path}/$familyName.ttf');
      final otf = File('${fontsDir.path}/$familyName.otf');

      if (ttf.existsSync()) ttf.deleteSync();
      if (otf.existsSync()) otf.deleteSync();

      final currentFonts = List<String>.from(settings.customFonts);
      currentFonts.remove(familyName);
      settings.customFonts = currentFonts;

      if (settings.selectedFontFamily == familyName) {
        settings.selectedFontFamily = '';
      }
    } catch (e) {
      debugPrint('CustomFontManager.deleteFont error: $e');
    }
  }
}
