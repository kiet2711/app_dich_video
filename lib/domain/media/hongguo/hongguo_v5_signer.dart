import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'hongguo_device_service.dart';
import 'hongguo_medusa_v5.dart';
import 'hongguo_sixgod_signer.dart';
import 'hongguo_v5_constants.dart';

/// Kết quả yêu cầu đã ký hoàn chỉnh (URL có `_rticket` chuẩn nhánh + headers).
class HongguoSignedV5Request {
  final String url;
  final Map<String, String> headers;
  final Uint8List? body;

  const HongguoSignedV5Request({
    required this.url,
    required this.headers,
    this.body,
  });
}

/// Bộ ký yêu cầu bổ sung giao thức v5 (`mobileV5`) và hỗ trợ body nhị phân gzip.
class HongguoV5Signer {
  HongguoV5Signer._();

  /// Ký request phát video mobile v5 (`/novel/player/multi_video_model/player/v1`).
  ///
  /// Đối chiếu `MobilePlayback.kt` & `Signer.signPlayback(..., mobileV5 = true)`:
  /// - Query KHÔNG mang `ts`, dùng `aid=8662`, `version_code=74332`, `PGT-AN10`,
  ///   và trượt `_rticket` tối đa 1024ms để `hashF13` rơi đúng nhánh `12`.
  /// - Giữ header tinh gọn: `User-Agent`, `Accept`, `Content-Encoding: gzip`,
  ///   `Content-Type`, `x-ss-stub`, `x-khronos`, `x-helios`, `x-medusa` (không gửi Cookie).
  static HongguoSignedV5Request signPlaybackV5({
    required String baseUrl,
    required HongguoDeviceInfo device,
    required Uint8List bodyBytes,
    int? nowMs,
    int? heliosRandom,
    int? medusaMessageRand,
    int? medusaNonceRand,
    int? medusaTailRand,
  }) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final ts = now ~/ 1000;

    final queryBase = <String, String>{
      ...HongguoV5Constants.v5PlaybackQueryDefaults,
      'iid': device.installId,
      'cdid': device.cdid.isNotEmpty
          ? device.cdid
          : '00000000-0000-4000-8000-000000000000',
      'device_id': device.deviceId,
    };

    for (var offset = 0; offset < 1024; offset++) {
      final ticket = now + offset;
      final queryParams = <String, String>{
        ...queryBase,
        '_rticket': ticket.toString(),
      };
      final queryStr = _encodeQuery(queryParams);
      if (!HongguoMedusaV5.isValidBranch(queryStr, bodyBytes, ts)) {
        continue;
      }

      final fullUrl = '$baseUrl?$queryStr';
      final stub = md5.convert(bodyBytes).toString().toUpperCase();
      final helios = HongguoMedusaV5.genHelios(
        ts: ts,
        randomVal: heliosRandom,
        license: HongguoV5Constants.license,
      );
      final medusa = HongguoMedusaV5.genMedusaV5(
        url: fullUrl,
        body: bodyBytes,
        ts: ts,
        deviceId: device.deviceId,
        channel: HongguoV5Constants.v5PlaybackQueryDefaults['channel']!,
        versionName: HongguoV5Constants.v5PlaybackQueryDefaults['version_name']!,
        osVersion: HongguoV5Constants.v5PlaybackQueryDefaults['os_version']!,
        deviceType: HongguoV5Constants.v5PlaybackQueryDefaults['device_type']!,
        processNonce: device.processNonce,
        processStartedMs: device.processStartedMs,
        messageRand: medusaMessageRand,
        nonceRand: medusaNonceRand,
        tailRand: medusaTailRand,
      );

      final headers = <String, String>{
        'User-Agent': HongguoV5Constants.playerUaV5,
        'Accept': 'application/json',
        'Accept-Encoding': 'gzip',
        'Content-Encoding': 'gzip',
        'Content-Type': 'application/json; charset=utf-8',
        'x-ss-stub': stub,
        'x-khronos': ts.toString(),
        'x-helios': helios,
        'x-medusa': medusa,
      };
      return HongguoSignedV5Request(
        url: fullUrl,
        headers: headers,
        body: bodyBytes,
      );
    }

    throw StateError('Không tìm được _rticket phù hợp cho nhánh F13 v5');
  }

  /// Ký request v3 (bọc `HongguoSixgodSigner.signRequest` với UA v3 + Cookie + Helios).
  static Map<String, String> signHeadersV3({
    required String baseUrl,
    Map<String, String> extraParams = const <String, String>{},
    dynamic body,
    HongguoDeviceInfo? device,
    bool playback = false,
    bool includeHelios = true,
  }) {
    final uri = Uri.parse(baseUrl);
    final mergedUrl = extraParams.isEmpty
        ? baseUrl
        : uri
            .replace(
              queryParameters: <String, String>{
                ...uri.queryParameters,
                ...extraParams,
              },
            )
            .toString();
    final signed = HongguoSixgodSigner.signRequest(
      url: mergedUrl,
      body: body ?? '',
      deviceId: device?.deviceId,
      installId: device?.installId,
      includeHelios: includeHelios,
    );
    final headers = <String, String>{
      ...signed.headers,
      'Accept-Encoding': 'gzip',
    };
    if (playback) {
      headers['user-agent'] = HongguoV5Constants.playerUa;
    } else if (body != null && body.toString().isNotEmpty) {
      headers['user-agent'] = HongguoV5Constants.videoUa;
    } else {
      headers['user-agent'] = HongguoV5Constants.appUa;
    }
    if (device != null && device.cookieHeader.isNotEmpty && !playback) {
      headers['cookie'] = device.cookieHeader;
    }
    return <String, String>{
      '_signedUrl': signed.signedUrl,
      ...headers,
    };
  }

  static String _encodeQuery(Map<String, String> params) {
    return params.entries
        .map((e) => '${_encodeComponent(e.key)}=${_encodeComponent(e.value)}')
        .join('&');
  }

  static String _encodeComponent(String value) {
    return Uri.encodeQueryComponent(value, encoding: utf8)
        .replaceAll('+', '%20')
        .replaceAll('%7E', '~');
  }
}
