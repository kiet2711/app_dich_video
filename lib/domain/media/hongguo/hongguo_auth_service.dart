import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'hongguo_device_service.dart';
import 'hongguo_gorgon.dart';
import 'hongguo_medusa.dart';
import 'hongguo_medusa_v5.dart';
import 'hongguo_v5_constants.dart';

/// Mã vùng quốc gia / khu vực hỗ trợ đăng nhập SMS Hồng Quả (55+ quốc gia, ưu tiên VN & CN).
class HongguoCountryCode {
  final String code;
  final String name;
  final String iso;

  const HongguoCountryCode(this.code, this.name, this.iso);
}

const List<HongguoCountryCode> kHongguoCountryCodes = <HongguoCountryCode>[
  HongguoCountryCode('84', 'Việt Nam (+84)', 'VN'),
  HongguoCountryCode('86', 'Trung Quốc (+86)', 'CN'),
  HongguoCountryCode('1', 'Hoa Kỳ / Canada (+1)', 'US'),
  HongguoCountryCode('886', 'Đài Loan (+886)', 'TW'),
  HongguoCountryCode('852', 'Hồng Kông (+852)', 'HK'),
  HongguoCountryCode('853', 'Ma Cao (+853)', 'MO'),
  HongguoCountryCode('82', 'Hàn Quốc (+82)', 'KR'),
  HongguoCountryCode('81', 'Nhật Bản (+81)', 'JP'),
  HongguoCountryCode('65', 'Singapore (+65)', 'SG'),
  HongguoCountryCode('66', 'Thái Lan (+66)', 'TH'),
  HongguoCountryCode('60', 'Malaysia (+60)', 'MY'),
  HongguoCountryCode('62', 'Indonesia (+62)', 'ID'),
  HongguoCountryCode('63', 'Philippines (+63)', 'PH'),
  HongguoCountryCode('855', 'Campuchia (+855)', 'KH'),
  HongguoCountryCode('856', 'Lào (+856)', 'LA'),
  HongguoCountryCode('95', 'Myanmar (+95)', 'MM'),
  HongguoCountryCode('61', 'Úc (+61)', 'AU'),
  HongguoCountryCode('64', 'New Zealand (+64)', 'NZ'),
  HongguoCountryCode('44', 'Vương quốc Anh (+44)', 'GB'),
  HongguoCountryCode('33', 'Pháp (+33)', 'FR'),
  HongguoCountryCode('49', 'Đức (+49)', 'DE'),
  HongguoCountryCode('39', 'Ý (+39)', 'IT'),
  HongguoCountryCode('34', 'Tây Ban Nha (+34)', 'ES'),
  HongguoCountryCode('31', 'Hà Lan (+31)', 'NL'),
  HongguoCountryCode('41', 'Thụy Sĩ (+41)', 'CH'),
  HongguoCountryCode('46', 'Thụy Điển (+46)', 'SE'),
  HongguoCountryCode('47', 'Na Uy (+47)', 'NO'),
  HongguoCountryCode('45', 'Đan Mạch (+45)', 'DK'),
  HongguoCountryCode('358', 'Phần Lan (+358)', 'FI'),
  HongguoCountryCode('32', 'Bỉ (+32)', 'BE'),
  HongguoCountryCode('43', 'Áo (+43)', 'AT'),
  HongguoCountryCode('351', 'Bồ Đào Nha (+351)', 'PT'),
  HongguoCountryCode('353', 'Ireland (+353)', 'IE'),
  HongguoCountryCode('48', 'Ba Lan (+48)', 'PL'),
  HongguoCountryCode('420', 'Séc (+420)', 'CZ'),
  HongguoCountryCode('36', 'Hungary (+36)', 'HU'),
  HongguoCountryCode('30', 'Hy Lạp (+30)', 'GR'),
  HongguoCountryCode('7', 'Nga / Kazakhstan (+7)', 'RU'),
  HongguoCountryCode('380', 'Ukraina (+380)', 'UA'),
  HongguoCountryCode('90', 'Thổ Nhĩ Kỳ (+90)', 'TR'),
  HongguoCountryCode('971', 'UAE (+971)', 'AE'),
  HongguoCountryCode('966', 'Ả Rập Xê Út (+966)', 'SA'),
  HongguoCountryCode('972', 'Israel (+972)', 'IL'),
  HongguoCountryCode('91', 'Ấn Độ (+91)', 'IN'),
  HongguoCountryCode('92', 'Pakistan (+92)', 'PK'),
  HongguoCountryCode('880', 'Bangladesh (+880)', 'BD'),
  HongguoCountryCode('94', 'Sri Lanka (+94)', 'LK'),
  HongguoCountryCode('977', 'Nepal (+977)', 'NP'),
  HongguoCountryCode('55', 'Brazil (+55)', 'BR'),
  HongguoCountryCode('52', 'Mexico (+52)', 'MX'),
  HongguoCountryCode('54', 'Argentina (+54)', 'AR'),
  HongguoCountryCode('56', 'Chile (+56)', 'CL'),
  HongguoCountryCode('57', 'Colombia (+57)', 'CO'),
  HongguoCountryCode('51', 'Peru (+51)', 'PE'),
  HongguoCountryCode('27', 'Nam Phi (+27)', 'ZA'),
  HongguoCountryCode('20', 'Ai Cập (+20)', 'EG'),
  HongguoCountryCode('234', 'Nigeria (+234)', 'NG'),
  HongguoCountryCode('254', 'Kenya (+254)', 'KE'),
];

class HongguoAuthException implements Exception {
  final String message;
  final int errorCode;
  final int retrySeconds;
  final bool canRetryCode;

  const HongguoAuthException(
    this.message, {
    this.errorCode = 0,
    this.retrySeconds = 0,
    this.canRetryCode = true,
  });

  @override
  String toString() => message;
}

class HongguoCaptchaRequiredException extends HongguoAuthException {
  const HongguoCaptchaRequiredException([
    super.message =
        'Yêu cầu xác minh bảo mật (trượt captcha). Vui lòng dùng tab Mã QR để quét bằng app Hồng Quả.',
  ]) : super(errorCode: 1105, canRetryCode: false);
}

class HongguoAccountNotProvisionedException extends HongguoAuthException {
  const HongguoAccountNotProvisionedException()
      : super(
          'Tài khoản đã đăng nhập nhưng chưa có hồ sơ Hồng Quả (biz_user_id trống). Hãy đăng nhập 1 lần trên app Hồng Quả chính thức để khởi tạo.',
        );
}

/// Thông tin đăng nhập tài khoản Hồng Quả được lưu an toàn bằng `FlutterSecureStorage`.
class HongguoAccountCredentials {
  final String cookie;
  final String deviceId;
  final String installId;
  final String userId;
  final String bizUserId;
  final String userName;
  final String avatarUrl;
  final String phoneMasked;

  const HongguoAccountCredentials({
    required this.cookie,
    this.deviceId = '',
    this.installId = '',
    this.userId = '',
    this.bizUserId = '',
    this.userName = '',
    this.avatarUrl = '',
    this.phoneMasked = '',
  });

  bool get isValid => cookie.trim().isNotEmpty;

  HongguoAccountCredentials copyWith({
    String? cookie,
    String? deviceId,
    String? installId,
    String? userId,
    String? bizUserId,
    String? userName,
    String? avatarUrl,
    String? phoneMasked,
  }) {
    return HongguoAccountCredentials(
      cookie: cookie ?? this.cookie,
      deviceId: deviceId ?? this.deviceId,
      installId: installId ?? this.installId,
      userId: userId ?? this.userId,
      bizUserId: bizUserId ?? this.bizUserId,
      userName: userName ?? this.userName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      phoneMasked: phoneMasked ?? this.phoneMasked,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'cookie': cookie,
        'deviceId': deviceId,
        'installId': installId,
        'userId': userId,
        'bizUserId': bizUserId,
        'userName': userName,
        'avatarUrl': avatarUrl,
        'phoneMasked': phoneMasked,
      };

  factory HongguoAccountCredentials.fromJson(Map<String, dynamic> json) {
    return HongguoAccountCredentials(
      cookie: json['cookie']?.toString() ?? '',
      deviceId: json['deviceId']?.toString() ?? '',
      installId: json['installId']?.toString() ?? '',
      userId: json['userId']?.toString() ?? '',
      bizUserId: json['bizUserId']?.toString() ?? '',
      userName: json['userName']?.toString() ?? '',
      avatarUrl: json['avatarUrl']?.toString() ?? '',
      phoneMasked: json['phoneMasked']?.toString() ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HongguoAccountCredentials &&
      other.cookie == cookie &&
      other.deviceId == deviceId &&
      other.installId == installId &&
      other.userId == userId;

  @override
  int get hashCode => Object.hash(cookie, deviceId, installId, userId);

  /// Tuyệt đối không rò rỉ cookie hoặc thông tin nhạy cảm vào logs.
  @override
  String toString() =>
      'HongguoAccountCredentials(user=$userId, name=$userName, valid=$isValid)';
}

/// Cổng chặn spam gửi SMS khi máy chủ trả `error_code = 7` hoặc `retry_time`.
class HongguoSmsRetryGate {
  final int Function() _clockMs;
  int _blockedUntilMs = 0;

  HongguoSmsRetryGate({int Function()? clockMs})
      : _clockMs = clockMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  int remainingSeconds() {
    final rem = _blockedUntilMs - _clockMs();
    if (rem <= 0) return 0;
    return (rem + 999) ~/ 1000;
  }

  void blockForSeconds(int seconds) {
    final sec = seconds.clamp(1, 3600);
    final target = _clockMs() + sec * 1000;
    if (target > _blockedUntilMs) _blockedUntilMs = target;
  }

  void ensureAllowed() {
    final rem = remainingSeconds();
    if (rem > 0) {
      throw HongguoAuthException(
        'Thao tác quá nhanh, vui lòng thử lại sau ${rem}s',
        errorCode: 7,
        retrySeconds: rem,
      );
    }
  }

  void reset() => _blockedUntilMs = 0;
}

class HongguoQrSession {
  final String token;
  final Uint8List qrImageBytes;
  final int expireSeconds;
  final String appScanUrl;
  final String dragonDeeplink;

  const HongguoQrSession({
    required this.token,
    required this.qrImageBytes,
    required this.expireSeconds,
    required this.appScanUrl,
    required this.dragonDeeplink,
  });
}

enum HongguoQrPollStatus {
  pending,
  scanned,
  confirmed,
  expired,
}

class HongguoQrPollResult {
  final HongguoQrPollStatus status;
  final HongguoAccountCredentials? credentials;

  const HongguoQrPollResult({
    required this.status,
    this.credentials,
  });
}

class HongguoSmsSendResult {
  final String maskedMobile;
  final int retrySeconds;
  final String mobileTicket;

  const HongguoSmsSendResult({
    required this.maskedMobile,
    required this.retrySeconds,
    required this.mobileTicket,
  });
}

/// Dịch vụ xác thực Hồng Quả (QR chính thức `hongguoduanju.com`, SMS App Passport `security.snssdk.com`,
/// và lưu trữ bảo mật `FlutterSecureStorage`).
class HongguoAuthService {
  HongguoAuthService._();
  static final HongguoAuthService instance = HongguoAuthService._();

  static const String webBase = 'https://hongguoduanju.com';
  static const String passportBase = 'https://security.snssdk.com';
  static const String webUa =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';
  static const String _storageKey = 'hongguo_account_credentials_v1';

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  // Phiên Cookie web & SMS hiện hành.
  final Map<String, String> _webCookies = <String, String>{};
  final Map<String, String> _passportCookies = <String, String>{};
  final HongguoSmsRetryGate smsRetryGate = HongguoSmsRetryGate();

  String _activeMobile = '';
  String _activeMobileTicket = '';
  bool _ticketInvalidated = false;

  HongguoAccountCredentials? _cachedCredentials;
  Dio? _overrideDio;
  final Dio _defaultDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 15),
      followRedirects: false,
      validateStatus: (status) => status != null && status < 500,
    ),
  );

  Dio get _dio => _overrideDio ?? _defaultDio;

  @visibleForTesting
  void setDioForTesting(Dio? dio) {
    _overrideDio = dio;
  }

  @visibleForTesting
  void resetForTesting() {
    _overrideDio = null;
    _cachedCredentials = null;
    _webCookies.clear();
    _passportCookies.clear();
    _activeMobile = '';
    _activeMobileTicket = '';
    _ticketInvalidated = false;
    smsRetryGate.reset();
  }

  /// Thuật toán mix_mode ByteDance web passport: XOR từng byte UTF-8 với `5` và encode hex.
  static String mix(String value) {
    final bytes = utf8.encode(value);
    return bytes.map((b) => ((b & 0xFF) ^ 5).toRadixString(16)).join();
  }

  /// Xây dựng liên kết deep-link mở trực tiếp app Hồng Quả (`dragon8662://webview?url=...`),
  /// khoá domain chặt chẽ chỉ cho phép URL quét mã chính thức của ByteDance/Hồng Quả.
  static String authorizationAppUrl(String rawUrl, String expectedToken) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty || expectedToken.isEmpty) return '';
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.userInfo.isNotEmpty) {
      return '';
    }
    final host = uri.host.toLowerCase();
    final isOfficialHost = host == 'reading.snssdk.com' ||
        host == 'hongguoduanju.com' ||
        host.endsWith('.hongguoduanju.com') ||
        host.endsWith('.fqnovel.com');
    if (!isOfficialHost) return '';
    if (!uri.path.endsWith('/scan-code.html')) return '';
    if (uri.queryParameters['token'] != expectedToken) return '';
    return 'dragon8662://webview?url=${Uri.encodeComponent(trimmed)}';
  }

  static bool _isAllowedRedirectHost(Uri uri) {
    if (uri.scheme.toLowerCase() != 'https' || uri.userInfo.isNotEmpty) {
      return false;
    }
    final h = uri.host.toLowerCase();
    return h == 'hongguoduanju.com' ||
        h.endsWith('.hongguoduanju.com') ||
        h == 'reading.snssdk.com' ||
        h.endsWith('.snssdk.com') ||
        h.endsWith('.fqnovel.com') ||
        h.endsWith('.bytedance.com');
  }

  /// Chuẩn hoá số điện thoại: TQ (+86) 11 số bỏ +86; quốc tế giữ `+<mã> <số>`.
  static String formatPhone(String countryCode, String rawPhone) {
    final cc = countryCode.replaceAll(RegExp(r'[^0-9]'), '');
    var digits = rawPhone.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) {
      throw ArgumentError('Vui lòng nhập số điện thoại');
    }
    if (cc == '86') {
      if (digits.startsWith('86') && digits.length > 11) {
        digits = digits.substring(2);
      }
      if (!RegExp(r'^1[3-9][0-9]{9}$').hasMatch(digits)) {
        throw ArgumentError('Số điện thoại Trung Quốc phải gồm đúng 11 chữ số');
      }
      return digits;
    }
    if (digits.startsWith(cc) && digits.length > cc.length + 5) {
      digits = digits.substring(cc.length);
    }
    if (digits.startsWith('0') && digits.length >= 9) {
      digits = digits.substring(1);
    }
    if (digits.length < 6 || digits.length > 15) {
      throw ArgumentError('Số điện thoại quốc tế không hợp lệ');
    }
    return '+$cc $digits';
  }

  // ==================== LƯU TRỮ BẢO MẬT ====================

  Future<HongguoAccountCredentials?> loadCredentials() async {
    if (_cachedCredentials != null && _cachedCredentials!.isValid) {
      return _cachedCredentials;
    }
    try {
      final raw = await _secureStorage.read(key: _storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          final creds = HongguoAccountCredentials.fromJson(decoded);
          if (creds.isValid) {
            _cachedCredentials = creds;
            return creds;
          }
        }
      }
    } on MissingPluginException {
      return _cachedCredentials;
    } catch (e) {
      debugPrint('[HongguoAuth] Lỗi đọc SecureStorage: $e');
    }
    return _cachedCredentials;
  }

  Future<void> saveCredentials(HongguoAccountCredentials credentials) async {
    _cachedCredentials = credentials;
    try {
      await _secureStorage.write(
        key: _storageKey,
        value: jsonEncode(credentials.toJson()),
      );
    } on MissingPluginException {
      // Bỏ qua an toàn trên môi trường test không có plugin native.
    } catch (e) {
      debugPrint('[HongguoAuth] Lỗi ghi SecureStorage: $e');
    }
  }

  Future<void> clearCredentials() async {
    _cachedCredentials = null;
    _webCookies.clear();
    _passportCookies.clear();
    try {
      await _secureStorage.delete(key: _storageKey);
    } on MissingPluginException {
      // ignore in unit test
    } catch (_) {}
  }

  // ==================== KÊNH 1: MÃ QR CHÍNH THỨC ====================

  /// Lấy mã QR đăng nhập chính thức từ `hongguoduanju.com`.
  Future<HongguoQrSession> fetchQrCode() async {
    _webCookies.clear();
    final data = await _webCall(
      '/passport/web/get_qrcode/',
      query: const <String, String>{'next': '$webBase/'},
    );
    final token = data['token']?.toString() ?? '';
    var qrRaw = data['qrcode']?.toString() ?? '';
    final b64Idx = qrRaw.indexOf('base64,');
    if (b64Idx >= 0) qrRaw = qrRaw.substring(b64Idx + 7);
    if (token.isEmpty || qrRaw.isEmpty) {
      throw const HongguoAuthException('Không lấy được dữ liệu mã QR Hồng Quả');
    }
    final expireSec = (data['expire_time'] as num?)?.toInt() ?? 180;
    final scanUrl = data['scan_url']?.toString() ??
        'https://reading.snssdk.com/reading_offline/novelread/page/scan-code.html?token=${Uri.encodeQueryComponent(token)}&qr_source_aid=513755';
    final deeplink = authorizationAppUrl(scanUrl, token);

    return HongguoQrSession(
      token: token,
      qrImageBytes: base64Decode(qrRaw),
      expireSeconds: expireSec,
      appScanUrl: scanUrl,
      dragonDeeplink: deeplink,
    );
  }

  /// Kiểm tra trạng thái quét QR; tự hoàn tất redirect & lưu credential khi xác nhận.
  Future<HongguoQrPollResult> pollQrStatus(String token) async {
    final data = await _webCall(
      '/passport/web/check_qrconnect/',
      query: <String, String>{
        'next': '$webBase/',
        'token': token,
      },
    );
    final status = data['status']?.toString() ?? '';
    if (status == '5' || status == 'expired') {
      throw const HongguoAuthException('Mã QR đã hết hạn, vui lòng tạo mã mới');
    }
    if (status == '2' || status == 'scanned') {
      return const HongguoQrPollResult(status: HongguoQrPollStatus.scanned);
    }
    if (status == '3' || status == 'confirmed') {
      final redirect = data['redirect_url']?.toString() ?? '';
      if (redirect.isNotEmpty) {
        await _finishOfficialRedirect(redirect);
      }
      final info = await _webCall('/passport/account/info/v2/');
      final creds = await _buildCredentialsFromCookies(
        _webCookies,
        userInfo: info,
      );
      await saveCredentials(creds);
      return HongguoQrPollResult(
        status: HongguoQrPollStatus.confirmed,
        credentials: creds,
      );
    }
    return const HongguoQrPollResult(status: HongguoQrPollStatus.pending);
  }

  Future<void> _finishOfficialRedirect(String redirectUrl) async {
    final rawUri = Uri.tryParse(redirectUrl);
    if (rawUri == null) {
      throw const HongguoAuthException('URL chuyển hướng không hợp lệ');
    }
    final Uri resolved;
    if (!rawUri.hasScheme && redirectUrl.startsWith('/')) {
      resolved = Uri.parse('$webBase$redirectUrl');
    } else {
      if (!_isAllowedRedirectHost(rawUri)) {
        throw const HongguoAuthException(
          'Từ chối chuyển hướng ngoài hệ thống ByteDance',
        );
      }
      resolved = rawUri;
    }
    final res = await _dio.get<String>(
      resolved.toString(),
      options: Options(
        headers: _webHeaders(),
        responseType: ResponseType.plain,
      ),
    );
    _captureCookies(_webCookies, res.headers['set-cookie']);
  }

  Future<Map<String, dynamic>> _webCall(
    String path, {
    Map<String, String> query = const <String, String>{},
    Map<String, String>? formBody,
  }) async {
    final fullQuery = <String, String>{
      'aid': '513755',
      'passport_jssdk_version': '3.4.10',
      'passport_jssdk_type': 'normal',
      ...query,
    };
    final uri = Uri.parse('$webBase$path').replace(queryParameters: fullQuery);
    final headers = _webHeaders();
    final csrf = _webCookies['passport_csrf_token'];
    if (csrf != null && csrf.isNotEmpty) {
      headers['x-tt-passport-csrf-token'] = csrf;
    }

    final Response<String> res;
    if (formBody != null) {
      res = await _dio.post<String>(
        uri.toString(),
        data: formBody,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: headers,
          responseType: ResponseType.plain,
        ),
      );
    } else {
      res = await _dio.get<String>(
        uri.toString(),
        options: Options(headers: headers, responseType: ResponseType.plain),
      );
    }
    _captureCookies(_webCookies, res.headers['set-cookie']);
    return _unwrapPassportReply(res.data ?? '');
  }

  Map<String, String> _webHeaders() {
    final headers = <String, String>{
      'User-Agent': webUa,
      'Referer': '$webBase/',
      'Origin': webBase,
      'Accept': 'application/json',
      'Accept-Encoding': 'gzip',
    };
    if (_webCookies.isNotEmpty) {
      headers['Cookie'] =
          _webCookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    }
    return headers;
  }

  // ==================== KÊNH 2: ĐĂNG NHẬP SMS ĐIỆN THOẠI ====================

  /// Gửi mã OTP SMS tới số điện thoại (dùng kênh App Passport `security.snssdk.com`).
  Future<HongguoSmsSendResult> sendSmsCode(
    String countryCode,
    String rawPhone,
  ) async {
    smsRetryGate.ensureAllowed();
    final formatted = formatPhone(countryCode, rawPhone);
    _activeMobile = formatted;
    _activeMobileTicket = '';
    _ticketInvalidated = false;

    final reply = await _passportCall(
      '/passport/mobile/send_code/v1/',
      <String, String>{
        'mobile': formatted,
        'type': '24',
      },
      useFormPost: false,
    );

    final data = _extractDataMap(reply);
    if (_isSliderChallenge(reply, data)) {
      throw const HongguoCaptchaRequiredException();
    }

    final ticket = data['mobile_ticket']?.toString() ?? '';
    final retrySec = (data['retry_time'] as num?)?.toInt() ?? 60;
    final masked = data['mobile']?.toString() ?? formatted;
    if (ticket.isNotEmpty) {
      _activeMobileTicket = ticket;
    }
    return HongguoSmsSendResult(
      maskedMobile: masked,
      retrySeconds: retrySec,
      mobileTicket: ticket,
    );
  }

  static const List<({String path, bool form})> _verifyAttempts =
      <({String path, bool form})>[
    (path: '/passport/mobile/sms_login/', form: true),
    (path: '/passport/mobile/sms_login_only/', form: true),
    (path: '/passport/mobile/sms_login_continue/', form: true),
    (path: '/passport/mobile/validate_code/v1/', form: false),
    (path: '/passport/mobile/validate_code/v1/', form: true),
  ];

  /// Xác minh mã OTP 4-6 số để lấy `sessionid` và lưu vào SecureStorage.
  Future<HongguoAccountCredentials> verifySmsCode(String rawCode) async {
    smsRetryGate.ensureAllowed();
    if (_ticketInvalidated) {
      throw const HongguoAuthException(
        'Phiên OTP đã hết hạn hoặc nhập sai quá số lần, vui lòng gửi lại mã mới',
      );
    }
    final code = rawCode.trim();
    if (code.isEmpty || _activeMobile.isEmpty) {
      throw const HongguoAuthException('Vui lòng gửi mã OTP và nhập mã xác nhận');
    }

    final params = <String, String>{
      'mobile': _activeMobile,
      'code': code,
      'type': '24',
      if (_activeMobileTicket.isNotEmpty) 'mobile_ticket': _activeMobileTicket,
    };

    HongguoAuthException? lastError;
    for (final attempt in _verifyAttempts) {
      try {
        await _passportCall(attempt.path, params, useFormPost: attempt.form);
        if (_hasSessionCookie(_passportCookies)) {
          break;
        }
      } on HongguoAuthException catch (e) {
        if (e.errorCode == 7) {
          smsRetryGate.blockForSeconds(e.retrySeconds > 0 ? e.retrySeconds : 60);
          rethrow;
        }
        if (e.errorCode == 1102) {
          // Sai mã OTP: dừng ngay, không lặp tiếp tránh mất lượt.
          rethrow;
        }
        if (e.errorCode == 1203) {
          _ticketInvalidated = true;
          rethrow;
        }
        lastError = e;
        if (_hasSessionCookie(_passportCookies)) break;
        // error_code == 1 (hết hạn / endpoint không hợp lệ) -> thử endpoint kế tiếp mà không khóa ticket.
      }
    }

    if (!_hasSessionCookie(_passportCookies)) {
      throw lastError ??
          const HongguoAuthException(
            'Đăng nhập thất bại: không nhận được phiên đăng nhập',
          );
    }

    final creds = await _buildCredentialsFromCookies(
      _passportCookies,
      phoneMasked: _activeMobile,
    );
    await saveCredentials(creds);
    return creds;
  }

  /// Thử gửi SMS qua kênh web (`hongguoduanju.com`) theo giao thức dự phòng.
  Future<void> sendWebSmsCode(String countryCode, String rawPhone) async {
    smsRetryGate.ensureAllowed();
    if (_webCookies['passport_csrf_token'] == null) {
      await fetchQrCode();
    }
    final formatted = formatPhone(countryCode, rawPhone);
    final cc = countryCode.replaceAll(RegExp(r'[^0-9]'), '');
    final webMobile = formatted.startsWith('+') ? formatted : '+$cc $formatted';
    await _webCall(
      '/passport/web/send_code/',
      formBody: <String, String>{
        'mobile': mix(webMobile),
        'type': mix('24'),
        'mix_mode': '1',
      },
    );
  }

  Future<Map<String, dynamic>> _passportCall(
    String path,
    Map<String, String> params, {
    required bool useFormPost,
  }) async {
    final device = await HongguoDeviceService.instance.getOrRegisterDevice();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final ts = nowMs ~/ 1000;

    final cleanQuery = <String, String>{
      'aid': '8662',
      'app_name': 'novelread',
      'device_platform': 'android',
      if (!useFormPost)
        ...params.entries
            .where((e) => e.value.isNotEmpty)
            .fold<Map<String, String>>(
              <String, String>{},
              (m, e) => m..[e.key] = e.value,
            ),
      '_rticket': nowMs.toString(),
    };

    final encodedQuery = cleanQuery.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    final signedUrl = '$passportBase$path?$encodedQuery';
    final formEncoded = useFormPost
        ? params.entries
            .where((e) => e.value.isNotEmpty)
            .map(
              (e) =>
                  '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
            )
            .join('&')
        : null;
    final bodyBytes = formEncoded != null ? utf8.encode(formEncoded) : null;

    final helios = HongguoMedusaV5.genHelios(
      ts: ts,
      license: HongguoV5Constants.legacyLicense,
    );
    final gorgon = HongguoGorgon.encryptGorgon(
      query: encodedQuery,
      body: formEncoded ?? '',
      khronos: ts,
      xgRand: nowMs & 0xFFFF,
    );
    final medusa = HongguoMedusa.genMedusa(
      query: encodedQuery,
      body: formEncoded ?? '',
      khronos: ts,
      deviceId: device.deviceId,
      versionName: '7.1.3.32',
      deviceType: '25053RT47C',
    );

    final headers = <String, String>{
      'User-Agent': HongguoV5Constants.appUa,
      'Accept': 'application/json',
      'Accept-Encoding': 'gzip',
      'x-khronos': ts.toString(),
      'x-helios': helios,
      'x-gorgon': gorgon,
      'x-medusa': medusa,
      'sdk-version': '2',
      'passport-sdk-version': '50561',
      if (bodyBytes != null)
        'x-ss-stub': HongguoGorgon.calculateStub(formEncoded),
      if (_passportCookies.isNotEmpty)
        'Cookie': _passportCookies.entries
            .map((e) => '${e.key}=${e.value}')
            .join('; '),
    };

    final Response<String> res;
    if (useFormPost) {
      res = await _dio.post<String>(
        signedUrl,
        data: formEncoded,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: headers,
          responseType: ResponseType.plain,
        ),
      );
    } else {
      res = await _dio.get<String>(
        signedUrl,
        options: Options(headers: headers, responseType: ResponseType.plain),
      );
    }

    _captureCookies(_passportCookies, res.headers['set-cookie']);
    return _unwrapPassportReply(res.data ?? '', checkSmsErrors: true);
  }

  Map<String, dynamic> _unwrapPassportReply(
    String rawText, {
    bool checkSmsErrors = false,
  }) {
    if (rawText.trim().isEmpty) {
      throw const HongguoAuthException('Cổng đăng nhập trả về phản hồi rỗng');
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(rawText);
    } catch (_) {
      throw const HongguoAuthException('Phản hồi đăng nhập không hợp lệ');
    }
    if (decoded is! Map) {
      throw const HongguoAuthException('Định dạng phản hồi không đúng');
    }
    final root = Map<String, dynamic>.from(decoded);
    final data = _extractDataMap(root);

    if (_isSliderChallenge(root, data)) {
      throw const HongguoCaptchaRequiredException();
    }

    final message = root['message']?.toString().toLowerCase() ?? '';
    final errCode = (data['error_code'] as num?)?.toInt() ??
        (root['error_code'] as num?)?.toInt() ??
        0;
    if (message == 'error' || errCode != 0) {
      final desc = data['description']?.toString().isNotEmpty == true
          ? data['description'].toString()
          : (root['description']?.toString() ?? 'Lỗi xác thực ($errCode)');
      final retrySec = (data['retry_time'] as num?)?.toInt() ?? 60;
      if (errCode == 7 && checkSmsErrors) {
        smsRetryGate.blockForSeconds(retrySec);
      }
      if (errCode == 1105) {
        throw HongguoCaptchaRequiredException(desc);
      }
      throw HongguoAuthException(
        desc,
        errorCode: errCode,
        retrySeconds: retrySec,
        canRetryCode: errCode != 1 && errCode != 1203,
      );
    }
    return data.isNotEmpty ? data : root;
  }

  static Map<String, dynamic> _extractDataMap(Map<String, dynamic> root) {
    final d = root['data'];
    return d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
  }

  static bool _isSliderChallenge(
    Map<String, dynamic> root,
    Map<String, dynamic> data,
  ) {
    final conf = data['verify_center_decision_conf']?.toString() ?? '';
    final code = (data['error_code'] as num?)?.toInt() ??
        (root['error_code'] as num?)?.toInt() ??
        0;
    return conf.isNotEmpty || code == 1105;
  }

  static bool _hasSessionCookie(Map<String, String> jar) {
    return (jar['sessionid']?.isNotEmpty ?? false) ||
        (jar['sessionid_ss']?.isNotEmpty ?? false);
  }

  static void _captureCookies(
    Map<String, String> jar,
    List<String>? setCookieHeaders,
  ) {
    if (setCookieHeaders == null) return;
    for (final header in setCookieHeaders) {
      final first = header.split(';').firstOrNull?.trim() ?? '';
      final eq = first.indexOf('=');
      if (eq > 0) {
        final name = first.substring(0, eq).trim();
        final value = first.substring(eq + 1).trim();
        if (name.isNotEmpty && value.isNotEmpty) {
          jar[name] = value;
        }
      }
    }
  }

  Future<HongguoAccountCredentials> _buildCredentialsFromCookies(
    Map<String, String> jar, {
    Map<String, dynamic>? userInfo,
    String phoneMasked = '',
  }) async {
    final device = await HongguoDeviceService.instance.getOrRegisterDevice();
    final cookieHeader = jar.entries
        .where(
          (e) => const <String>{
            'sessionid',
            'sessionid_ss',
            'sid_tt',
            'uid_tt',
            'sid_guard',
            'install_id',
          }.contains(e.key),
        )
        .map((e) => '${e.key}=${e.value}')
        .join('; ');

    final fallbackCookie = cookieHeader.isNotEmpty
        ? cookieHeader
        : jar.entries.map((e) => '${e.key}=${e.value}').join('; ');

    return HongguoAccountCredentials(
      cookie: fallbackCookie,
      deviceId: device.deviceId,
      installId: device.installId,
      userId: userInfo?['user_id']?.toString() ??
          jar['uid_tt']?.toString() ??
          '',
      userName: userInfo?['name']?.toString() ??
          userInfo?['screen_name']?.toString() ??
          '',
      avatarUrl: userInfo?['avatar_url']?.toString() ?? '',
      phoneMasked: phoneMasked,
    );
  }
}
