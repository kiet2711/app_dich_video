import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:capsub_flutter/data/api/capcut_signer.dart';

void main() {
  test('testMd5', () {
    const input = 'hello world';
    const expected = '5eb63bbbe01eeed093cb22bb8f5acdc3';
    expect(CapCutSigner.md5String(input), equals(expected));
  });

  test('testMakeSignHeader', () {
    const url =
        'https://editor-api-sg.capcutapi.com/lv/v1/upload_sign?device_id=123';
    const appvr = '8.7.0';
    const deviceTime = '1720000000';
    const tdid = '7647145645564632872';

    final sign = CapCutSigner.makeSignHeader(url, appvr, deviceTime, tdid);
    expect(sign.length, equals(32));
    expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(sign), isTrue);
  });

  test('testMakeSsStub', () {
    const body = '{"biz":"cc_pc_text_recognize"}';
    final stub = CapCutSigner.makeSsStub(body);
    expect(stub.length, equals(32));
    expect(stub, equals(CapCutSigner.md5String(body)));
  });

  test('testMakeTraceId', () {
    final traceId = CapCutSigner.makeTraceId();
    expect(traceId.startsWith('00-'), isTrue);
    expect(traceId.endsWith('-01'), isTrue);
  });

  test('testCrc32Hex', () {
    final data = utf8.encode('123456789');
    // Chuẩn CRC32 của "123456789" là cbf43926
    expect(CapCutSigner.crc32Hex(data), equals('cbf43926'));
  });

  test('testAws4Authorization', () {
    final auth = CapCutSigner.aws4Authorization(
      method: 'GET',
      url: 'https://example.com/top/v1?Action=ApplyUploadInner',
      body: [],
      accessKeyId: 'TEST_KEY_ID',
      secretAccessKey: 'TEST_SECRET_KEY',
      sessionToken: 'TEST_SESSION_TOKEN',
      amzDate: '20260921T120000Z',
    );

    expect(
      auth.startsWith(
        'AWS4-HMAC-SHA256 Credential=TEST_KEY_ID/20260921/sdwdmwlll/vod/aws4_request',
      ),
      isTrue,
    );
    expect(
      auth.contains('SignedHeaders=x-amz-date;x-amz-security-token'),
      isTrue,
    );
    expect(auth.contains('Signature='), isTrue);
  });

  test('testMakeTtsPayloadSign', () {
    const ssml =
        '<speak><voice name="BV074_streaming"><prosody rate="1.0">Xin chào</prosody></voice></speak>';
    const extraInfo = '{"benefit_info":{}}';
    const deviceId = '1234567890123456789';
    const appId = '359289';

    final sign = CapCutSigner.makeTtsPayloadSign(
      ssml,
      extraInfo,
      deviceId,
      appId,
    );
    // Chữ ký RSA PKCS#1 v1.5 với khóa 2048-bit luôn có kích thước 256 bytes, mã hóa Base64 là 344 ký tự
    expect(sign.isNotEmpty, isTrue);
    expect(sign.length, equals(344));
  });
}
