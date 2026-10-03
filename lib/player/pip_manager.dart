import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Quản lý chế độ Hình trong Hình (Picture-in-Picture - PiP) trên Android/iOS
class PipManager {
  static const MethodChannel _channel = MethodChannel('com.capcut.capsub/pip');
  static final ValueNotifier<bool> isInPipMode = ValueNotifier<bool>(false);
  static final ValueNotifier<String?> lastPipAction = ValueNotifier<String?>(null);
  static bool _initialized = false;

  /// Lắng nghe sự kiện thay đổi trạng thái PiP và các hành động nút điều khiển từ native Android
  static void initialize() {
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPipModeChanged') {
        final inPip = call.arguments as bool? ?? false;
        isInPipMode.value = inPip;
      } else if (call.method == 'onPipAction') {
        final action = call.arguments as String? ?? '';
        lastPipAction.value = action;
        // Reset sau 50ms để có thể nhận cùng action liên tiếp
        Future.delayed(const Duration(milliseconds: 50), () {
          if (lastPipAction.value == action) {
            lastPipAction.value = null;
          }
        });
      }
    });
  }

  /// Kiểm tra thiết bị có hỗ trợ PiP hay không
  static Future<bool> isPipSupported() async {
    if (!Platform.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>('isPipSupported');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Kích hoạt chế độ Picture-in-Picture ngoài màn hình chính Android
  static Future<bool> enterPip({
    int width = 16,
    int height = 9,
    bool isPlaying = true,
  }) async {
    if (!Platform.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>('enterPip', {
        'width': width,
        'height': height,
        'isPlaying': isPlaying,
      });
      return res ?? false;
    } catch (e) {
      debugPrint('Lỗi kích hoạt PiP: $e');
      return false;
    }
  }

  /// Cập nhật trạng thái các nút điều khiển trong native PiP (Play/Pause)
  static Future<bool> updatePipActions({required bool isPlaying}) async {
    if (!Platform.isAndroid || !isInPipMode.value) return false;
    try {
      final res = await _channel.invokeMethod<bool>('updatePipActions', {
        'isPlaying': isPlaying,
      });
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Điều chỉnh tỉ lệ / kích thước khung hình PiP mượt mà trong khi đang phát
  static Future<bool> updatePipAspectRatio({
    required int width,
    required int height,
  }) async {
    if (!Platform.isAndroid || !isInPipMode.value) return false;
    try {
      final res = await _channel.invokeMethod<bool>('updatePipAspectRatio', {
        'width': width,
        'height': height,
      });
      return res ?? false;
    } catch (_) {
      return false;
    }
  }
}
