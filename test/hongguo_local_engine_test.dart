import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:capsub_flutter/domain/media/hongguo_cenc_decryptor.dart';
import 'package:capsub_flutter/domain/media/hongguo/hongguo_gorgon.dart';
import 'package:capsub_flutter/domain/media/hongguo/hongguo_helios.dart';
import 'package:capsub_flutter/domain/media/hongguo/hongguo_local_engine.dart';
import 'package:capsub_flutter/domain/media/hongguo/hongguo_medusa.dart';
import 'package:capsub_flutter/domain/media/hongguo/hongguo_sixgod_signer.dart';
import 'package:capsub_flutter/domain/media/hongguo/hongguo_sm3.dart';

void main() {
  group('Hongguo Local Engine & Sixgod Cryptography Tests', () {
    test('SM3 standard hash matches reference vectors', () {
      expect(
        HongguoSm3.hashHex('abc'),
        '66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0',
      );
    });

    test('HongguoGorgon matches reference test vector', () {
      expect(HongguoGorgon.reverseBits(0xC0), 0x03);

      final gorgon = HongguoGorgon.encryptGorgon(
        body: {'biz_param': {'video_platform': 1024}},
        query: 'iid=3076883975280827&device_id=3076883975276731',
        khronos: 1728388016,
        xgRand: 12345,
      );
      expect(gorgon, '8404393040015ab4db4368520c7c4b50121f10356c731aa0d23b');
    });

    test('HongguoHelios matches reference test vector', () {
      final helios = HongguoHelios.encryptHelios(
        khronos: 1728388016,
        rand: 54321,
      );
      expect(helios, 'MdQAAOAr0Ajd+Bre7yZrUCNxu18ek8ZgWUn0KJeLcG12vLBF');
    });

    test('HongguoMedusa matches reference test vector byte-for-byte', () {
      final medusa = HongguoMedusa.genMedusa(
        query: 'iid=3076883975280827&device_id=3076883975276731',
        body: {'biz_param': {'video_platform': 1024}},
        khronos: 1728388016,
        deviceId: '3076883975276731',
        versionName: '7.1.3.32',
        deviceType: '25053RT47C',
        hashRand: 11111,
        xmRand: 22222,
        protoRand: 1234567,
        launchTime: 110,
        pid: 11000,
        reportTime: 1728388016,
      );
      expect(medusa.length, 1012);
      expect(
        sha256.convert(utf8.encode(medusa)).toString(),
        '769a962c5759523cf5fa8e9724945acc3a994f2860094918004dba8836c5987b',
      );
    });

    test('deriveContentKey produces exact 16-byte key', () {
      const spadeA = 'nbwTxlyxJspbhRX8X4YWy0SzDuNGswjKc7c//nKDI9NzlTufnw==';
      final key = HongguoCencDecryptor.deriveContentKey(spadeA);
      expect(hex.encode(key), '0d8acde97b2c159b39096abf414e8760');
    });

    test('decryptSpadeUrl decrypts AES-128-CBC URL correctly', () {
      const rawUrl =
          'qAABAFLTFwkHd9eR+SqFALp3t9IDQwjHS5TOcgjkXjgwDK6D4AjvZNQon//zOGDYB6rVmRQCdjhumsonTgM/HjGMQcqqyJI77Ed7tbglymcc+PXanVrLCCUKhhqQqS2eJJyDUcT4u0yvg8aBRwOaCmL2n03qSr6imqaBQJrWlokShjrGdG7NXUxsTCfpn2V4W9+t4QXuGcKussDuCsmg+fySloDDgpf+Ph5AUVEyi6iPuER/s6sF5xjWXgtKaEQUVxlTMlDsWgPx8Cq3uZDzR2kiPrfefMjNtTrQITk+15Z+XZIgs31hcAWgD5OPmDHn7rhSc+x4ZiSTwmBk/LOKJyyKRuvL6QxdV7aTijvD2nZMuLw+lPK+yTwdYF8JNgI8K9i4yIYhhbbL6gEJI4a+wc93hk40fZAmF2xk1l8CohPDtOpR0FNW/tV+3JEijy3p9/IFd45qE0nmetf3zuq12quRTO3Yg9lC1kz6L+EUCx+i0PV+Jb2OBncOnHVjzMC3I2rQLGjvX+Sm2e/Cd409+lt/pyeWJzlMpVRZqiAri5ZBxkoNd/3ALd8bMsEuwbfI5lDK7E7BSTp8A+7It1MHVsXsy16M9mHenGiazjo6xUoMYQ/UB1eEz0lSAzD25sEsGhfVDnAslMYDiZg3LtjauiaGlJvn6qW//gX50npYWhjQfCPrY1Bdh4iHMMPzovTJqYR5DS5o0M5hz5x3FCo4tKgmQoeFtLVZzdAbSAL2IiLmw4EU2BsJ4wBCy1IbpQxAjXbfyV52cbqnnhUjZElbKIWh6nXlUcDqYW5uMYX5i0KbuWGzZgWoN5mKt7TBk0QZ+5cz5U74or5fa1v6RpYz3XqhyaH2OoBSQK3EQ1oJ5pL54hCqJlTrUUzQgkkgK30TRqEzGJVmv6kRQfEdbGH76k74CIQ=';
      const seedHex =
          '96c01307d5e80b5b3321e823822f55b649ce4e819499ffe852ac9f4b9d799199';
      final seed = Uint8List.fromList(hex.decode(seedHex));

      final decrypted = HongguoCencDecryptor.decryptSpadeUrl(rawUrl, seed);
      expect(decrypted, startsWith('https://v3-reading-videocdn302.qznovelvod.com/'));
      expect(decrypted, contains('video_mp4'));
    });

    test('signRequest produces required ByteDance query and headers', () {
      final payload = {
        'biz_param': {
          'detail_page_version': 0,
          'device_level': 3,
          'disable_digg_stat': false,
          'need_all_video_definition': true,
          'need_mp4_align': false,
          'use_os_player': false,
          'use_server_dns': false,
          'video_platform': 1024,
        },
        'mixed_video_id_map': {
          '1004': ['7687921227100343358'],
        },
      };

      final signed = HongguoSixgodSigner.signRequest(
        url: HongguoLocalEngine.videoModelUrlTemplate,
        body: payload,
      );

      expect(signed.signedUrl, contains('ts='));
      expect(signed.signedUrl, contains('_rticket='));
      expect(signed.headers['x-medusa'], isNotEmpty);
      expect(signed.headers['x-gorgon'], isNotEmpty);
      expect(signed.headers['x-ss-stub'], hasLength(32));
    });

    test('resolveVideoInfo live call retrieves valid stream URL & key', () async {
      final info = await HongguoLocalEngine.resolveVideoInfo('7687921227100343358');
      expect(info.realMainUrl, startsWith('http'));
      expect(info.contentKeyHex, isNotEmpty);
    });
  });
}
