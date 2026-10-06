import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'hongguo_gorgon.dart';
import 'hongguo_helios.dart';
import 'hongguo_medusa.dart';

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

  /// Ký toàn bộ headers và URL theo chuẩn Sixgod engine
  static SignedRequestResult signRequest({
    required String url,
    required dynamic body,
    String deviceId = defaultDeviceId,
    String installId = defaultInstallId,
  }) {
    final bodyJsonStr = jsonEncode(body);
    final bodyBytes = utf8.encode(bodyJsonStr);

    final uri = Uri.parse(url);
    final queryMap = Map<String, String>.from(uri.queryParameters);

    final now = DateTime.now().toUtc();
    final khronos = now.millisecondsSinceEpoch ~/ 1000;
    final rTicket = now.millisecondsSinceEpoch;

    queryMap['ts'] = khronos.toString();
    queryMap['_rticket'] = rTicket.toString();

    // Tạo chuỗi query đã encode
    final encodedQuery = queryMap.entries
        .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');

    final baseSignedUrl = '${uri.scheme}://${uri.host}${uri.path}?$encodedQuery';

    final xgRand = Random().nextInt(0xFFFF);

    final gorgon = HongguoGorgon.encryptGorgon(
      body: body,
      query: encodedQuery,
      khronos: khronos,
      xgRand: xgRand,
    );

    final helios = HongguoHelios.encryptHelios(
      khronos: khronos,
    );

    final medusa = HongguoMedusa.genMedusa(
      query: encodedQuery,
      body: body,
      khronos: khronos,
      deviceId: deviceId,
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
      'x-ss-req-ticket': rTicket.toString(),
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
