import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'hongguo_sixgod_signer.dart';
import 'hongguo_v5_constants.dart';

/// Thông tin định danh thiết bị đã đăng ký với hệ thống Hongguo (ttEncrypt + device_register).
class HongguoDeviceInfo {
  final String deviceId;
  final String installId;
  final String cdid;
  final String openudid;
  final String deviceToken;
  final Map<String, String> cookies;
  final String processNonce;
  final int processStartedMs;
  final bool isRegistered;

  HongguoDeviceInfo({
    required this.deviceId,
    required this.installId,
    this.cdid = '',
    this.openudid = '',
    this.deviceToken = '',
    this.cookies = const <String, String>{},
    String? processNonce,
    int? processStartedMs,
    this.isRegistered = true,
  })  : processNonce = (processNonce != null && processNonce.isNotEmpty)
            ? processNonce
            : HongguoV5Constants.randomProcessNonce(),
        processStartedMs =
            processStartedMs ?? DateTime.now().millisecondsSinceEpoch;

  static final RegExp _validIdPattern = RegExp(r'^[1-9][0-9]{0,29}$');

  bool get isValid =>
      _validIdPattern.hasMatch(deviceId) && _validIdPattern.hasMatch(installId);

  /// Cookie header tối thiểu để gọi API nội dung khi cần (lọc từ `Set-Cookie` đăng ký).
  String get cookieHeader {
    if (cookies.isEmpty) return '';
    const allowed = <String>{
      'install_id',
      'ttreq',
      'store-region',
      'store-region-src',
    };
    final filtered = cookies.entries.where((e) => allowed.contains(e.key));
    final source = filtered.isNotEmpty ? filtered : cookies.entries;
    return source.map((e) => '${e.key}=${e.value}').join('; ');
  }

  HongguoDeviceInfo copyWith({
    String? deviceId,
    String? installId,
    String? cdid,
    String? openudid,
    String? deviceToken,
    Map<String, String>? cookies,
    String? processNonce,
    int? processStartedMs,
    bool? isRegistered,
  }) {
    return HongguoDeviceInfo(
      deviceId: deviceId ?? this.deviceId,
      installId: installId ?? this.installId,
      cdid: cdid ?? this.cdid,
      openudid: openudid ?? this.openudid,
      deviceToken: deviceToken ?? this.deviceToken,
      cookies: cookies ?? this.cookies,
      processNonce: processNonce ?? this.processNonce,
      processStartedMs: processStartedMs ?? this.processStartedMs,
      isRegistered: isRegistered ?? this.isRegistered,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'device_id': deviceId,
        'install_id': installId,
        'cdid': cdid,
        'openudid': openudid,
        'device_token': deviceToken,
        'cookies': cookies,
        'process_nonce': processNonce,
        'process_started_ms': processStartedMs,
        'is_registered': isRegistered,
      };

  factory HongguoDeviceInfo.fromJson(Map<String, dynamic> json) {
    final rawCookies = json['cookies'];
    final cookiesMap = <String, String>{};
    if (rawCookies is Map) {
      rawCookies.forEach((k, v) {
        final ks = k.toString();
        final vs = v?.toString() ?? '';
        if (ks.isNotEmpty && vs.isNotEmpty) {
          cookiesMap[ks] = vs;
        }
      });
    }
    return HongguoDeviceInfo(
      deviceId: json['device_id']?.toString() ?? '',
      installId: json['install_id']?.toString() ?? '',
      cdid: json['cdid']?.toString() ?? '',
      openudid: json['openudid']?.toString() ?? '',
      deviceToken: json['device_token']?.toString() ?? '',
      cookies: cookiesMap,
      processNonce: json['process_nonce']?.toString(),
      processStartedMs: (json['process_started_ms'] as num?)?.toInt(),
      isRegistered: json['is_registered'] as bool? ?? true,
    );
  }
}

/// Quản lý đăng ký thiết bị ẩn danh qua `ttEncrypt(gzip(JSON))` với `log5-applog-lf.fqnovel.com`.
///
/// Protocol đối chiếu từ `DeviceRegister.kt` & `PlaybackDeviceSession.kt` của hongguoTV:
/// - Body là binary nhị phân `ttEncrypt(gzip(JSON))` (tuyệt đối không encode base64).
/// - Không gửi header `Accept-Encoding: br` (chỉ dùng `gzip`).
/// - Không gắn chữ ký `x-gorgon` / `x-medusa` / `x-helios` / `ts` / `_rticket` lên request đăng ký.
class HongguoDeviceService {
  HongguoDeviceService._();
  static final HongguoDeviceService instance = HongguoDeviceService._();

  static const String _prefKey = 'hongguo_device_registered_info_v5';
  static const String registerHost = 'https://log5-applog-lf.fqnovel.com';
  static const String registerPath = '/service/2/device_register/';
  static const String registerQuery =
      '?tt_data=a&cronet_version=8d40f833_2026-03-03&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1';
  static String get registerUrl => '$registerHost$registerPath$registerQuery';

  static final List<int> _ttMagic = <int>[0x74, 0x63, 0x05, 0x10, 0x00, 0x00];
  static const Duration _rotationCooldown = Duration(minutes: 5);
  static const Uuid _uuid = Uuid();

  final Dio _defaultDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      validateStatus: (status) => status != null && status < 500,
    ),
  );

  Dio? _overrideDio;
  HongguoDeviceInfo? _cachedInfo;
  Future<HongguoDeviceInfo>? _inFlightRegistration;
  DateTime? _lastRotationAt;

  @visibleForTesting
  void setDioForTesting(Dio? dio) {
    _overrideDio = dio;
  }

  @visibleForTesting
  void resetForTesting() {
    _cachedInfo = null;
    _inFlightRegistration = null;
    _lastRotationAt = null;
    _overrideDio = null;
  }

  Dio get _dio => _overrideDio ?? _defaultDio;

  /// Mã hoá `ttEncrypt`:
  /// `MAGIC[6] || rnd[32] || AES-128-CBC(SHA512(SHA512(rnd) + KDF_SALT)[0..32], PKCS7(SHA512(data) || data))`
  static Uint8List ttEncrypt(Uint8List data, {Uint8List? random32}) {
    final Uint8List rnd;
    if (random32 != null) {
      if (random32.length != 32) {
        throw ArgumentError.value(random32.length, 'random32', 'Must be 32 bytes');
      }
      rnd = Uint8List.fromList(random32);
    } else {
      final rng = Random.secure();
      rnd = Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));
    }

    final rndSha = sha512.convert(rnd).bytes;
    final kdfInput = Uint8List(rndSha.length + HongguoV5Constants.ttEncryptKdfSalt.length);
    kdfInput.setAll(0, rndSha);
    kdfInput.setAll(rndSha.length, HongguoV5Constants.ttEncryptKdfSalt);
    final derived = Uint8List.fromList(sha512.convert(kdfInput).bytes);

    final aesKey = Uint8List.sublistView(derived, 0, 16);
    final aesIv = Uint8List.sublistView(derived, 16, 32);

    final dataSha = sha512.convert(data).bytes;
    final bodyLen = dataSha.length + data.length;
    final padding = 16 - (bodyLen % 16);
    final padded = Uint8List(bodyLen + padding);
    padded.setAll(0, dataSha);
    padded.setAll(dataSha.length, data);
    padded.fillRange(bodyLen, padded.length, padding);

    final cipher = CBCBlockCipher(AESEngine())
      ..init(
        true,
        ParametersWithIV(KeyParameter(aesKey), aesIv),
      );
    final encrypted = Uint8List(padded.length);
    for (var offset = 0; offset < padded.length; offset += 16) {
      cipher.processBlock(padded, offset, encrypted, offset);
    }

    final out = Uint8List(_ttMagic.length + rnd.length + encrypted.length);
    out.setAll(0, _ttMagic);
    out.setAll(_ttMagic.length, rnd);
    out.setAll(_ttMagic.length + rnd.length, encrypted);
    return out;
  }

  /// Tạo payload nhị phân `ttEncrypt(gzip(JSON))` cho `/service/2/device_register/`.
  static Uint8List buildRegisterPayload({
    required String cdid,
    required String openudid,
    int? nowMs,
    Map<String, String> overrides = const <String, String>{},
  }) {
    final tsMs = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    String val(String key, String fallback) {
      final v = overrides[key];
      return (v != null && v.isNotEmpty) ? v : fallback;
    }

    final jsonPayload = <String, dynamic>{
      'magic_tag': 'ss_app_log',
      'header': <String, dynamic>{
        'display_name': '红果免费短剧',
        'update_version_code': 73932,
        'manifest_version_code': 73932,
        'app_version_minor': '7.3.9.32',
        'aid': 8662,
        'channel': val('channel', '69310258a'),
        'package': 'com.phoenix.read',
        'app_version': '7.3.9.32',
        'version_code': 73932,
        'sdk_version': '3.7.0-rc.34-fanqie-xiaoshuo',
        'sdk_target_version': 29,
        'git_hash': '3a88f4e',
        'os': 'Android',
        'os_version': val('os_version', '12'),
        'os_api': int.tryParse(val('os_api', '32')) ?? 32,
        'device_model': val('device_type', 'PGT-AN10'),
        'device_brand': val('device_brand', 'HONOR'),
        'device_manufacturer': val('device_brand', 'HONOR'),
        'cpu_abi': val('host_abi', 'arm64-v8a'),
        'release_build': 'b5e187f',
        'density_dpi': int.tryParse(val('dpi', '360')) ?? 360,
        'display_density': 'mdpi',
        'resolution': val('resolution', '1440x2560').replaceAll('*', 'x'),
        'language': 'zh',
        'timezone': 8,
        'access': 'wifi',
        'not_request_sender': 0,
        'carrier': 'CHINA MOBILE',
        'mcc_mnc': '46000',
        'rom': 'eng.root.20231116.160340',
        'rom_version': val('rom_version', 'W528JS release-keys'),
        'cdid': cdid,
        'sig_hash': '56a962410c494bbaf0b58dba20cae56f',
        'openudid': openudid,
        'clientudid': _uuid.v4(),
        'ipv6_list': const <String>[],
        'region': 'CN',
        'tz_name': 'Asia/Shanghai',
        'tz_offset': 28800,
        'sim_region': 'cn',
        'sim_serial_number': const <String>[],
        'oaid_may_support': false,
        'req_id': _uuid.v4(),
        'device_platform': 'android',
        'custom': <String, dynamic>{
          'account_region_src': 'fallback',
          'host_bit': 64,
          'account_region': 'cn',
          'dragon_device_type': val('dragon_device_type', 'phone'),
        },
        'pre_installed_channel': '',
        'apk_first_install_time': tsMs,
        'is_system_app': 0,
        'sdk_flavor': 'china',
        'guest_mode': 0,
      },
      '_gen_time': tsMs,
    };

    final compressed = Uint8List.fromList(
      gzip.encode(utf8.encode(jsonEncode(jsonPayload))),
    );
    return ttEncrypt(compressed);
  }

  /// Header chuẩn cho `/service/2/device_register/` (không gắn chữ ký x-gorgon/x-medusa).
  static Map<String, String> buildRegisterHeaders(
    Uint8List body, {
    int? nowMs,
    String? userAgent,
  }) {
    final tsMs = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final stub = md5.convert(body).toString().toUpperCase();
    return <String, String>{
      'User-Agent': (userAgent != null && userAgent.isNotEmpty)
          ? userAgent
          : HongguoV5Constants.appUa,
      'Content-Type': 'application/octet-stream;tt-data=a',
      'log-encode-type': 'gzip',
      'Accept-Encoding': 'gzip',
      'x-ss-dp': '8662',
      'x-ss-req-ticket': tsMs.toString(),
      'x-vc-bdturing-sdk-version': '4.0.3.cn',
      'lc': '101',
      'sdk-version': '2',
      'passport-sdk-version': '5051452',
      'x-neptune': '-8|50:51:59:30:40:47:49:39',
      'x-ss-stub': stub,
    };
  }

  /// Parse JSON phản hồi + `Set-Cookie` từ endpoint đăng ký thiết bị.
  static HongguoDeviceInfo? parseRegisterResponse(
    String responseText, {
    List<String> setCookies = const <String>[],
    required String cdid,
    required String openudid,
  }) {
    dynamic decoded;
    try {
      decoded = jsonDecode(responseText);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;

    final deviceIdStr = _nonBlankString(decoded['device_id_str']) ??
        _nonBlankString(decoded['device_id']) ??
        '';
    final installIdStr = _nonBlankString(decoded['install_id_str']) ??
        _nonBlankString(decoded['install_id']) ??
        '';
    if (deviceIdStr.isEmpty ||
        installIdStr.isEmpty ||
        deviceIdStr == '0' ||
        installIdStr == '0') {
      return null;
    }

    final cookies = <String, String>{};
    for (final header in setCookies) {
      final firstPart = header.split(';').firstOrNull?.trim() ?? '';
      final eq = firstPart.indexOf('=');
      if (eq > 0) {
        final name = firstPart.substring(0, eq).trim();
        final value = firstPart.substring(eq + 1).trim();
        if (name.isNotEmpty && value.isNotEmpty) {
          cookies[name] = value;
        }
      }
    }

    final info = HongguoDeviceInfo(
      deviceId: deviceIdStr,
      installId: installIdStr,
      cdid: cdid,
      openudid: openudid,
      deviceToken: decoded['device_token']?.toString() ?? '',
      cookies: cookies,
      processNonce: HongguoV5Constants.randomProcessNonce(),
      processStartedMs: DateTime.now().millisecondsSinceEpoch,
      isRegistered: true,
    );
    return info.isValid ? info : null;
  }

  static String? _nonBlankString(dynamic value) {
    if (value == null) return null;
    final s = value.toString().trim();
    return s.isEmpty ? null : s;
  }

  /// Lấy thông tin thiết bị (ưu tiên bộ nhớ -> SharedPreferences -> đăng ký `ttEncrypt`).
  Future<HongguoDeviceInfo> getOrRegisterDevice({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _cachedInfo != null && _cachedInfo!.isValid) {
      return _cachedInfo!;
    }
    if (!forceRefresh && _inFlightRegistration != null) {
      return _inFlightRegistration!;
    }

    final future = _loadOrRegister(forceRefresh: forceRefresh);
    _inFlightRegistration = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlightRegistration, future)) {
        _inFlightRegistration = null;
      }
    }
  }

  /// Xoay danh tính thiết bị ẩn danh mới (có cooldown 5 phút chống spam).
  Future<bool> rotateDevice({
    HongguoDeviceInfo? expected,
    bool bypassCooldown = false,
  }) async {
    if (expected != null &&
        _cachedInfo != null &&
        _cachedInfo!.deviceId != expected.deviceId) {
      return true;
    }
    final now = DateTime.now();
    if (!bypassCooldown &&
        _lastRotationAt != null &&
        now.difference(_lastRotationAt!) < _rotationCooldown) {
      return false;
    }
    _lastRotationAt = now;
    try {
      final registered = await _registerWithServer();
      if (registered != null && registered.isValid) {
        _cachedInfo = registered;
        await _persist(registered);
        return true;
      }
    } catch (e) {
      debugPrint('[HongguoDeviceService] Xoay thiết bị thất bại: $e');
    }
    return false;
  }

  Future<void> clearCache() async {
    _cachedInfo = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefKey);
    } catch (_) {}
  }

  Future<HongguoDeviceInfo> _loadOrRegister({required bool forceRefresh}) async {
    if (!forceRefresh) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final cachedStr = prefs.getString(_prefKey);
        if (cachedStr != null && cachedStr.isNotEmpty) {
          final decoded = jsonDecode(cachedStr);
          if (decoded is Map<String, dynamic>) {
            final info = HongguoDeviceInfo.fromJson(decoded);
            if (info.isValid && info.cdid.isNotEmpty) {
              _cachedInfo = info;
              return info;
            }
          }
        }
      } catch (e) {
        debugPrint('[HongguoDeviceService] Lỗi đọc cache thiết bị: $e');
      }
    }

    final registered = await _registerWithServer();
    if (registered != null && registered.isValid) {
      _cachedInfo = registered;
      await _persist(registered);
      return registered;
    }

    // Fallback về danh tính mặc định nếu thiết bị offline hoàn toàn.
    final fallback = HongguoDeviceInfo(
      deviceId: HongguoSixgodSigner.defaultDeviceId,
      installId: HongguoSixgodSigner.defaultInstallId,
      cdid: _uuid.v4(),
      openudid: _generateOpenUdid(),
      isRegistered: false,
    );
    _cachedInfo = fallback;
    return fallback;
  }

  Future<HongguoDeviceInfo?> _registerWithServer() async {
    final cdid = _uuid.v4();
    final openudid = _generateOpenUdid();
    final body = buildRegisterPayload(cdid: cdid, openudid: openudid);
    final headers = buildRegisterHeaders(body);

    try {
      final response = await _dio.post<String>(
        registerUrl,
        data: Stream<List<int>>.fromIterable(<List<int>>[body]),
        options: Options(
          headers: <String, dynamic>{
            ...headers,
            Headers.contentLengthHeader: body.length,
          },
          responseType: ResponseType.plain,
        ),
      );
      final text = response.data ?? '';
      if (text.isEmpty) return null;
      final setCookies = response.headers['set-cookie'] ?? const <String>[];
      final info = parseRegisterResponse(
        text,
        setCookies: setCookies,
        cdid: cdid,
        openudid: openudid,
      );
      if (info != null) {
        debugPrint(
          '[HongguoDeviceService] Đăng ký ttEncrypt thành công: '
          'did=${info.deviceId}, iid=${info.installId}',
        );
      }
      return info;
    } catch (e) {
      debugPrint('[HongguoDeviceService] Đăng ký thiết bị lỗi: $e');
      return null;
    }
  }

  Future<void> _persist(HongguoDeviceInfo info) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, jsonEncode(info.toJson()));
    } catch (e) {
      debugPrint('[HongguoDeviceService] Lỗi lưu cache thiết bị: $e');
    }
  }

  static String _generateOpenUdid() {
    return _uuid.v4().replaceAll('-', '').substring(0, 16);
  }
}
