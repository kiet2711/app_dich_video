import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ksub/domain/media/hongguo/hongguo_device_service.dart';
import 'package:ksub/domain/media/hongguo/hongguo_medusa_v5.dart';
import 'package:ksub/domain/media/hongguo/hongguo_sm3.dart';
import 'package:ksub/domain/media/hongguo/hongguo_v5_constants.dart';
import 'package:ksub/domain/media/hongguo/hongguo_v5_signer.dart';

Uint8List _hexToBytes(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s+'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _bytesToHex(List<int> bytes) {
  return bytes.map((b) => (b & 0xFF).toRadixString(16).padLeft(2, '0')).join();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    HongguoDeviceService.instance.resetForTesting();
  });

  group('Hongguo ttEncrypt & DeviceRegister', () {
    test('ttEncrypt matches hongguoTV DeviceCryptoTest golden vector', () {
      final random32 = _hexToBytes(
        '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
      );
      final data = Uint8List.fromList(utf8.encode('hello-tt-encrypt-payload'));
      final encrypted = HongguoDeviceService.ttEncrypt(data, random32: random32);

      const expectedHex =
          '746305100000000102030405060708090a0b0c0d0e0f10111213141516171819'
          '1a1b1c1d1e1f9c2938fa4a012faf0ecd9d31020e00f9748841c73838f76c10a9'
          'f9084bcfc717bc3cb6085a81a491f6e9b3d47a574b96bd818707ca911fc89bfa'
          'd9a68edc174aa2f2dbc4ea60415c1e06b7525320a6451dbebd0a552028b5e706'
          '53d538c39842';
      expect(_bytesToHex(encrypted), expectedHex);
    });

    test('buildRegisterHeaders omits signature headers and brotli', () {
      final body = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final headers = HongguoDeviceService.buildRegisterHeaders(
        body,
        nowMs: 1800000000123,
      );

      expect(headers['Content-Type'], 'application/octet-stream;tt-data=a');
      expect(headers['log-encode-type'], 'gzip');
      expect(headers['Accept-Encoding'], 'gzip');
      expect(headers['x-ss-dp'], '8662');
      expect(headers['x-ss-stub'], '08D6C05A21512A79A1DFEB9D2A8F262F');
      expect(headers.containsKey('x-gorgon'), isFalse);
      expect(headers.containsKey('x-medusa'), isFalse);
      expect(headers.containsKey('x-helios'), isFalse);
    });

    test('device registration via mock Dio persists cdid, cookies & enforces cooldown', () async {
      var calls = 0;
      Uint8List? capturedBody;
      final dio = Dio();
      dio.httpClientAdapter = _MockAdapter((options) async {
        calls++;
        if (options.data is Stream<List<int>>) {
          final chunks = await (options.data as Stream<List<int>>).toList();
          capturedBody = Uint8List.fromList(chunks.expand((e) => e).toList());
        }
        return ResponseBody.fromString(
          jsonEncode(<String, dynamic>{
            'device_id': 7491234567890123456,
            'device_id_str': '7491234567890123456',
            'install_id_str': '7491234567890129999',
            'device_token': 'tok_v5',
            'new_user': 1,
          }),
          200,
          headers: <String, List<String>>{
            'content-type': <String>['application/json'],
            'set-cookie': <String>[
              'install_id=7491234567890129999; Path=/',
              'ttreq=abcd1234; Path=/',
              'store-region=cn; Path=/',
              'ignored_cookie=xyz; Path=/',
            ],
          },
        );
      });

      HongguoDeviceService.instance.setDioForTesting(dio);
      final info = await HongguoDeviceService.instance.getOrRegisterDevice();
      expect(calls, 1);
      expect(info.isValid, isTrue);
      expect(info.isRegistered, isTrue);
      expect(info.deviceId, '7491234567890123456');
      expect(info.installId, '7491234567890129999');
      expect(info.cdid, isNotEmpty);
      expect(
        info.cookieHeader,
        'install_id=7491234567890129999; ttreq=abcd1234; store-region=cn',
      );
      expect(capturedBody, isNotNull);
      expect(capturedBody!.sublist(0, 6), <int>[0x74, 0x63, 0x05, 0x10, 0x00, 0x00]);

      // Second call uses cache.
      final cached = await HongguoDeviceService.instance.getOrRegisterDevice();
      expect(calls, 1);
      expect(cached.deviceId, info.deviceId);

      // Rotation succeeds first time, then is blocked by 5-min cooldown.
      final rotated1 = await HongguoDeviceService.instance.rotateDevice();
      expect(rotated1, isTrue);
      expect(calls, 2);

      final rotated2 = await HongguoDeviceService.instance.rotateDevice();
      expect(rotated2, isFalse);
      expect(calls, 2);
    });
  });

  group('Hongguo v5 Medusa, AesV3, hashF13 & Helios', () {
    test('AesV3V5 encrypts 248+ byte payloads across all 4 ts mod 4 modes', () {
      final key = Uint8List.fromList(List<int>.generate(16, (i) => (i * 17 + 3) & 0xFF));
      final iv = Uint8List.fromList(List<int>.generate(16, (i) => (i * 29 + 7) & 0xFF));
      final src = Uint8List.fromList(List<int>.generate(260, (i) => (i * 13 + 5) & 0xFF));

      expect(
        () => HongguoAesV3V5(key, 1800000000).encrypt(Uint8List(247), iv),
        throwsArgumentError,
      );

      final outputs = <String>{};
      for (var offset = 0; offset < 4; offset++) {
        final ts = 1800000000 + offset;
        final enc1 = HongguoAesV3V5(key, ts).encrypt(src, iv);
        final enc2 = HongguoAesV3V5(key, ts).encrypt(src, iv);
        expect(enc1.length, src.length + 1);
        expect(enc1, enc2);
        outputs.add(_bytesToHex(enc1));
      }
      expect(outputs.length, 4);
    });

    test('hashF13V5 enforces branch 12 and emits 20 bytes with 0x20 flag', () {
      const ts = 1800000000;
      var matchedTicket = -1;
      for (var offset = 0; offset < 256; offset++) {
        final q = 'aid=8662&_rticket=${ts * 1000 + offset}';
        if (HongguoMedusaV5.isValidBranch(q, null, ts)) {
          matchedTicket = offset;
          final qSm3 = HongguoSm3.hash(Uint8List.fromList(utf8.encode(q)));
          final bMd5 = Uint8List(16);
          final f13 = HongguoMedusaV5.hashF13V5(qSm3, bMd5, ts);
          expect(f13.length, 20);
          expect(f13[16] & 0x20, 0x20);
          break;
        }
      }
      expect(matchedTicket, greaterThanOrEqualTo(0));
    });

    test('signPlaybackV5 builds branch-12 request with lean headers and deterministic output', () {
      final device = HongguoDeviceInfo(
        deviceId: '7491234567890123456',
        installId: '7491234567890129999',
        cdid: '11111111-2222-4333-8444-555555555555',
        processNonce: 'test_nonce_123456',
        processStartedMs: 1799999000000,
      );
      final body = Uint8List.fromList(utf8.encode('{"mixed_video_id_map":{"1004":["123"]}}'));

      final req1 = HongguoV5Signer.signPlaybackV5(
        baseUrl: 'https://api5-normal-sinfonlinea.fqnovel.com/novel/player/multi_video_model/player/v1',
        device: device,
        bodyBytes: body,
        nowMs: 1800000000000,
        heliosRandom: 0x12345678,
        medusaMessageRand: 0x11223344,
        medusaNonceRand: 0x55667788,
        medusaTailRand: 0x99aabbcc,
      );
      final req2 = HongguoV5Signer.signPlaybackV5(
        baseUrl: 'https://api5-normal-sinfonlinea.fqnovel.com/novel/player/multi_video_model/player/v1',
        device: device,
        bodyBytes: body,
        nowMs: 1800000000000,
        heliosRandom: 0x12345678,
        medusaMessageRand: 0x11223344,
        medusaNonceRand: 0x55667788,
        medusaTailRand: 0x99aabbcc,
      );

      expect(req1.url, req2.url);
      expect(req1.headers, req2.headers);

      final uri = Uri.parse(req1.url);
      expect(uri.queryParameters['aid'], '8662');
      expect(uri.queryParameters['version_code'], '74332');
      expect(uri.queryParameters['device_type'], 'PGT-AN10');
      expect(uri.queryParameters.containsKey('ts'), isFalse);
      expect(
        HongguoMedusaV5.isValidBranch(uri.query, body, 1800000000),
        isTrue,
      );

      expect(req1.headers['User-Agent'], HongguoV5Constants.playerUaV5);
      expect(req1.headers['Content-Encoding'], 'gzip');
      expect(req1.headers['x-khronos'], '1800000000');
      expect(req1.headers['x-helios'], isNotEmpty);
      expect(req1.headers['x-medusa'], isNotEmpty);
      expect(req1.headers['x-ss-stub'], isNotEmpty);
      expect(req1.headers.containsKey('Cookie'), isFalse);
      expect(req1.headers.containsKey('x-gorgon'), isFalse);
      expect(req1.headers.containsKey('x-ladon'), isFalse);
      expect(req1.headers.containsKey('x-argus'), isFalse);
    });
  });
}

class _MockAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) handler;

  _MockAdapter(this.handler);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return handler(options);
  }
}
