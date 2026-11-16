import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'hongguo_medusa.dart';
import 'hongguo_sm3.dart';
import 'hongguo_v5_constants.dart';

/// Triển khai AES-V3 phiên bản v5 (protocol-specific carrier cipher v04.10.03).
class HongguoAesV3V5 {
  final int word;
  late final Uint8List _box;
  late final List<int> _con;
  late final List<int> _order;
  late final List<List<int>> _keys;

  HongguoAesV3V5(Uint8List key, int timestamp) : word = timestamp & 3 {
    if (key.length != 16) {
      throw ArgumentError.value(key.length, 'key', 'AES-V3 key must be 16 bytes');
    }
    _box = Uint8List.sublistView(
      HongguoV5Constants.sbox,
      word * 256,
      (word + 1) * 256,
    );
    const cons = <List<int>>[
      <int>[2, 0, 3, 1],
      <int>[1, 3, 2, 0],
      <int>[3, 2, 1, 0],
      <int>[2, 3, 1, 0],
    ];
    const orders = <List<int>>[
      <int>[0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
      <int>[0, 9, 14, 11, 4, 13, 2, 3, 8, 1, 6, 15, 12, 5, 10, 7],
      <int>[0, 9, 14, 3, 4, 13, 2, 15, 8, 1, 6, 11, 12, 5, 10, 7],
      <int>[0, 9, 14, 15, 4, 13, 2, 3, 8, 1, 6, 11, 12, 5, 10, 7],
    ];
    const initials = <int>[0xbbb5de72, 0xd4638d5b, 0x92a5f73b, 0x89f8a1c9];
    _con = cons[word];
    _order = orders[word];

    final initial = initials[word];
    final initLe = _le32(initial);
    final expanded = List<int>.filled(48, 0);
    for (var i = 0; i < 16; i++) {
      expanded[i] = (initLe[i & 3] ^ key[i]) & 0xFF;
    }

    var rounds = 8;
    for (var i = 4; i < 12; i++) {
      final at = 4 * (i - 1);
      var a = expanded[at];
      var b = expanded[at + 1];
      var c = expanded[at + 2];
      var d = expanded[at + 3];
      if ((i & 3) == 0) {
        final t = ((initial >>> (rounds & 24)) ^ _box[b]) & 0xFF;
        b = _box[c];
        c = _box[d];
        d = _box[a];
        a = t;
      }
      rounds += 2;
      expanded[at + 4] = (a ^ expanded[at - 12]) & 0xFF;
      expanded[at + 5] = (b ^ expanded[at - 11]) & 0xFF;
      expanded[at + 6] = (c ^ expanded[at - 10]) & 0xFF;
      expanded[at + 7] = (d ^ expanded[at - 9]) & 0xFF;
    }

    _keys = List<List<int>>.generate(
      12,
      (i) => expanded.sublist(i * 4, i * 4 + 4),
    );
  }

  Uint8List _block(Uint8List value) {
    final rows = List<List<int>>.generate(
      4,
      (i) => List<int>.generate(4, (j) => value[i * 4 + j] & 0xFF),
    );

    void addCon(int offset) {
      for (var i = 0; i < 4; i++) {
        for (var j = 0; j < 4; j++) {
          rows[i][j] = (rows[i][j] ^ _keys[offset + i][_con[j]]) & 0xFF;
        }
      }
    }

    addCon(0);
    for (var round = 1; round <= 2; round++) {
      for (var i = 0; i < 4; i++) {
        for (var j = 0; j < 4; j++) {
          rows[i][j] = _box[rows[i][j]];
        }
      }
      final before = List<List<int>>.generate(
        4,
        (i) => List<int>.from(rows[i]),
      );
      for (var i = 0; i < 4; i++) {
        rows[i] = List<int>.from(before[_con[i]]);
      }
      final flat = <int>[
        ...rows[0],
        ...rows[1],
        ...rows[2],
        ...rows[3],
      ];
      for (var i = 0; i < 16; i++) {
        rows[i ~/ 4][i % 4] = flat[_order[i]];
      }
      if (round == 1) {
        for (var i = 0; i < 4; i++) {
          final old = List<int>.from(rows[i]);
          for (var j = 0; j < 4; j++) {
            rows[i][j] = old[_con[j]];
          }
        }
        int xt(int x) => ((x << 1) ^ ((x & 128) != 0 ? 0x1b : 0)) & 0xFF;
        for (var i = 0; i < 4; i++) {
          final t = rows[0][i] ^ rows[1][i] ^ rows[2][i] ^ rows[3][i];
          final u = rows[0][i];
          rows[0][i] = (rows[0][i] ^ t ^ xt(rows[0][i] ^ rows[1][i])) & 0xFF;
          rows[1][i] = (rows[1][i] ^ t ^ xt(rows[1][i] ^ rows[2][i])) & 0xFF;
          rows[2][i] = (rows[2][i] ^ t ^ xt(rows[2][i] ^ rows[3][i])) & 0xFF;
          rows[3][i] = (rows[3][i] ^ t ^ xt(rows[3][i] ^ u)) & 0xFF;
        }
      }
      addCon(round * 4);
    }

    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) {
        rows[i][j] = (rows[i][j] ^ _keys[4 + i][j]) & 0xFF;
      }
    }

    final out = Uint8List(16);
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) {
        out[i * 4 + j] = rows[i][j] & 0xFF;
      }
    }
    return out;
  }

  Uint8List encrypt(Uint8List source, Uint8List iv) {
    if (source.length < 248) {
      throw ArgumentError.value(
        source.length,
        'source',
        'AES-V3 source must be at least 248 bytes',
      );
    }
    if (iv.length < 16) {
      throw ArgumentError.value(iv.length, 'iv', 'AES-V3 iv must be 16 bytes');
    }

    const wire = <int>[6, 5, 3, 4, 2, 7, 1, 0];
    const compact = <int>[1, 7, 3, 6, 2, 0, 4, 5];

    final plaintext = Uint8List(32);
    for (var i = 0; i < 31; i++) {
      var acc = 0;
      for (var j = 0; j < 8; j++) {
        final bit = (source[i * 8 + j] >> wire[j]) & 1;
        acc |= bit << compact[j];
      }
      plaintext[i] = acc & 0xFF;
    }
    plaintext[31] = 1;

    final firstIn = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      firstIn[i] = (plaintext[i] ^ iv[i]) & 0xFF;
    }
    final first = _block(firstIn);

    final secondIn = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      secondIn[i] = (plaintext[16 + i] ^ first[i]) & 0xFF;
    }
    final second = _block(secondIn);

    final key = Uint8List(32);
    key.setAll(0, first);
    key.setAll(16, second);

    final out = Uint8List(1 + source.length);
    out[0] = key[31];
    out.setAll(1, source);
    for (var i = 0; i < 31; i++) {
      for (var j = 0; j < 8; j++) {
        final at = 1 + i * 8 + j;
        final bit = (key[i] >> compact[j]) & 1;
        out[at] = (out[at] & (~(1 << wire[j]))) | (bit << wire[j]);
      }
    }
    return out;
  }

  static Uint8List _le32(int value) {
    final bd = ByteData(4)..setUint32(0, value & 0xFFFFFFFF, Endian.little);
    return bd.buffer.asUint8List();
  }
}

/// Bộ tạo chữ ký Medusa v5 (nhánh F13 `12` + Helios license `646637794`).
class HongguoMedusaV5 {
  HongguoMedusaV5._();

  static int _getIv(int initial, Uint8List data) {
    var value = initial & 0xFFFFFFFF;
    for (var i = 0; i < data.length; i++) {
      final b = data[i] & 0xFF;
      if ((i & 1) == 0) {
        value = ((value >>> 4) ^ value ^ ((value << 6) & 0xFFFFFFFF) ^ b) &
            0xFFFFFFFF;
      } else {
        value = (~((value >>> 7) ^ value ^ (b | ((value << 12) & 0xFFFFFFFF)))) &
            0xFFFFFFFF;
      }
    }
    return value;
  }

  /// Tính giá trị IV kết hợp query SM3, body MD5 và timestamp (4 byte LE).
  static int computeIv(Uint8List querySm3, Uint8List bodyMd5, int ts) {
    return _getIv(
      _getIv(_getIv(0x20230928, querySm3), bodyMd5),
      _le32(ts),
    );
  }

  /// v5 chỉ chấp nhận nhánh hash F13 `12` (`(iv & 15) == 12`).
  static bool isValidBranch(String query, Uint8List? body, int ts) {
    final querySm3 = HongguoSm3.hash(Uint8List.fromList(utf8.encode(query)));
    final bodyMd5 =
        body != null ? Uint8List.fromList(md5.convert(body).bytes) : Uint8List(16);
    return (computeIv(querySm3, bodyMd5, ts) & 15) == 12;
  }

  static int _rol32(int v, int n) {
    final s = n & 31;
    final u = v & 0xFFFFFFFF;
    if (s == 0) return u;
    return ((u << s) | (u >>> (32 - s))) & 0xFFFFFFFF;
  }

  static int _ror32(int v, int n) {
    final s = n & 31;
    final u = v & 0xFFFFFFFF;
    if (s == 0) return u;
    return ((u >>> s) | (u << (32 - s))) & 0xFFFFFFFF;
  }

  static int _sumMd5(Uint8List data) {
    var check = 0x20220420;
    for (var i = 0; i < 12; i++) {
      final temp =
          ((check >>> ((i & 1) == 0 ? 3 : 5)) ^ check) & 0xFFFFFFFF;
      if ((i & 1) == 0) {
        check = ((data[i] & 0xFF) ^ ((check << 7) & 0xFFFFFFFF)) & 0xFFFFFFFF;
      } else {
        check = (~((data[i] & 0xFF) | ((check << 11) & 0xFFFFFFFF))) &
            0xFFFFFFFF;
      }
      check = (check ^ temp) & 0xFFFFFFFF;
    }
    return ((check | 4) ^ 0x1000000) & 0xFFFFFFFF;
  }

  /// Tính `hashF13` nhánh `12` chuẩn mobile v5 (với cờ `| 0x20` ở checksum đuôi).
  static Uint8List hashF13V5(Uint8List querySm3, Uint8List bodyMd5, int ts) {
    final ivVal = computeIv(querySm3, bodyMd5, ts);
    if ((ivVal & 15) != 12) {
      throw StateError('Unsupported v5 hash branch: ${ivVal & 15}');
    }

    const ivV1 = 0x9d4a97c2;
    final count = (ivV1 + (ts & 0xFFFFFFFF)) & 0xFFFFFFFF;
    final tt = HongguoV5Constants.hashTable
        .map((e) => _ror32(e, (count + 1) & 255))
        .toList(growable: false);
    final shift = (count + 2) & 7;
    final pad = Uint8List.fromList(
      <int>[0xfa, 0x45, 0x61, 0xd7]
          .map((it) => ((it | (it << 8)) >> shift) & 0xFF)
          .toList(growable: false),
    );

    final data = Uint8List(64);
    data.setAll(0, querySm3.sublist(0, 32));
    data.setAll(32, bodyMd5.sublist(0, 16));
    data.setAll(48, _le32(ts));
    data.setAll(52, pad);
    // 00000000000001a0
    data[62] = 0x01;
    data[63] = 0xa0;

    final diBd = ByteData.sublistView(data);
    final di = List<int>.generate(
      16,
      (i) => diBd.getUint32(i * 4, Endian.big),
    );
    for (var i = 0; i < 112; i++) {
      final x = di[i + 1];
      final y = di[i + 14];
      final s0 = _rol32(x, 14) ^ _rol32(x, 25) ^ (x >>> 3);
      final s1 = _rol32(y, 13) ^ _rol32(y, 15) ^ (y >>> 10);
      di.add((di[i] + di[i + 9] + s0 + s1) & 0xFFFFFFFF);
    }

    const rawInitial = <int>[
      0x7aba4fc8,
      0x67166507,
      0x6403fa00,
      0x340f512f,
      984304912,
      3005047866,
      2874125293,
      2152413264,
    ];
    final initial = rawInitial
        .map((e) => _ror32(e, count))
        .toList(growable: false);

    const chosen = <int>[96, 1, 3, 4, 0, 6, 5, 2, 0, 7, 7];
    final d = List<int>.from(initial);
    for (var i = 0; i < chosen[0]; i++) {
      final base = (ivV1 + i) & 0xFFFFFFFF;
      final n1 = ((d[chosen[3]] ^ d[chosen[4]]) & d[chosen[1]]) ^ d[chosen[3]];
      final n2 = _rol32(d[chosen[1]], 26) ^
          _rol32(d[chosen[1]], 21) ^
          _rol32(d[chosen[1]], 7);
      final n4 =
          (di[base & 127] + n1 + n2 + tt[base & 63] + d[chosen[5]]) &
              0xFFFFFFFF;
      final n5 = _rol32(d[chosen[2]], 30) ^
          _rol32(d[chosen[2]], 19) ^
          _rol32(d[chosen[2]], 10);
      final n6 = (d[chosen[2]] & d[chosen[6]]) |
          ((d[chosen[2]] | d[chosen[6]]) & d[chosen[7]]);
      final old = d[chosen[9]];
      final last = d.removeAt(7);
      d.insert(0, last);
      d[chosen[10]] = (n5 + n6 + n4) & 0xFFFFFFFF;
      d[chosen[8]] = (old + n4) & 0xFFFFFFFF;
    }

    final ret = Uint8List(32);
    final retBd = ByteData.sublistView(ret);
    for (var i = 0; i < 8; i++) {
      retBd.setUint32(i * 4, (d[i] + initial[i]) & 0xFFFFFFFF, Endian.big);
    }

    final folded = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      folded[i] = (ret[i] ^ ret[i + 16]) & 0xFF;
    }

    final sum = (_sumMd5(folded) | 0x20) & 0xFFFFFFFF;
    final out = Uint8List(20);
    out.setAll(0, folded);
    out.setAll(16, _le32(sum));
    return out;
  }

  /// Sinh header `x-medusa` bản v5 (`v04.10.03-ml-android`).
  static String genMedusaV5({
    required String url,
    Uint8List? body,
    required int ts,
    required String deviceId,
    required String channel,
    required String versionName,
    required String osVersion,
    required String deviceType,
    required String processNonce,
    required int processStartedMs,
    int? messageRand,
    int? nonceRand,
    int? tailRand,
  }) {
    final qIdx = url.indexOf('?');
    final queryStr = qIdx >= 0 ? url.substring(qIdx + 1) : '';
    final query = HongguoSm3.hash(Uint8List.fromList(utf8.encode(queryStr)));
    final bodyMd5 =
        body != null ? Uint8List.fromList(md5.convert(body).bytes) : Uint8List(16);
    final f13 = hashF13V5(query, bodyMd5, ts);
    final flags = Uint8List(8);

    final deviceInfo = _encodeProto(<_ProtoField>[
      _ProtoField.sint(1, 1),
      _ProtoField.sint(2, 2),
      _ProtoField.str(3, '8662'),
      _ProtoField.str(4, deviceId),
      _ProtoField.str(5, processNonce),
      _ProtoField.str(6, '!noperm!'),
      _ProtoField.str(12, 'Asia/Shanghai,8'),
      _ProtoField.str(13, 'zh_CN'),
      _ProtoField.str(22, osVersion),
      _ProtoField.sint(25, processStartedMs),
      _ProtoField.str(30, deviceType),
      _ProtoField.str(31, 'HONOR'),
      _ProtoField.str(32, deviceType),
      _ProtoField.str(34, 'HONOR'),
    ]);

    final env = _encodeProto(<_ProtoField>[
      _ProtoField.str(6, 'v04.10.03.04-bugfix'),
      _ProtoField.str(8, channel),
      _ProtoField.bytes(12, deviceInfo),
      _ProtoField.str(14, versionName),
    ]);

    final nested15 = _encodeProto(<_ProtoField>[
      _ProtoField.sint(1, 1),
      _ProtoField.sint(2, 1),
      _ProtoField.sint(3, 1),
      _ProtoField.sint(5, 1),
    ]);

    final rng = Random.secure();
    int nextRand32() =>
        (rng.nextInt(0x10000) << 16) | rng.nextInt(0x10000);

    final msgRand = (messageRand ?? nextRand32()) & 0xFFFFFFFF;
    final message = _encodeProto(<_ProtoField>[
      _ProtoField.bytes(1, HongguoV5Constants.magic),
      _ProtoField.sint(2, 5),
      _ProtoField.sint(3, msgRand),
      _ProtoField.str(4, '8662'),
      _ProtoField.str(5, deviceId),
      _ProtoField.str(6, HongguoV5Constants.license),
      _ProtoField.str(7, versionName),
      _ProtoField.str(8, 'v04.10.03-ml-android'),
      _ProtoField.sint(9, 0x040a0300),
      _ProtoField.bytes(10, flags),
      _ProtoField.sint(12, ts),
      _ProtoField.bytes(13, f13),
      _ProtoField.bytes(14, Uint8List.sublistView(query, 0, 6)),
      _ProtoField.bytes(15, nested15),
      _ProtoField.sint(17, ts),
      _ProtoField.str(20, 'none'),
      _ProtoField.sint(21, 377),
      _ProtoField.bytes(23, env),
      _ProtoField.str(
        24,
        '{"cmr":16777216,"cmr2":16777216,"un_h":11,"vpn":0,"kd":0,"dyn":"","do":1,"tk":true}',
      ),
    ]);

    final nonce = (nonceRand ?? nextRand32()) & 0xFFFFFFFF;
    final key = HongguoV5Constants.signKey;
    final hashInput = BytesBuilder(copy: false)
      ..add(key)
      ..add(_le32(nonce))
      ..add(key);
    final hash = HongguoSm3.hash(hashInput.toBytes());

    final high = (nonce >>> 16) & 0xFF;
    final seed = _le32(
      (~(((high << 11) | (nonce >>> 24)) ^ (high >>> 5) ^ high)) & 0xFFFFFFFF,
    );

    final xm = HongguoMedusa.xmxor(message, hash);
    final combinedLen = flags.length + xm.length;
    final transformed = Uint8List(combinedLen);
    for (var i = 0; i < combinedLen; i++) {
      final srcIdx = combinedLen - 1 - i;
      final srcByte = srcIdx < flags.length
          ? flags[srcIdx]
          : xm[srcIdx - flags.length];
      transformed[i] = (srcByte ^ seed[(~i) & 3]) & 0xFF;
    }

    final check = (0x18000001 |
            ((query[0] & 63) << 14) |
            ((f13[0] & 63) << 8)) &
        0xFFFFFFFF;
    final tRand = (tailRand ?? nextRand32()) & 0xFFFFFFFF;
    final packed = BytesBuilder(copy: false)
      ..addByte(0xca)
      ..add(_le32(tRand))
      ..add(_le32(check))
      ..add(transformed)
      ..addByte((nonce >>> 16) & 0xFF)
      ..addByte((nonce >>> 24) & 0xFF);

    final keyFirst = Uint8List.fromList(
      md5.convert(Uint8List.sublistView(key, 0, 16)).bytes,
    );
    final keySecond = Uint8List.fromList(
      md5.convert(Uint8List.sublistView(key, 16, 32)).bytes,
    );
    final encrypted = HongguoAesV3V5(keyFirst, ts).encrypt(
      packed.toBytes(),
      keySecond,
    );

    final prefix = BytesBuilder(copy: false)
      ..add(_le32(5))
      ..add(HongguoV5Constants.magic);
    final prefixBytes = prefix.toBytes();
    final tsLe = _le32(ts);
    for (var i = 0; i < prefixBytes.length; i++) {
      prefixBytes[i] = (prefixBytes[i] ^ tsLe[i & 3]) & 0xFF;
    }

    final finalOut = BytesBuilder(copy: false)
      ..add(prefixBytes)
      ..addByte(nonce & 0xFF)
      ..addByte((nonce >>> 8) & 0xFF)
      ..addByte(0)
      ..addByte(1)
      ..add(encrypted);
    return base64Encode(finalOut.toBytes());
  }

  /// Sinh header `x-helios` chuẩn v5 (hoặc v3 khi truyền `license`).
  static String genHelios({
    required int ts,
    int? randomVal,
    String license = HongguoV5Constants.license,
  }) {
    final rng = Random.secure();
    final r = (randomVal ?? ((rng.nextInt(0x10000) << 16) | rng.nextInt(0x10000))) &
        0xFFFFFFFF;
    final md5Input = BytesBuilder(copy: false)
      ..add(_le32(r))
      ..add(utf8.encode('8662'));
    final ascii = utf8.encode(md5.convert(md5Input.toBytes()).toString());
    final asciiBytes = Uint8List.fromList(ascii);
    final bd = ByteData.sublistView(asciiBytes);
    final words = List<int>.generate(
      4,
      (i) => bd.getInt64(i * 8, Endian.little),
    );
    final table = <int>[words[0]];
    var b0 = words.removeAt(0);
    var b8 = words.removeAt(0);
    for (var i = 0; i < 34; i++) {
      var x8 = (_ror64(b8, 8) + b0) ^ i;
      words.add(x8);
      x8 = x8 ^ _ror64(b0, 61);
      table.add(x8);
      b0 = x8;
      b8 = words.removeAt(0);
    }

    final text = utf8.encode('$ts-$license-8662');
    final padding = 16 - (text.length % 16);
    final data = Uint8List(text.length + padding)
      ..setAll(0, text)
      ..fillRange(text.length, text.length + padding, padding);
    final dataBd = ByteData.sublistView(data);

    final out = BytesBuilder(copy: false)..add(_le32(r));
    for (var at = 0; at < data.length; at += 16) {
      var a = dataBd.getInt64(at, Endian.little);
      var b = dataBd.getInt64(at + 8, Endian.little);
      for (var i = 0; i < 34; i++) {
        b = table[i] ^ (a + _ror64(b, 8));
        a = b ^ _ror64(a, 61);
      }
      out.add(_le64(a));
      out.add(_le64(b));
    }
    return base64Encode(out.toBytes());
  }

  static int _ror64(int v, int n) {
    final s = n & 63;
    if (s == 0) return v;
    return (v >>> s) | (v << (64 - s));
  }

  static Uint8List _le32(int value) {
    final bd = ByteData(4)..setUint32(0, value & 0xFFFFFFFF, Endian.little);
    return bd.buffer.asUint8List();
  }

  static Uint8List _le64(int value) {
    final bd = ByteData(8)..setInt64(0, value, Endian.little);
    return bd.buffer.asUint8List();
  }

  static Uint8List _encodeProto(List<_ProtoField> fields) {
    final out = BytesBuilder(copy: false);
    for (final field in fields) {
      if (field.isSint) {
        final n = field.sintValue!;
        _writeVarint(out, field.tag << 3);
        final zz = n < 0 ? (-n * 2 - 1) : (n * 2);
        _writeVarint(out, zz);
      } else {
        final bytes = field.bytesValue!;
        if (bytes.isEmpty) continue;
        _writeVarint(out, (field.tag << 3) | 2);
        _writeVarint(out, bytes.length);
        out.add(bytes);
      }
    }
    return out.toBytes();
  }

  static void _writeVarint(BytesBuilder out, int value) {
    var n = value;
    while (n < 0 || n > 127) {
      out.addByte((n & 127) | 128);
      n = n >>> 7;
    }
    out.addByte(n);
  }
}

class _ProtoField {
  final int tag;
  final bool isSint;
  final int? sintValue;
  final Uint8List? bytesValue;

  const _ProtoField._({
    required this.tag,
    required this.isSint,
    this.sintValue,
    this.bytesValue,
  });

  factory _ProtoField.sint(int tag, int value) =>
      _ProtoField._(tag: tag, isSint: true, sintValue: value);

  factory _ProtoField.str(int tag, String value) => _ProtoField._(
        tag: tag,
        isSint: false,
        bytesValue: Uint8List.fromList(utf8.encode(value)),
      );

  factory _ProtoField.bytes(int tag, Uint8List value) =>
      _ProtoField._(tag: tag, isSint: false, bytesValue: value);
}

