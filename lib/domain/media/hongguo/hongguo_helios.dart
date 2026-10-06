import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Bộ tạo chữ ký X-Helios của ByteDance
class HongguoHelios {
  static final BigInt _mask64 = (BigInt.one << 64) - BigInt.one;

  /// Phép xoay phải 64-bit (ror)
  static BigInt ror(BigInt value, int count) {
    final c = count % 64;
    if (c == 0) return value & _mask64;
    final low = (value << (64 - c)) & _mask64;
    final high = value >> c;
    return (high | low) & _mask64;
  }

  static BigInt _readUint64Le(Uint8List bytes, int offset) {
    var res = BigInt.zero;
    for (var i = 0; i < 8; i++) {
      res |= BigInt.from(bytes[offset + i]) << (i * 8);
    }
    return res;
  }

  static void _writeUint64Le(BigInt value, Uint8List target, int offset) {
    var v = value;
    for (var i = 0; i < 8; i++) {
      target[offset + i] = (v & BigInt.from(0xFF)).toInt();
      v >>= 8;
    }
  }

  static Uint8List _encryptHeliosInput(List<BigInt> hashTable, Uint8List inData) {
    var data0 = _readUint64Le(inData, 0);
    var data1 = _readUint64Le(inData, 8);

    for (var i = 0; i < 0x22; i++) {
      final hash1 = hashTable[i];
      data1 = hash1 ^ ((data0 + ror(data1, 8)) & _mask64);
      data0 = (data1 ^ ror(data0, 61)) & _mask64;
    }

    final out = Uint8List(16);
    _writeUint64Le(data0, out, 0);
    _writeUint64Le(data1, out, 8);
    return out;
  }

  /// Sinh chữ ký X-Helios
  static String encryptHelios({
    required int khronos,
    int? rand,
  }) {
    final effectiveRand = rand ?? (Random().nextInt(0x7FFFFFFF) + (Random().nextInt(2) << 31));
    final dataBd = ByteData(4);
    dataBd.setUint32(0, effectiveRand, Endian.little);
    final dataBuilder = BytesBuilder();
    dataBuilder.add(dataBd.buffer.asUint8List());
    dataBuilder.add(utf8.encode('8662'));

    final keySum = md5.convert(dataBuilder.toBytes()).bytes;
    final hexChars = ascii.encode('0123456789abcdef');

    final keys = Uint8List(32);
    for (var i = 0; i < 16; i++) {
      final v1 = keySum[i];
      keys[2 * i] = hexChars[v1 >> 4];
      keys[2 * i + 1] = hexChars[v1 & 15];
    }

    final hashTable = <BigInt>[];
    hashTable.add(_readUint64Le(keys, 0));

    final keyMatrix = <BigInt>[];
    for (var i = 0; i < keys.length; i += 8) {
      keyMatrix.add(_readUint64Le(keys, i));
    }

    var bufferB0 = keyMatrix[0];
    var bufferB8 = keyMatrix[1];
    keyMatrix.removeAt(0);
    keyMatrix.removeAt(0);

    for (var i = 0; i < 0x22; i++) {
      final x9 = bufferB0;
      var x8 = bufferB8;

      x8 = ror(x8, 8);
      x8 = (x8 + x9) & _mask64;
      x8 = (x8 ^ BigInt.from(i)) & _mask64;
      keyMatrix.add(x8);

      x8 = (x8 ^ ror(x9, 61)) & _mask64;

      hashTable.add(x8);
      bufferB0 = x8;
      bufferB8 = keyMatrix[0];
      keyMatrix.removeAt(0);
    }

    // PKCS7 Padding cho chuỗi "${khronos}-1588093228-8662"
    final rawText = utf8.encode('$khronos-1588093228-8662');
    final padLength = 16 - (rawText.length % 16);
    final inData = Uint8List(rawText.length + padLength);
    inData.setRange(0, rawText.length, rawText);
    for (var i = rawText.length; i < inData.length; i++) {
      inData[i] = padLength;
    }

    final outBuilder = BytesBuilder();
    for (var i = 0; i < inData.length; i += 16) {
      outBuilder.add(_encryptHeliosInput(hashTable, inData.sublist(i, i + 16)));
    }

    final finalBuilder = BytesBuilder();
    finalBuilder.add(dataBd.buffer.asUint8List());
    finalBuilder.add(outBuilder.toBytes());

    return base64Encode(finalBuilder.toBytes());
  }
}
