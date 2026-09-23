import 'dart:io';

import 'package:flutter/services.dart';

class ForegroundServiceManager {
  static const MethodChannel _channel = MethodChannel(
    'com.capcut.capsub/foreground_service',
  );

  /// Khởi chạy Foreground Service trên Android với thanh thông báo tiến trình và Partial WakeLock.
  /// Trên các nền tảng khác (iOS, Desktop), phương thức này tự động bỏ qua an toàn.
  static Future<void> start({
    required String title,
    required String message,
    int progress = 0,
    int maxProgress = 100,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('start', {
        'title': title,
        'message': message,
        'progress': progress,
        'maxProgress': maxProgress,
      });
    } catch (_) {}
  }

  /// Cập nhật nội dung hiển thị và phần trăm tiến độ trên thanh thông báo Android.
  static Future<void> update({
    String? title,
    required String message,
    int progress = 0,
    int maxProgress = 100,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      final payload = <String, dynamic>{
        'message': message,
        'progress': progress,
        'maxProgress': maxProgress,
      };
      if (title != null) {
        payload['title'] = title;
      }
      await _channel.invokeMethod('update', payload);
    } catch (_) {}
  }

  /// Dừng Foreground Service và giải phóng WakeLock khi tiến trình hoàn tất hoặc bị hủy.
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }
}
