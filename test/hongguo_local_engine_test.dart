import 'package:capsub_flutter/domain/media/hongguo/hongguo_local_engine.dart';
import 'package:capsub_flutter/domain/media/hongguo/hongguo_sixgod_signer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Hongguo Local Engine & Sixgod Tests', () {
    test('signRequest uses valid default device credentials', () {
      final signed = HongguoSixgodSigner.signRequest(
        url: HongguoLocalEngine.videoModelUrlTemplate,
        body: {'test': 1},
      );
      final uri = Uri.parse(signed.signedUrl);
      expect(uri.queryParameters['device_id'], HongguoSixgodSigner.defaultDeviceId);
      expect(uri.queryParameters['iid'], HongguoSixgodSigner.defaultInstallId);
    });

    test('resolveVideoInfo retrieves valid stream URL & DRM key for Episode 2', () async {
      // Test video ID from user report (Tập 2: 7699685725448457241)
      const videoId = '7699685725448457241';
      final info = await HongguoLocalEngine.resolveVideoInfo(videoId);
      expect(info.realMainUrl, startsWith('http'));
      expect(info.contentKeyHex, hasLength(32));
      expect(info.isDrmProtected, isTrue);
    });
  });
}

