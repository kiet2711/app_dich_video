import 'dart:convert';
import 'dart:typed_data';
import 'package:convert/convert.dart';

/// Thuật toán hàm băm SM3 chuẩn quốc gia Trung Quốc (GB/T 32918.4-2016)
/// Dùng bởi module bảo mật ByteDance Sixgod / Medusa.
class HongguoSm3 {
  static const int _t1 = 0x79cc4519;
  static const int _t2 = 0x7a879d8a;

  static const List<int> _iv = [
    0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600,
    0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e,
  ];

  static int _rol(int x, int n) {
    n = n % 32;
    return (((x << n) | ((x & 0xFFFFFFFF) >> (32 - n)))) & 0xFFFFFFFF;
  }

  static int _p0(int x) => (x ^ _rol(x, 9) ^ _rol(x, 17)) & 0xFFFFFFFF;
  static int _p1(int x) => (x ^ _rol(x, 15) ^ _rol(x, 23)) & 0xFFFFFFFF;

  static int _ff(int x, int y, int z, int j) {
    if (j < 16) {
      return (x ^ y ^ z) & 0xFFFFFFFF;
    }
    return ((x & y) | (x & z) | (y & z)) & 0xFFFFFFFF;
  }

  static int _gg(int x, int y, int z, int j) {
    if (j < 16) {
      return (x ^ y ^ z) & 0xFFFFFFFF;
    }
    return ((x & y) | ((~x) & z)) & 0xFFFFFFFF;
  }

  /// Tính băm SM3 dạng bytes
  static Uint8List hash(List<int> msg) {
    final length = msg.length;
    final bitLen = length * 8;

    // Padding: 0x80 rồi số lượng byte 0 sao cho len % 64 == 56, rồi 8 byte bit length
    var k = 56 - ((length + 1) % 64);
    if (k < 0) k += 64;

    final padded = Uint8List(length + 1 + k + 8);
    padded.setRange(0, length, msg);
    padded[length] = 0x80;

    // Ghi 64-bit big endian bitLen vào 8 byte cuối
    final bd = ByteData.sublistView(padded);
    // 32-bit high = 0 (cho file < 500MB)
    bd.setUint32(padded.length - 8, bitLen ~/ 0x100000000, Endian.big);
    bd.setUint32(padded.length - 4, bitLen & 0xFFFFFFFF, Endian.big);

    final v = List<int>.from(_iv);
    final w = List<int>.filled(68, 0);
    final w1 = List<int>.filled(64, 0);

    for (var i = 0; i < padded.length; i += 64) {
      for (var j = 0; j < 16; j++) {
        w[j] = bd.getUint32(i + j * 4, Endian.big);
      }
      for (var j = 16; j < 68; j++) {
        w[j] = (_p1(w[j - 16] ^ w[j - 9] ^ _rol(w[j - 3], 15)) ^
                _rol(w[j - 13], 7) ^
                w[j - 6]) &
            0xFFFFFFFF;
      }
      for (var j = 0; j < 64; j++) {
        w1[j] = (w[j] ^ w[j + 4]) & 0xFFFFFFFF;
      }

      var a = v[0];
      var b = v[1];
      var c = v[2];
      var d = v[3];
      var e = v[4];
      var f = v[5];
      var g = v[6];
      var h = v[7];

      for (var j = 0; j < 64; j++) {
        final t = j < 16 ? _t1 : _t2;
        final ss1 = _rol((_rol(a, 12) + e + _rol(t, j % 32)) & 0xFFFFFFFF, 7);
        final ss2 = (ss1 ^ _rol(a, 12)) & 0xFFFFFFFF;
        final tt1 = (_ff(a, b, c, j) + d + ss2 + w1[j]) & 0xFFFFFFFF;
        final tt2 = (_gg(e, f, g, j) + h + ss1 + w[j]) & 0xFFFFFFFF;

        d = c;
        c = _rol(b, 9);
        b = a;
        a = tt1;
        h = g;
        g = _rol(f, 19);
        f = e;
        e = _p0(tt2);
      }

      v[0] = (v[0] ^ a) & 0xFFFFFFFF;
      v[1] = (v[1] ^ b) & 0xFFFFFFFF;
      v[2] = (v[2] ^ c) & 0xFFFFFFFF;
      v[3] = (v[3] ^ d) & 0xFFFFFFFF;
      v[4] = (v[4] ^ e) & 0xFFFFFFFF;
      v[5] = (v[5] ^ f) & 0xFFFFFFFF;
      v[6] = (v[6] ^ g) & 0xFFFFFFFF;
      v[7] = (v[7] ^ h) & 0xFFFFFFFF;
    }

    final out = Uint8List(32);
    final outBd = ByteData.sublistView(out);
    for (var i = 0; i < 8; i++) {
      outBd.setUint32(i * 4, v[i], Endian.big);
    }
    return out;
  }

  /// Tính băm SM3 dạng chuỗi hex
  static String hashHex(dynamic input) {
    List<int> bytes;
    if (input is String) {
      bytes = utf8.encode(input);
    } else if (input is List<int>) {
      bytes = input;
    } else {
      throw ArgumentError('Input phải là String hoặc List<int>');
    }
    return hex.encode(hash(bytes));
  }
}
