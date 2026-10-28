import 'dart:io';
import 'package:capsub_flutter/domain/media/hongguo/hongguo_device_service.dart';
import 'package:capsub_flutter/domain/media/hongguo/hongguo_local_engine.dart';
import 'package:capsub_flutter/domain/media/hongguo/hongguo_sixgod_signer.dart';
import 'package:flutter_test/flutter_test.dart';

class MyHttpOverrides extends HttpOverrides {}

void main() {
  HttpOverrides.global = MyHttpOverrides();

  group('Hongguo Local Engine & Sixgod Tests', () {
    test('signRequest uses valid default device credentials when none provided', () {
      final signed = HongguoSixgodSigner.signRequest(
        url: HongguoLocalEngine.videoModelUrlTemplate,
        body: {'test': 1},
      );
      final uri = Uri.parse(signed.signedUrl);
      expect(uri.queryParameters['device_id'], HongguoSixgodSigner.defaultDeviceId);
      expect(uri.queryParameters['iid'], HongguoSixgodSigner.defaultInstallId);
    });

    test('HongguoDeviceService registers real device and caches it', () async {
      final dev = await HongguoDeviceService.instance.getOrRegisterDevice();
      expect(dev.deviceId, isNotEmpty);
      expect(dev.installId, isNotEmpty);
      expect(dev.isValid, isTrue);

      // Subsequent call returns cached instance in 0ms
      final cachedDev = await HongguoDeviceService.instance.getOrRegisterDevice();
      expect(cachedDev.deviceId, dev.deviceId);
      expect(cachedDev.installId, dev.installId);
    });

    test('resolveVideoInfo retrieves valid stream URL & DRM key with real registered device', () async {
      const videoId = '7699685725448457241';
      final info = await HongguoLocalEngine.resolveVideoInfo(videoId);
      expect(info.realMainUrl, startsWith('http'));
      expect(info.contentKeyHex, hasLength(32));
      expect(info.isDrmProtected, isTrue);
    });
  });
}
