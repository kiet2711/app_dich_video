import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import 'hongguo/hongguo_mp4_cenc.dart';
export 'hongguo/hongguo_mp4_cenc.dart';

/// Bộ giải mã DRM video CENC (Common Encryption) và Spade URL
/// Chạy trực tiếp trên thiết bị (On-Device Dart thuần) cho nền tảng Hồng Quả / ByteDance.
class HongguoCencDecryptor {
  /// Chuẩn bị bộ giải mã stream từ buffer hộp `moov`.
  static HongguoPreparedCenc prepareFromMoov(
    Uint8List moovBytes, {
    required int moovFileOffset,
  }) {
    return HongguoPreparedCenc.parseMoov(
      moovBytes,
      moovFileOffset: moovFileOffset,
    );
  }

  /// Đọc nhanh thời lượng & thông tin track từ file MP4 cục bộ (chỉ đọc box `moov`).
  static Future<Mp4ContainerMetadata?> probeMp4FileMetadata(File file) async {
    try {
      if (!await file.exists()) return null;
      final fileLen = await file.length();
      if (fileLen < 16) return null;
      final raf = await file.open(mode: FileMode.read);
      try {
        var cursor = 0;
        final headerBuf = Uint8List(16);
        while (cursor + 8 <= fileLen) {
          await raf.setPosition(cursor);
          final n = await raf.readInto(headerBuf, 0, 16);
          if (n < 8) break;
          final bd = ByteData.sublistView(headerBuf);
          final size32 = bd.getUint32(0, Endian.big);
          final type = ascii.decode(headerBuf.sublist(4, 8), allowInvalid: true);
          int boxSize;
          if (size32 == 1) {
            if (n < 16) break;
            boxSize = bd.getUint64(8, Endian.big);
          } else if (size32 == 0) {
            boxSize = fileLen - cursor;
          } else if (size32 < 8) {
            break;
          } else {
            boxSize = size32;
          }
          if (boxSize <= 0 || cursor + boxSize > fileLen) break;
          if (type == 'moov') {
            if (boxSize > 16 * 1024 * 1024) return null;
            await raf.setPosition(cursor);
            final moovBytes = await raf.read(boxSize);
            return HongguoPreparedCenc.probeMoovMetadata(
              moovBytes,
              moovFileOffset: cursor,
            );
          }
          cursor += boxSize;
        }
      } finally {
        await raf.close();
      }
    } catch (_) {}
    return null;
  }
  /// Kiểm tra xem file MP4 có bị lỗi box free size 8 gây crash ExoPlayer không
  static Future<bool> isCorruptedMp4File(File file) async {
    try {
      if (!await file.exists() || await file.length() < 100) return true;
      final raf = await file.open(mode: FileMode.read);
      try {
        final sampleLen = math.min(await file.length(), 4096);
        final header = await raf.read(sampleLen);
        final badPattern = [0, 0, 0, 8, 0x66, 0x72, 0x65, 0x65, 0, 0, 0, 0];
        for (var i = 0; i <= header.length - badPattern.length; i++) {
          var match = true;
          for (var j = 0; j < badPattern.length; j++) {
            if (header[i + j] != badPattern[j]) {
              match = false;
              break;
            }
          }
          if (match) return true;
        }
        return false;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }
  /// Giải mã Base64 có padding linh hoạt
  static Uint8List b64DecodePadded(String s) {
    var str = s.trim();
    final pad = str.length % 4;
    if (pad != 0) {
      str += '=' * (4 - pad);
    }
    try {
      return Uint8List.fromList(base64Decode(str));
    } catch (_) {
      return Uint8List.fromList(base64Url.decode(str));
    }
  }

  /// Trích xuất chuỗi 32 ký tự Hex của content_key từ chuỗi Base64 `spade_a`
  /// Dùng để truyền trực tiếp vào bộ giải mã FFmpeg native (`decryption_key=<hex>`)
  static String deriveContentKeyHex(String spadeB64) {
    var s = spadeB64.trim();
    final m = 4 - (s.length % 4);
    if (m != 4) {
      s += '=' * m;
    }

    final raw = base64Decode(s);
    if (raw.length < 3) {
      throw ArgumentError('spade_a quá ngắn: ${raw.length} bytes');
    }

    final v6 = raw[0] ^ raw[1] ^ raw[2];
    var v8 = raw.length - v6 + 47;

    if (v8 <= 0 || v8 > raw.length * 2) {
      throw StateError('spade_a: v8=$v8 ngoài phạm vi hợp lệ');
    }
    if (1 + v8 > raw.length) {
      v8 = raw.length - 1;
    }
    if (v8 < 33) {
      throw StateError('spade_a: v8=$v8 quá nhỏ (cần >= 33)');
    }

    final v13 = Uint8List.fromList(raw.sublist(1, 1 + v8));
    var vA = 85;
    var vB = 246;

    for (var i = 0; i < v8; i++) {
      // Đếm số bit 1 của i (popcount)
      var popcnt = 0;
      var temp = i;
      while (temp > 0) {
        popcnt += temp & 1;
        temp >>= 1;
      }

      int v24;
      if ((i & 1) != 0) {
        v24 = vA;
        vA = v13[i];
      } else {
        v24 = vB;
        vB = v13[i];
      }
      final v25 = v24 ^ v13[i];
      final v26 = -21 - popcnt;
      v13[i] = (v26 + v25) & 0xFF;
    }

    return ascii.decode(v13.sublist(1, 33)).toLowerCase();
  }

  /// Trích xuất 16-byte content_key từ chuỗi Base64 `spade_a`
  /// Thuật toán đảo ngược DRM của ByteDance / Fanqie Novel
  static Uint8List deriveContentKey(String spadeB64) {
    final hexStr = deriveContentKeyHex(spadeB64);
    final keyBytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      keyBytes[i] = int.parse(hexStr.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return keyBytes;
  }

  /// Giải mã URL Spade (AES-128-CBC) bằng key_seed
  static String decryptSpadeUrl(String b64Str, Uint8List keySeed) {
    if (b64Str.isEmpty) return '';

    final raw = b64DecodePadded(b64Str);
    if (raw.length < 5) {
      throw ArgumentError('Bản mã URL quá ngắn');
    }
    if (raw[0] != 0xA8 || raw[2] != 0x01 || raw[3] != 0x00) {
      throw FormatException('Định dạng header bản mã Spade URL không khớp');
    }

    final cipherData = raw.sublist(4);
    final cipherLen = (cipherData.length ~/ 16) * 16;
    if (cipherLen == 0) return '';
    final truncatedCipher = cipherData.sublist(0, cipherLen);

    final constants = Uint8List.fromList(const [
      0x4D,
      0xD4,
      0xC2,
      0xE6,
      0xB8,
      0x31,
      0x62,
      0x09,
      0x0E,
      0x52,
      0xB3,
      0xC7,
      0xA6,
      0x73,
      0x3B,
      0xA4,
      0x1C,
      0xB2,
      0x46,
      0x2B,
      0x82,
      0x9A,
      0xB5,
      0x8A,
      0x19,
      0x6B,
      0x39,
      0xDB,
      0x57,
      0x17,
      0x75,
      0x24,
      0xF4,
      0x9B,
      0xAF,
      0x7F,
      0x08,
      0xE8,
      0xD6,
      0x8D,
      0x26,
      0xA7,
      0x2E,
      0x37,
      0xC1,
      0xA9,
      0x5A,
      0x2F,
      0x1F,
      0x05,
      0xA5,
      0x18,
      0x92,
      0xAE,
      0xF2,
      0x94,
      0x97,
      0x32,
      0xB6,
      0x2A,
      0x38,
      0xAA,
      0xDD,
      0x58,
    ]);

    // H1 = SHA-512(key_seed)
    final h1 = Uint8List.fromList(sha512.convert(keySeed).bytes);

    // H2 = SHA-512(H1 + constants)
    final h2Input = Uint8List(h1.length + constants.length);
    h2Input.setRange(0, h1.length, h1);
    h2Input.setRange(h1.length, h2Input.length, constants);
    final h2 = Uint8List.fromList(sha512.convert(h2Input).bytes);

    final aesKey = h2.sublist(0, 16);
    final iv = h2.sublist(16, 32);

    // Giải mã AES-128-CBC
    final cbc = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(aesKey), iv));

    final plaintext = Uint8List(truncatedCipher.length);
    for (var offset = 0; offset < truncatedCipher.length; offset += 16) {
      cbc.processBlock(truncatedCipher, offset, plaintext, offset);
    }

    // Loại bỏ PKCS7 Padding
    var padLength = 0;
    if (plaintext.isNotEmpty) {
      final pad = plaintext.last;
      if (pad >= 1 && pad <= 16 && pad <= plaintext.length) {
        var isValid = true;
        for (var i = plaintext.length - pad; i < plaintext.length; i++) {
          if (plaintext[i] != pad) {
            isValid = false;
            break;
          }
        }
        if (isValid) {
          padLength = pad;
        }
      }
    }

    final trimmed = plaintext.sublist(0, plaintext.length - padLength);
    // Loại bỏ null bytes ở cuối
    var end = trimmed.length;
    while (end > 0 && trimmed[end - 1] == 0) {
      end--;
    }
    return utf8.decode(trimmed.sublist(0, end), allowMalformed: true);
  }

  /// Tìm box MP4 theo mã 4 ký tự (FourCC). Trả về (offset, size) hoặc (-1, 0)
  static (int, int) findBox(Uint8List data, String fourcc, int start) {
    final b = ascii.encode(fourcc);
    final bd = ByteData.sublistView(data);
    final end = data.length - 8;
    for (var i = start; i < end; i++) {
      if (i >= 4 &&
          data[i] == b[0] &&
          data[i + 1] == b[1] &&
          data[i + 2] == b[2] &&
          data[i + 3] == b[3]) {
        final sz = bd.getUint32(i - 4, Endian.big);
        if (sz > 0 && sz < 5000000) {
          return (i - 4, sz);
        }
      }
    }
    return (-1, 0);
  }

  /// Lấy nội dung thân (body) của box MP4 (bỏ qua 8 bytes header)
  static Uint8List? getBox(Uint8List data, String fourcc, int stblOff) {
    final (o, sz) = findBox(data, fourcc, stblOff);
    if (o >= 0 && o + sz <= data.length) {
      return data.sublist(o + 8, o + sz);
    }
    return null;
  }

  /// Phân tích bảng stbl của track
  static ({
    List<int> sizes,
    List<int> offsets,
    List<int> cns,
    int auxOff,
    int auxSz,
    int ns,
  })?
  parseTrack(Uint8List moov, int tOff) {
    final (stblOff, _) = findBox(moov, 'stbl', tOff + 8);
    if (stblOff < 0) return null;

    final stsz = getBox(moov, 'stsz', stblOff);
    if (stsz == null || stsz.length < 12) return null;
    final stszBd = ByteData.sublistView(stsz);
    final ds = stszBd.getUint32(4, Endian.big);
    final ns = stszBd.getUint32(8, Endian.big);
    final sizes = <int>[];
    if (ds == 0) {
      for (var i = 0; i < ns; i++) {
        sizes.add(stszBd.getUint32(12 + i * 4, Endian.big));
      }
    } else {
      sizes.addAll(List.filled(ns, ds));
    }

    final stco = getBox(moov, 'stco', stblOff);
    if (stco == null || stco.length < 8) return null;
    final stcoBd = ByteData.sublistView(stco);
    final nc = stcoBd.getUint32(4, Endian.big);
    final offsets = <int>[];
    for (var i = 0; i < nc; i++) {
      offsets.add(stcoBd.getUint32(8 + i * 4, Endian.big));
    }

    final stsc = getBox(moov, 'stsc', stblOff);
    if (stsc == null || stsc.length < 8) return null;
    final stscBd = ByteData.sublistView(stsc);
    final nsc = stscBd.getUint32(4, Endian.big);
    final entries = <(int, int, int)>[];
    for (var i = 0; i < nsc; i++) {
      entries.add((
        stscBd.getUint32(8 + i * 12, Endian.big),
        stscBd.getUint32(12 + i * 12, Endian.big),
        stscBd.getUint32(16 + i * 12, Endian.big),
      ));
    }

    final cns = List<int>.filled(nc, 0);
    for (var i = 0; i < nsc; i++) {
      final fc = entries[i].$1;
      final spc = entries[i].$2;
      var end = nc;
      if (i + 1 < nsc) {
        end = entries[i + 1].$1 - 1;
      }
      final limit = end < nc ? end : nc;
      for (var c = fc - 1; c < limit; c++) {
        if (c >= 0 && c < nc) {
          cns[c] = spc;
        }
      }
    }

    final saiz = getBox(moov, 'saiz', stblOff);
    if (saiz == null || saiz.length < 9) return null;
    final da = saiz[4];
    final saizBd = ByteData.sublistView(saiz);
    final na = saizBd.getUint32(5, Endian.big);

    final saio = getBox(moov, 'saio', stblOff);
    if (saio == null || saio.length < 12) return null;
    final saioBd = ByteData.sublistView(saio);
    final auxOff = saioBd.getUint32(8, Endian.big);
    final auxSz = na * (da > 8 ? da : 8);

    return (
      sizes: sizes,
      offsets: offsets,
      cns: cns,
      auxOff: auxOff,
      auxSz: auxSz,
      ns: ns,
    );
  }

  static void replaceFourcc(
    Uint8List data,
    List<int> oldBytes,
    List<int> newBytes,
  ) {
    final oldLen = oldBytes.length;
    final limit = data.length - oldLen;
    for (var i = 0; i < limit; i++) {
      var match = true;
      for (var j = 0; j < oldLen; j++) {
        if (data[i + j] != oldBytes[j]) {
          match = false;
          break;
        }
      }
      if (match) {
        for (var j = 0; j < newBytes.length; j++) {
          data[i + j] = newBytes[j];
        }
      }
    }
  }

  static void _replaceFourcc(
    Uint8List data,
    List<int> oldBytes,
    List<int> newBytes,
  ) => replaceFourcc(data, oldBytes, newBytes);

  static void replaceSinf(Uint8List data) {
    final bd = ByteData.sublistView(data);
    var i = 0;
    final limit = data.length - 4;
    final sinfBytes = ascii.encode('sinf');
    final freeBytes = ascii.encode('free');
    final frmaBytes = ascii.encode('frma');

    while (i < limit) {
      if (data[i] == sinfBytes[0] &&
          data[i + 1] == sinfBytes[1] &&
          data[i + 2] == sinfBytes[2] &&
          data[i + 3] == sinfBytes[3]) {
        if (i >= 4) {
          final sz = bd.getUint32(i - 4, Endian.big);
          if (sz > 0 && sz < 50000) {
            final end = (i - 4 + sz) < data.length ? (i - 4 + sz) : data.length;

            // Kiểm tra box frma bên trong sinf để khôi phục đúng FourCC gốc (hvc1, avc1, mp4a)
            for (var j = i + 4; j <= end - 8; j++) {
              if (data[j] == frmaBytes[0] &&
                  data[j + 1] == frmaBytes[1] &&
                  data[j + 2] == frmaBytes[2] &&
                  data[j + 3] == frmaBytes[3]) {
                final origFormat = data.sublist(j + 4, j + 8);
                final origStr = ascii.decode(origFormat, allowInvalid: true);
                if (origStr == 'hvc1' || origStr == 'avc1' || origStr == 'hev1') {
                  _replaceFourcc(data, ascii.encode('encv'), origFormat);
                } else if (origStr == 'mp4a') {
                  _replaceFourcc(data, ascii.encode('enca'), origFormat);
                }
                break;
              }
            }

            // Đổi sinf -> free nhưng GIỮ NGUYÊN kích thước sz của box!
            // Tuyệt đối không đổi kích thước thành 8 vì các byte đệm số 0 phía sau
            // sẽ bị ExoPlayer coi là atom con có kích thước 0 và gây lỗi "childAtomSize must be positive".
            data[i] = freeBytes[0];
            data[i + 1] = freeBytes[1];
            data[i + 2] = freeBytes[2];
            data[i + 3] = freeBytes[3];

            for (var j = i + 4; j < end; j++) {
              data[j] = 0;
            }
            i = end;
            continue;
          }
        }
      }
      i++;
    }
  }

  /// Giải mã trực tiếp file video MP4 bị mã hoá DRM CENC bằng `contentKey` (16 bytes)
  /// Trả về mảng byte MP4 hoàn chỉnh có thể phát trực tiếp trên mọi player
  static Uint8List decryptMp4Cenc(Uint8List data, Uint8List contentKey) {
    if (data.length < 16) {
      throw ArgumentError('Dữ liệu video quá nhỏ');
    }
    final bd = ByteData.sublistView(data);
    Mp4BoxRef? moovBox;
    for (final box in Mp4BoxScanner.iterChildren(data, bd, 0, data.length)) {
      if (box.type == 'moov') {
        moovBox = box;
        break;
      }
    }
    if (moovBox == null) {
      throw const FormatException('MP4 không hợp lệ: không tìm thấy hoặc lỗi box moov');
    }

    final moovSlice = Uint8List.sublistView(
      data,
      moovBox.offset,
      moovBox.endOffset,
    );
    final prepared = HongguoPreparedCenc.parseMoov(
      moovSlice,
      moovFileOffset: moovBox.offset,
    );
    prepared.finalizeFromFullBuffer(data);

    // Cho phép sửa tại chỗ khi caller không giữ bản mã để tiết kiệm RAM.
    prepared.decryptRange(0, data, contentKey: contentKey);
    return data;
  }
}
