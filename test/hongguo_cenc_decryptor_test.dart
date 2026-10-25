import 'dart:convert';
import 'dart:typed_data';

import 'package:capsub_flutter/domain/media/hongguo_cenc_decryptor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HongguoCencDecryptor Tests', () {
    test('deriveContentKeyHex and deriveContentKey consistency', () {
      const expectedHex = '0123456789abcdef0123456789abcdef';
      final targetAscii = ascii.encode(expectedHex);

      // Build a synthetic valid spade_a that decodes to expectedHex
      final raw = Uint8List(50);
      // We will fill raw[1..49] (which is v13_old[0..48])
      // so that after forward transform, v13[1..32] == targetAscii
      final desiredFinal = Uint8List(49);
      for (var k = 0; k < 32; k++) {
        desiredFinal[1 + k] = targetAscii[k];
      }

      var vA = 85;
      var vB = 246;
      final v13Old = Uint8List(49);
      v13Old[0] = 0; // raw[1] = 0

      // Step i = 0:
      {
        final v24 = vB;
        vB = v13Old[0]; // 0
        final v25 = v24 ^ v13Old[0];
        final v26 = -21;
        desiredFinal[0] = (v26 + v25) & 0xFF;
      }

      for (var i = 1; i < 49; i++) {
        var popcnt = 0;
        var temp = i;
        while (temp > 0) {
          popcnt += temp & 1;
          temp >>= 1;
        }

        final int v24;
        if ((i & 1) != 0) {
          v24 = vA;
        } else {
          v24 = vB;
        }

        final v26 = -21 - popcnt;
        final targetFinalVal = desiredFinal[i];
        final neededXor = (targetFinalVal - v26) & 0xFF;
        final oldVal = v24 ^ neededXor;
        v13Old[i] = oldVal;

        if ((i & 1) != 0) {
          vA = oldVal;
        } else {
          vB = oldVal;
        }
      }

      for (var i = 0; i < 49; i++) {
        raw[1 + i] = v13Old[i];
      }
      // Set raw[0] so that raw[0] ^ raw[1] ^ raw[2] = 0
      raw[0] = raw[1] ^ raw[2];

      final spadeA = base64Encode(raw);

      final hexKey = HongguoCencDecryptor.deriveContentKeyHex(spadeA);
      expect(hexKey, equals(expectedHex));

      final byteKey = HongguoCencDecryptor.deriveContentKey(spadeA);
      expect(byteKey.length, 16);

      // Verify hexKey matches byteKey
      final convertedBack = byteKey
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join('')
          .toLowerCase();
      expect(convertedBack, equals(hexKey));
    });
  });
}
