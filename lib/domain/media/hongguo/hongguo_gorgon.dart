import 'dart:convert';
import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';

/// Bộ tạo chữ ký X-Gorgon (v8.4) của ByteDance
class HongguoGorgon {
  static const List<int> gorgon84 = [0x4a, 0x16, 0x47, 0x6c, 0x84, 0x04];

  /// RC4 tùy biến dùng cho X-Gorgon
  static Uint8List rc4Xg(Uint8List data, Uint8List key) {
    final s = List<int>.generate(256, (i) => i);
    var j = 0;
    for (var i = 0; i < 256; i++) {
      j = (j + s[i] + key[i % key.length]) % 256;
      s[i] = s[j];
    }

    var i = 0;
    j = 0;
    final result = Uint8List(data.length);
    for (var k = 0; k < data.length; k++) {
      i = (i + 1) & 0xFF;
      final x = s[i];
      j = (j + x) & 0xFF;
      final y = s[j];
      s[i] = y;
      result[k] = data[k] ^ s[(y + y) & 0xFF];
    }
    return result;
  }

  /// Đảo ngược 8 bit của một byte (0b10000000 -> 0b00000001)
  static int reverseBits(int num) {
    var v = num & 0xFF;
    v = ((v >> 1) & 0x55) | ((v & 0x55) << 1);
    v = ((v >> 2) & 0x33) | ((v & 0x33) << 2);
    v = ((v >> 4) & 0x0F) | ((v & 0x0F) << 4);
    return v & 0xFF;
  }

  /// Tính x-ss-stub (MD5 uppercase) từ body
  static String calculateStub(dynamic body) {
    if (body == null) return '';
    String str;
    if (body is String) {
      str = body;
    } else {
      str = jsonEncode(body);
    }
    return md5.convert(utf8.encode(str)).toString().toUpperCase();
  }

  /// Sinh chữ ký X-Gorgon
  static String encryptGorgon({
    required dynamic body,
    required String query,
    required int khronos,
    required int xgRand,
  }) {
    const xgSeed = 320;
    final bodyMd5Str = (body != null) ? calculateStub(body).toLowerCase() : '';

    final queryMd5 = md5.convert(utf8.encode(query)).bytes;
    final dataBuilder = BytesBuilder();
    dataBuilder.add(queryMd5.sublist(0, 4));

    if (bodyMd5Str.isNotEmpty) {
      final bodyMd5Bytes = hex.decode(bodyMd5Str);
      dataBuilder.add(bodyMd5Bytes.sublist(0, 4));
    } else {
      dataBuilder.add([0, 0, 0, 0]);
    }
    dataBuilder.add([0, 0, 0, 0]);

    // mssdkVersionInt = 67503104 little endian (4 bytes)
    final bd = ByteData(8);
    bd.setUint32(0, 67503104, Endian.little);
    // khronos big endian (4 bytes)
    bd.setUint32(4, khronos, Endian.big);
    dataBuilder.add(bd.buffer.asUint8List());

    final data = dataBuilder.toBytes();

    final key = Uint8List.fromList([
      gorgon84[0],
      xgSeed & 0xFF,
      gorgon84[1],
      (xgRand >> 8) & 0xFF,
      gorgon84[2],
      gorgon84[3],
      (xgSeed >> 8) & 0xFF,
      xgRand & 0xFF,
    ]);

    final out = rc4Xg(data, key);

    for (var i = 0; i < out.length; i++) {
      final a = out[i];
      out[i] = ((a >> 4) | (a << 4)) & 0xFF;
      var nextA = out[0];
      if (i + 1 < out.length) {
        nextA = out[i + 1];
      }
      nextA ^= out[i];
      nextA = reverseBits(nextA);
      out[i] = (~(nextA ^ 20)) & 0xFF;
    }

    final retBuilder = BytesBuilder();
    retBuilder.add(gorgon84.sublist(gorgon84.length - 2));

    final randSeedBd = ByteData(4);
    randSeedBd.setUint16(0, xgRand, Endian.little);
    randSeedBd.setUint16(2, xgSeed, Endian.little);
    retBuilder.add(randSeedBd.buffer.asUint8List());
    retBuilder.add(out);

    return hex.encode(retBuilder.toBytes());
  }
}
