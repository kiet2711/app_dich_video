import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Chứa thông tin danh tính thiết bị ByteDance đã được cấp phát
class HongguoDeviceInfo {
  final String deviceId;
  final String installId;
  final String deviceToken;
  final String ttreq;
  final int serverTime;
  final int registeredAtMs;
  final String versionCode;
  final String versionName;
  final String openUdid;
  final String clientUdid;

  const HongguoDeviceInfo({
    required this.deviceId,
    required this.installId,
    required this.deviceToken,
    this.ttreq = '',
    required this.serverTime,
    required this.registeredAtMs,
    required this.versionCode,
    required this.versionName,
    required this.openUdid,
    required this.clientUdid,
  });

  bool get isValid => deviceId.isNotEmpty && installId.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'install_id': installId,
        'device_token': deviceToken,
        'ttreq': ttreq,
        'server_time': serverTime,
        'registered_at_ms': registeredAtMs,
        'version_code': versionCode,
        'version_name': versionName,
        'open_udid': openUdid,
        'client_udid': clientUdid,
      };

  factory HongguoDeviceInfo.fromJson(Map<String, dynamic> json) {
    return HongguoDeviceInfo(
      deviceId: json['device_id']?.toString() ?? '',
      installId: json['install_id']?.toString() ?? '',
      deviceToken: json['device_token']?.toString() ?? '',
      ttreq: json['ttreq']?.toString() ?? '',
      serverTime: (json['server_time'] as num?)?.toInt() ?? 0,
      registeredAtMs: (json['registered_at_ms'] as num?)?.toInt() ?? 0,
      versionCode: json['version_code']?.toString() ?? '73732',
      versionName: json['version_name']?.toString() ?? '7.3.7.32',
      openUdid: json['open_udid']?.toString() ?? '',
      clientUdid: json['client_udid']?.toString() ?? '',
    );
  }
}

/// Dịch vụ tự động đăng ký và quản lý thiết bị thật với ByteDance Device Register API
class HongguoDeviceService {
  HongguoDeviceService._();
  static final HongguoDeviceService instance = HongguoDeviceService._();

  static const String _prefKey = 'hongguo_device_registered_info';
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

  /// Tạo ngẫu nhiên OpenUDID (chuỗi hex 16 ký tự)
  static String _generateOpenUdid() {
    final rand = Random();
    final chars = '0123456789abcdef';
    return List.generate(16, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  /// Lấy hoặc tự động đăng ký danh tính thiết bị mới từ ByteDance
  Future<HongguoDeviceInfo> getOrRegisterDevice({bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedInfo != null && _cachedInfo!.isValid) {
      return _cachedInfo!;
    }

    // 1. Kiểm tra SharedPreferences nếu không ép buộc làm mới
    if (!forceRefresh) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_prefKey);
        if (raw != null && raw.isNotEmpty) {
          final map = jsonDecode(raw);
          if (map is Map<String, dynamic>) {
            final info = HongguoDeviceInfo.fromJson(map);
            final now = DateTime.now().millisecondsSinceEpoch;
            // Phiên đăng ký hợp lệ trong vòng 5 ngày
            if (info.isValid && (now - info.registeredAtMs) < 5 * 24 * 3600 * 1000) {
              _cachedInfo = info;
              return info;
            }
          }
        }
      } catch (e) {
        debugPrint('[HongguoDeviceService] Lỗi đọc cache device: $e');
      }
    }

    // 2. Tự động gửi request đăng ký thiết bị mới với ByteDance
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
      final deviceIdStr = data['device_id_str']?.toString() ??
          data['device_id']?.toString() ??
          '';
      final installIdStr = data['install_id_str']?.toString() ??
          data['install_id']?.toString() ??
          '';
      final deviceToken = data['device_token']?.toString() ?? '';
      final serverTime = (data['server_time'] as num?)?.toInt() ?? 0;

      // Trích xuất ttreq cookie từ headers nếu có
      var ttreq = '';
      final setCookies = res.headers['set-cookie'] ?? [];
      for (final c in setCookies) {
        final match = RegExp(r'ttreq=([^;]+)').firstMatch(c);
        if (match != null) {
          ttreq = match.group(1)!;
          break;
        }
      }

      if (deviceIdStr.isNotEmpty && installIdStr.isNotEmpty) {
        final newInfo = HongguoDeviceInfo(
          deviceId: deviceIdStr,
          installId: installIdStr,
          deviceToken: deviceToken,
          ttreq: ttreq,
          serverTime: serverTime,
          registeredAtMs: DateTime.now().millisecondsSinceEpoch,
          versionCode: currentVersionCode,
          versionName: currentVersionName,
          openUdid: openUdid,
          clientUdid: clientUdid,
        );

        _cachedInfo = newInfo;
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
    } catch (e) {
      debugPrint('[HongguoDeviceService] Lỗi khi đăng ký thiết bị: $e');
    }

    // Fallback nếu không gọi được mạng
    return _cachedInfo ??
        const HongguoDeviceInfo(
          deviceId: '3076883975276731',
          installId: '3076883975280827',
          deviceToken: '',
          serverTime: 0,
          registeredAtMs: 0,
          versionCode: '71332',
          versionName: '7.1.3.32',
          openUdid: '',
          clientUdid: '',
        );
  }
}
