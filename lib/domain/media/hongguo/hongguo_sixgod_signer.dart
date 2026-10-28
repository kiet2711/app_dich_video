import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'hongguo_gorgon.dart';
import 'hongguo_helios.dart';
import 'hongguo_medusa.dart';
import 'hongguo_sm3.dart';

/// Kết quả ký request Sixgod
class SignedRequestResult {
  final String signedUrl;
  final Map<String, String> headers;
  final List<int> bodyBytes;

  const SignedRequestResult({
    required this.signedUrl,
    required this.headers,
    required this.bodyBytes,
  });
}

/// Trình ký request Sixgod / Medusa / Gorgon của ByteDance thuần Dart
class HongguoSixgodSigner {
  static const String userAgent =
      'com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; '
      'Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 '
      'QuicVersion:c67e9834 2025-09-08)';

  static const String defaultDeviceId = '3076883975276731';
  static const String defaultInstallId = '3076883975280827';
  static const String defaultDeviceBrand = 'Redmi';
  static const String defaultDeviceType = '25053RT47C';
  static const String defaultVersionName = '7.1.3.32';

  static final Random _secureRandom = Random.secure();

  /// Sinh ID thiết bị tạm thời giống app Windows tham chiếu.
  static String generateSyntheticId() {
    final high = _secureRandom.nextInt(1 << 24);
    final low = _secureRandom.nextInt(1 << 24);
    return (1000000000000000 + (high << 24) + low).toString();
  }

  static int _getIv(int iv, List<int> data) {
    var result = iv & 0xFFFFFFFF;
    for (var i = 0; i < data.length; i++) {
      if ((i & 1) == 0) {
        result =
            ((result >> 4) ^ result ^ (result << 6) ^ data[i]) & 0xFFFFFFFF;
      } else {
        result =
            (~((result >> 7) ^ result ^ (data[i] | (result << 12)))) &
            0xFFFFFFFF;
      }
    }
    return result;
  }

  /// Xác định nhánh F13 dùng để sinh X-Medusa.
  static int calculateSignatureBranch({
    required String query,
    required List<int> bodyBytes,
    required int khronos,
  }) {
    final querySm3 = HongguoSm3.hash(utf8.encode(query));
    final bodyMd5 = md5.convert(bodyBytes).bytes;
    final timestamp = ByteData(4)..setUint32(0, khronos, Endian.little);

    var iv = _getIv(0x20230928, querySm3);
    iv = _getIv(iv, bodyMd5);
    iv = _getIv(iv, timestamp.buffer.asUint8List());
    final low = iv & 15;
    return low - (((low * 171) >> 9) * 3);
  }

  /// Ký toàn bộ headers và URL theo chuẩn Sixgod engine
  static SignedRequestResult signRequest({
    required String url,
    required dynamic body,
    String? deviceId,
    String? installId,
  }) {
    final bodyJsonStr = jsonEncode(body);
    final bodyBytes = utf8.encode(bodyJsonStr);

    final uri = Uri.parse(url);
    final queryMap = Map<String, String>.from(uri.queryParameters);
    final effectiveDeviceId =
        (deviceId != null && deviceId.isNotEmpty) ? deviceId : defaultDeviceId;
    final effectiveInstallId =
        (installId != null && installId.isNotEmpty) ? installId : defaultInstallId;
    queryMap['iid'] = effectiveInstallId;
    queryMap['device_id'] = effectiveDeviceId;

    final now = DateTime.now().toUtc();
    final khronos = now.millisecondsSinceEpoch ~/ 1000;
    queryMap['ts'] = khronos.toString();

    // Server không nhận biến thể chữ ký Medusa branch 1. Dịch nhẹ
    // _rticket để toàn bộ URL/header được ký bằng branch 0 hoặc 2.
    final ticketBase = now.millisecondsSinceEpoch;
    var requestTicket = ticketBase;
    var encodedQuery = '';
    for (var offset = 0; offset < 32; offset++) {
      requestTicket = ticketBase + offset;
      queryMap['_rticket'] = requestTicket.toString();
      encodedQuery = queryMap.entries
          .map(
            (e) =>
                '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
          )
          .join('&');
      if (calculateSignatureBranch(
            query: encodedQuery,
            bodyBytes: bodyBytes,
            khronos: khronos,
          ) !=
          1) {
        break;
      }
    }
    if (calculateSignatureBranch(
          query: encodedQuery,
          bodyBytes: bodyBytes,
          khronos: khronos,
        ) ==
        1) {
      throw StateError('Không thể tạo chữ ký ByteDance hợp lệ');
    }

    final baseSignedUrl =
        '${uri.scheme}://${uri.host}${uri.path}?$encodedQuery';

    final xgRand = Random().nextInt(0xFFFF);

    final gorgon = HongguoGorgon.encryptGorgon(
      body: body,
      query: encodedQuery,
      khronos: khronos,
      xgRand: xgRand,
    );

    final helios = HongguoHelios.encryptHelios(khronos: khronos);

    final medusa = HongguoMedusa.genMedusa(
      query: encodedQuery,
      body: body,
      khronos: khronos,
      deviceId: effectiveDeviceId,
      versionName: defaultVersionName,
      deviceType: defaultDeviceType,
    );

    final stub = HongguoGorgon.calculateStub(body);

    final ladonBd = ByteData(4);
    ladonBd.setUint32(0, khronos, Endian.big);
    final ladon = base64Encode(ladonBd.buffer.asUint8List());

    final argusBd = ByteData(4);
    argusBd.setUint32(0, khronos, Endian.little);
    final argus = base64Encode(argusBd.buffer.asUint8List());

    final headers = <String, String>{
      'user-agent': userAgent,
      'accept': 'application/json; charset=utf-8,application/x-protobuf',
      'content-type': 'application/json; charset=UTF-8',
      'x-xs-from-web': '0',
      'x-ss-req-ticket': requestTicket.toString(),
      'x-tt-request-tag': 't=0;n=0',
      'sdk-version': '2',
      'passport-sdk-version': '50561',
      'x-vc-bdturing-sdk-version': '3.7.2.cn',
      'x-ladon': ladon,
      'x-khronos': khronos.toString(),
      'x-argus': argus,
      'x-gorgon': gorgon,
      'x-helios': helios,
      'x-medusa': medusa,
      if (stub.isNotEmpty) 'x-ss-stub': stub,
      'x-tt-dt': '',
    };

    return SignedRequestResult(
      signedUrl: baseSignedUrl,
      headers: headers,
      bodyBytes: bodyBytes,
    );
  }
}
