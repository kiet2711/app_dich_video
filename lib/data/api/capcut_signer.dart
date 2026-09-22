import 'dart:convert';

import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:pointycastle/export.dart';

import '../model/device_config.dart';

class CapCutSigner {
  static const String vodRegion = 'sdwdmwlll';
  static const String vodService = 'vod';
  static const String baseUrl = 'https://editor-api-sg.capcutapi.com';

  static const String ttsSignPublicKeyPem = """-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAmTd34Lw4b7IuldSXh/zY
CMla+ITdGG5TeWz6ad+OySd4r+IrY45AoqrYUxhQ2dl+7z+i7r/5vEa8rr39BYfB
8AGMQLmZA8HmgpWBsqrn/V6daUALkKnkLb70Fn32CJigIuGXAYqxUdGuI340aC+0
v5Es3puJsHyzf01/AelE4Cdc6bZhQrASJLBh8R3BQToYClmDVSDUQk28o8sl/guA
Z4n303Vj+6Siv1HayPCdV6kpVVnMBAG4+umUbwGmn132N3fgpzLarFF3XyWmS1zh
D/J07iM/rP8GDO9IskHNHd2phrO0G6KzrcFAnTBHjVv+hCBEfzN/no3FNA9AuC36
mwIDAQAB
-----END PUBLIC KEY-----""";

  static String md5String(String input) {
    return md5Bytes(utf8.encode(input));
  }

  static String md5Bytes(List<int> bytes) {
    return crypto.md5.convert(bytes).toString();
  }

  static String sha256Hex(List<int> data) {
    return crypto.sha256.convert(data).toString();
  }

  static List<int> hmacSha256(List<int> key, List<int> data) {
    final hmac = crypto.Hmac(crypto.sha256, key);
    return hmac.convert(data).bytes;
  }

  static String makeSignHeader(
    String url,
    String appvr,
    String deviceTime,
    String tdid,
  ) {
    final path = url.split('?')[0];
    final pathSuffix = path.length >= 7
        ? path.substring(path.length - 7)
        : path;
    final signStr = '9e2c|$pathSuffix|3|$appvr|$deviceTime|$tdid|11ac';
    return md5String(signStr);
  }

  static String makeSsStub(String bodyText) {
    return md5String(bodyText);
  }

  static String makeTraceId() {
    final seed = const Uuid().v4().replaceAll('-', '').substring(0, 32);
    return '00-$seed-${seed.substring(0, 16)}-01';
  }

  /// Bảng tra cứu CRC32 chuẩn IEEE 802.3
  static final List<int> _crcTable = () {
    final table = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table[i] = c;
    }
    return table;
  }();

  static String crc32Hex(List<int> data) {
    var crc = 0xFFFFFFFF;
    for (final b in data) {
      crc = (crc >>> 8) ^ _crcTable[(crc ^ b) & 0xFF];
    }
    crc = (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
    return crc.toRadixString(16).padLeft(8, '0');
  }

  static Map<String, String> getUtcDatesForVod() {
    final now = DateTime.now().toUtc();
    final isoFormat = DateFormat("yyyyMMdd'T'HHmmss'Z'");
    final httpFormat = DateFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'", 'en_US');
    return {'iso': isoFormat.format(now), 'http': httpFormat.format(now)};
  }

  static List<int> _aws4SigningKey(
    String secretAccessKey,
    String dateStamp, {
    String region = vodRegion,
    String service = vodService,
  }) {
    final kDate = hmacSha256(
      utf8.encode('AWS4$secretAccessKey'),
      utf8.encode(dateStamp),
    );
    final kRegion = hmacSha256(kDate, utf8.encode(region));
    final kService = hmacSha256(kRegion, utf8.encode(service));
    return hmacSha256(kService, utf8.encode('aws4_request'));
  }

  static String _canonicalQuery(String urlStr) {
    final uri = Uri.parse(urlStr);
    if (!uri.hasQuery) return '';
    final queryParams = uri.queryParametersAll.entries.toList();
    queryParams.sort((a, b) => a.key.compareTo(b.key));

    final pairs = <String>[];
    for (final entry in queryParams) {
      for (final value in entry.value) {
        pairs.add(
          '${Uri.encodeComponent(entry.key)}=${Uri.encodeComponent(value)}',
        );
      }
    }
    return pairs.join('&');
  }

  static String aws4Authorization({
    required String method,
    required String url,
    required List<int> body,
    required String accessKeyId,
    required String secretAccessKey,
    required String sessionToken,
    required String amzDate,
  }) {
    final dateStamp = amzDate.substring(0, 8);
    final scope = '$dateStamp/$vodRegion/$vodService/aws4_request';
    final signedHeaders = 'x-amz-date;x-amz-security-token';
    final canonicalHeaders =
        'x-amz-date:$amzDate\nx-amz-security-token:$sessionToken\n';
    final uri = Uri.parse(url);
    final path = uri.path;

    final canonicalRequest = [
      method,
      path,
      _canonicalQuery(url),
      canonicalHeaders,
      signedHeaders,
      sha256Hex(body),
    ].join('\n');

    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      scope,
      sha256Hex(utf8.encode(canonicalRequest)),
    ].join('\n');

    final signingKey = _aws4SigningKey(secretAccessKey, dateStamp);
    final signatureBytes = hmacSha256(signingKey, utf8.encode(stringToSign));
    final signature = signatureBytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    return 'AWS4-HMAC-SHA256 Credential=$accessKeyId/$scope, SignedHeaders=$signedHeaders, Signature=$signature';
  }

  static Map<String, String> buildBaseHeaders(
    DeviceConfig device,
    String bodyText, {
    bool appid = false,
  }) {
    final now = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final headers = <String, String>{
      'content-type': 'application/json',
      'appvr': device.appvr,
      'ch': device.channel,
      'device-time': now,
      'lan': device.lan,
      'loc': device.loc,
      'pf': device.pf,
      'sign-ver': '1',
      'tdid': device.tdid,
      'x-ss-stub': makeSsStub(bodyText),
      'x-ss-dp': device.aid,
      'x-khronos': now,
      'x-tt-trace-id': makeTraceId(),
      'user-agent': 'Cronet/TTNetVersion:1d7cc3b1 2025-07-16 QuicVersion:52c2b40d 2025-04-03',
      'store-country-code': device.loc.toLowerCase(),
      'store-country-code-src': 'did',
      'is-dispatch-us-ttp': '0',
      'is-app-region-us-ttp': '0',
    };
    if (appid) {
      headers['app-sdk-version'] = device.appvr;
      headers['appid'] = device.aid;
    }
    return headers;
  }

  static String rsaEncryptPkcs1v15(
    String message, [
    String pem = ttsSignPublicKeyPem,
  ]) {
    final RSAPublicKey publicKey = CryptoUtils.rsaPublicKeyFromPem(pem);
    final cipher = PKCS1Encoding(RSAEngine())
      ..init(true, PublicKeyParameter<RSAPublicKey>(publicKey));
    final encrypted = cipher.process(Uint8List.fromList(utf8.encode(message)));
    return base64.encode(encrypted);
  }

  static String makeTtsPayloadSign(
    String ssml,
    String? extraInfo,
    String deviceId,
    String appId,
  ) {
    final ssmlMd5 = md5String(ssml);
    var signInput =
        'appid:$appId&did:$deviceId&creditDisable:false&ssml:$ssmlMd5';
    if (extraInfo != null) {
      signInput += '&extraInfo:$extraInfo';
    }
    return rsaEncryptPkcs1v15(signInput);
  }
}
