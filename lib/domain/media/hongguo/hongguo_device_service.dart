import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'hongguo_sixgod_signer.dart';

/// Chứa thông tin danh tính thiết bị ByteDance đã được cấp phát
class HongguoDeviceInfo {
  final String deviceId;
  final String installId;
  final String deviceToken;
  final int registeredAtMs;

  const HongguoDeviceInfo({
    required this.deviceId,
    required this.installId,
    this.deviceToken = '',
    required this.registeredAtMs,
  });

  bool get isValid =>
      deviceId.isNotEmpty &&
      installId.isNotEmpty &&
      deviceId != '0' &&
      installId != '0';

  Map<String, dynamic> toJson() => {
    'device_id': deviceId,
    'install_id': installId,
    'device_token': deviceToken,
    'registered_at_ms': registeredAtMs,
  };

  factory HongguoDeviceInfo.fromJson(Map<String, dynamic> json) {
    return HongguoDeviceInfo(
      deviceId: json['device_id']?.toString() ?? '',
      installId: json['install_id']?.toString() ?? '',
      deviceToken: json['device_token']?.toString() ?? '',
      registeredAtMs: (json['registered_at_ms'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Dịch vụ tự động đăng ký và quản lý thiết bị thật với ByteDance Device Register API
class HongguoDeviceService {
  HongguoDeviceService._();
  static final HongguoDeviceService instance = HongguoDeviceService._();

  static const String _prefKey = 'hongguo_device_registered_info_v2';
  static const String currentVersionCode = '73732';
  static const String currentVersionName = '7.3.7.32';
  static const String registerEndpoint =
      'https://log.snssdk.com/service/2/device_register/';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );

  HongguoDeviceInfo? _cachedInfo;
  Future<HongguoDeviceInfo>? _inFlightRegistration;

  static String _generateOpenUdid() {
    final rand = Random();
    final chars = '0123456789abcdef';
    return List.generate(16, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  /// Lấy thiết bị hợp lệ từ cache (RAM -> SharedPreferences) hoặc đăng ký mới nếu chưa có
  Future<HongguoDeviceInfo> getOrRegisterDevice({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _cachedInfo != null && _cachedInfo!.isValid) {
      return _cachedInfo!;
    }

    if (_inFlightRegistration != null) {
      return _inFlightRegistration!;
    }

    final future = _loadOrRegister(forceRefresh: forceRefresh);
    _inFlightRegistration = future;
    try {
      final result = await future;
      _cachedInfo = result;
      return result;
    } finally {
      _inFlightRegistration = null;
    }
  }

  Future<HongguoDeviceInfo> _loadOrRegister({
    required bool forceRefresh,
  }) async {
    // 1. Đọc từ SharedPreferences nếu không force refresh
    if (!forceRefresh) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_prefKey);
        if (raw != null && raw.isNotEmpty) {
          final map = jsonDecode(raw);
          if (map is Map<String, dynamic>) {
            final info = HongguoDeviceInfo.fromJson(map);
            if (info.isValid) {
              return info;
            }
          }
        }
      } catch (e) {
        debugPrint('[HongguoDeviceService] Lỗi đọc cache device: $e');
      }
    }

    // 2. Gửi request đăng ký thiết bị mới với ByteDance
    try {
      final openUdid = _generateOpenUdid();
      const uuid = Uuid();
      final clientUdid = uuid.v4();

      final queryParams = {
        'aid': '8662',
        'app_name': 'novelread',
        'version_code': currentVersionCode,
        'version_name': currentVersionName,
        'device_platform': 'android',
        'os': 'android',
        'os_version': '14',
        'os_api': '34',
        'channel': 'update_64',
      };

      final payload = {
        'magic_tag': 'ss_app_log',
        'header': {
          'display_name': '红果免费短剧',
          'update_version_code': int.parse(currentVersionCode),
          'manifest_version_code': int.parse(currentVersionCode),
          'aid': 8662,
          'channel': 'update_64',
          'package': 'com.phoenix.read',
          'app_version': currentVersionName,
          'version_code': int.parse(currentVersionCode),
          'sdk_version': 'v04.04.05-ov-android',
          'os': 'Android',
          'os_version': '14',
          'os_api': 34,
          'device_model': '23117RK66C',
          'device_brand': 'Redmi',
          'device_manufacturer': 'Xiaomi',
          'cpu_abi': 'arm64-v8a',
          'resolution': '1440*3200',
          'dpi': 560,
          'density_dpi': 560,
          'language': 'zh',
          'timezone': 8,
          'access': 'wifi',
          'openudid': openUdid,
          'clientudid': clientUdid,
          'region': 'CN',
          'tz_name': 'Asia/Shanghai',
          'tz_offset': 28800,
        },
        '_gen_time': DateTime.now().millisecondsSinceEpoch,
      };

      final res = await _dio.post(
        registerEndpoint,
        queryParameters: queryParams,
        data: payload,
        options: Options(
          headers: {
            'Content-Type': 'application/json; charset=utf-8',
            'User-Agent':
                'com.phoenix.read/$currentVersionCode (Linux; U; Android 14; zh_CN; 23117RK66C; Build/UKQ1.230804.001; Cronet/TTNetVersion:53f56e9c 2024-03-25 QuicVersion:44383f5d 2024-02-27)',
          },
          responseType: ResponseType.json,
          validateStatus: (status) => status != null && status < 500,
        ),
      );


      final data = res.data is Map ? res.data as Map : <String, dynamic>{};
      final deviceIdStr =
          data['device_id_str']?.toString() ??
          data['device_id']?.toString() ??
          '';
      final installIdStr =
          data['install_id_str']?.toString() ??
          data['install_id']?.toString() ??
          '';
      final deviceToken = data['device_token']?.toString() ?? '';

      if (deviceIdStr.isNotEmpty &&
          installIdStr.isNotEmpty &&
          deviceIdStr != '0' &&
          installIdStr != '0') {
        final newInfo = HongguoDeviceInfo(
          deviceId: deviceIdStr,
          installId: installIdStr,
          deviceToken: deviceToken,
          registeredAtMs: DateTime.now().millisecondsSinceEpoch,
        );

        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_prefKey, jsonEncode(newInfo.toJson()));
        } catch (e) {
          debugPrint('[HongguoDeviceService] Lưu cache thất bại: $e');
        }

        debugPrint(
          '[HongguoDeviceService] Đăng ký thiết bị ByteDance thành công: device_id=$deviceIdStr, install_id=$installIdStr',
        );
        return newInfo;
      }
    } catch (e, st) {
      debugPrint('[HongguoDeviceService] Lỗi khi đăng ký thiết bị: $e\n$st');
    }

    // 3. Fallback về ID mặc định nếu đăng ký thất bại hoặc offline
    return const HongguoDeviceInfo(
      deviceId: HongguoSixgodSigner.defaultDeviceId,
      installId: HongguoSixgodSigner.defaultInstallId,
      deviceToken: '',
      registeredAtMs: 0,
    );
  }

  /// Xóa cache thiết bị hiện tại (khi server báo ID không hợp lệ)
  Future<void> invalidateDevice() async {
    _cachedInfo = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefKey);
    } catch (_) {}
  }
}
