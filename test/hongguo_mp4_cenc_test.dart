import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

import 'package:ksub/domain/media/hongguo/hongguo_remote_video.dart';
import 'package:ksub/domain/media/hongguo_cenc_decryptor.dart';

Uint8List _box(String type, List<int> payload) {
  final size = 8 + payload.length;
  final out = Uint8List(size);
  ByteData.sublistView(out).setUint32(0, size, Endian.big);
  out.setAll(4, ascii.encode(type));
  out.setAll(8, payload);
  return out;
}

Uint8List _fullBox(String type, int version, int flags, List<int> payload) {
  final b = BytesBuilder(copy: false)
    ..addByte(version & 0xFF)
    ..addByte((flags >> 16) & 0xFF)
    ..addByte((flags >> 8) & 0xFF)
    ..addByte(flags & 0xFF)
    ..add(payload);
  return _box(type, b.toBytes());
}

Uint8List _u32(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.big)).buffer.asUint8List();

Uint8List _u16(int v) =>
    (ByteData(2)..setUint16(0, v, Endian.big)).buffer.asUint8List();

Uint8List _u64(int v) =>
    (ByteData(8)..setUint64(0, v, Endian.big)).buffer.asUint8List();

Uint8List _aesCtrEncrypt(Uint8List plain, Uint8List key, Uint8List iv16) {
  final engine = AESEngine()..init(true, KeyParameter(key));
  final counter = Uint8List.fromList(iv16);
  final ks = Uint8List(16);
  final out = Uint8List(plain.length);
  for (var i = 0; i < plain.length; i++) {
    final inBlock = i & 15;
    if (inBlock == 0) {
      engine.processBlock(counter, 0, ks, 0);
      for (var k = 15; k >= 0; k--) {
        counter[k] = (counter[k] + 1) & 0xFF;
        if (counter[k] != 0) break;
      }
    }
    out[i] = plain[i] ^ ks[inBlock];
  }
  return out;
}

Uint8List _buildSyntheticCencMp4({
  required Uint8List contentKey,
  required List<Uint8List> plainSamples,
  required List<Uint8List> ivs,
  required int ivSize,
  required String originalFourcc,
  required bool useCo64,
  required bool useSaizFlags1,
  required bool useSaioV1,
  List<List<({int clearBytes, int encBytes})>>? subsamples,
  int durationSeconds = 95,
  int width = 1080,
  int height = 1920,
}) {
  final ftyp = _box('ftyp', ascii.encode('isom\x00\x00\x02\x00isomiso2avc1mp41'));

  // Build mdat payload: [encrypted samples..., aux table...]
  final encryptedSamples = <Uint8List>[];
  final auxEntries = <Uint8List>[];
  for (var s = 0; s < plainSamples.length; s++) {
    final plain = plainSamples[s];
    final iv16 = Uint8List(16)..setAll(0, ivs[s]);
    final subs = subsamples?[s];
    if (subs == null || subs.isEmpty) {
      encryptedSamples.add(_aesCtrEncrypt(plain, contentKey, iv16));
      auxEntries.add(Uint8List.fromList(ivs[s].sublist(0, ivSize)));
    } else {
      // Collect only encrypted bytes across subsamples to share one continuous CTR stream.
      final encStreamIn = BytesBuilder(copy: false);
      var cursor = 0;
      for (final sub in subs) {
        cursor += sub.clearBytes;
        encStreamIn.add(plain.sublist(cursor, cursor + sub.encBytes));
        cursor += sub.encBytes;
      }
      final encStreamOut = _aesCtrEncrypt(encStreamIn.toBytes(), contentKey, iv16);

      final sampleOut = Uint8List.fromList(plain);
      var pPos = 0;
      var ePos = 0;
      for (final sub in subs) {
        pPos += sub.clearBytes;
        sampleOut.setRange(pPos, pPos + sub.encBytes, encStreamOut, ePos);
        pPos += sub.encBytes;
        ePos += sub.encBytes;
      }
      encryptedSamples.add(sampleOut);

      final aux = BytesBuilder(copy: false)
        ..add(ivs[s].sublist(0, ivSize))
        ..add(_u16(subs.length));
      for (final sub in subs) {
        aux
          ..add(_u16(sub.clearBytes))
          ..add(_u32(sub.encBytes));
      }
      auxEntries.add(aux.toBytes());
    }
  }

  final mdatBody = BytesBuilder(copy: false);
  final sampleRelOffsets = <int>[];
  for (final es in encryptedSamples) {
    sampleRelOffsets.add(mdatBody.length);
    mdatBody.add(es);
  }
  final auxRelOffset = mdatBody.length;
  for (final a in auxEntries) {
    mdatBody.add(a);
  }
  final mdat = _box('mdat', mdatBody.toBytes());

  // Build stbl children twice: first with placeholder offsets, then patched with exact file offsets.
  Uint8List buildMoov(int sampleStartAbs, int auxStartAbs) {
    final sinf = _box('sinf', <int>[
      ..._box('frma', ascii.encode(originalFourcc)),
      ..._box('schi', _fullBox('tenc', 0, 0, <int>[
        0, 0, 1, ivSize, ...List<int>.filled(16, 0xAA),
      ])),
    ]);

    final visualFixed = Uint8List(78);
    ByteData.sublistView(visualFixed)
      ..setUint16(24, width, Endian.big)
      ..setUint16(26, height, Endian.big);
    final encv = _box('encv', <int>[...visualFixed, ...sinf]);
    final stsd = _fullBox('stsd', 0, 0, <int>[..._u32(1), ...encv]);

    final stsz = _fullBox('stsz', 0, 0, <int>[
      ..._u32(0),
      ..._u32(encryptedSamples.length),
      for (final es in encryptedSamples) ..._u32(es.length),
    ]);
    final stsc = _fullBox('stsc', 0, 0, <int>[
      ..._u32(1),
      ..._u32(1),
      ..._u32(encryptedSamples.length),
      ..._u32(1),
    ]);
    final chunkBox = useCo64
        ? _fullBox('co64', 0, 0, <int>[..._u32(1), ..._u64(sampleStartAbs)])
        : _fullBox('stco', 0, 0, <int>[..._u32(1), ..._u32(sampleStartAbs)]);

    final saizPayload = BytesBuilder(copy: false);
    if (useSaizFlags1) {
      saizPayload
        ..add(ascii.encode('cenc'))
        ..add(_u32(0));
    }
    final firstAuxLen = auxEntries.first.length;
    final uniformAux = auxEntries.every((e) => e.length == firstAuxLen);
    if (uniformAux) {
      saizPayload
        ..addByte(firstAuxLen)
        ..add(_u32(auxEntries.length));
    } else {
      saizPayload
        ..addByte(0)
        ..add(_u32(auxEntries.length));
      for (final a in auxEntries) {
        saizPayload.addByte(a.length);
      }
    }
    final saiz = _fullBox('saiz', 0, useSaizFlags1 ? 1 : 0, saizPayload.toBytes());

    final saioPayload = BytesBuilder(copy: false);
    if (useSaioV1) {
      saioPayload
        ..add(ascii.encode('cenc'))
        ..add(_u32(0));
    }
    saioPayload.add(_u32(1));
    saioPayload.add(useSaioV1 ? _u64(auxStartAbs) : _u32(auxStartAbs));
    final saio = _fullBox(
      'saio',
      useSaioV1 ? 1 : 0,
      useSaioV1 ? 1 : 0,
      saioPayload.toBytes(),
    );

    final stts = _fullBox('stts', 0, 0, <int>[
      ..._u32(1),
      ..._u32(encryptedSamples.length),
      ..._u32(1000),
    ]);

    final stbl = _box('stbl', <int>[
      ...stsd,
      ...stts,
      ...stsz,
      ...stsc,
      ...chunkBox,
      ...saiz,
      ...saio,
    ]);
    final minf = _box('minf', stbl);
    final mdhd = _fullBox('mdhd', 0, 0, <int>[
      ..._u32(0),
      ..._u32(0),
      ..._u32(1000),
      ..._u32(durationSeconds * 1000),
      ..._u32(0),
    ]);
    final hdlr = _fullBox('hdlr', 0, 0, <int>[
      ..._u32(0),
      ...ascii.encode('vide'),
      ...List<int>.filled(12, 0),
    ]);
    final mdia = _box('mdia', <int>[...mdhd, ...hdlr, ...minf]);
    final tkhdPayload = Uint8List(88);
    ByteData.sublistView(tkhdPayload)
      ..setUint32(80, width << 16, Endian.big)
      ..setUint32(84, height << 16, Endian.big);
    final tkhd = _fullBox('tkhd', 0, 3, tkhdPayload);
    final trak = _box('trak', <int>[...tkhd, ...mdia]);
    final mvhd = _fullBox('mvhd', 0, 0, <int>[
      ..._u32(0),
      ..._u32(0),
      ..._u32(1000),
      ..._u32(durationSeconds * 1000),
      ...List<int>.filled(76, 0),
    ]);
    return _box('moov', <int>[...mvhd, ...trak]);
  }

  final dummyMoov = buildMoov(0, 0);
  final mdatPayloadAbs = ftyp.length + dummyMoov.length + 8;
  final exactMoov = buildMoov(mdatPayloadAbs, mdatPayloadAbs + auxRelOffset);
  assert(exactMoov.length == dummyMoov.length);

  return Uint8List.fromList(<int>[...ftyp, ...exactMoov, ...mdat]);
}

void main() {
  group('HongguoMp4Cenc MediaCrypto & ISO BMFF Tests', () {
    test('decrypts full-sample 8-byte IV MP4 and restores avc1 frma without touching mdat strings', () {
      final key = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
      // Put literal "encv" and "sinf" inside plain sample payload to verify we do NOT corrupt video frames!
      final sample0 = Uint8List.fromList(<int>[
        ...utf8.encode('FRAME0-encv-sinf-keep-me-intact!'),
        ...List<int>.generate(40, (i) => i * 3 & 0xFF),
      ]);
      final sample1 = Uint8List.fromList(List<int>.generate(65, (i) => (255 - i) & 0xFF));
      final iv0 = Uint8List.fromList(List<int>.generate(8, (i) => 0x10 + i));
      final iv1 = Uint8List.fromList(List<int>.generate(8, (i) => 0x20 + i));

      final encrypted = _buildSyntheticCencMp4(
        contentKey: key,
        plainSamples: <Uint8List>[sample0, sample1],
        ivs: <Uint8List>[iv0, iv1],
        ivSize: 8,
        originalFourcc: 'avc1',
        useCo64: false,
        useSaizFlags1: false,
        useSaioV1: false,
        durationSeconds: 95,
      );

      final decrypted = HongguoCencDecryptor.decryptMp4Cenc(
        Uint8List.fromList(encrypted),
        key,
      );

      // Verify metadata & patched boxes (avc1 + free, NO global hvc1 override).
      final meta = HongguoPreparedCenc.probeMoovMetadata(
        Uint8List.sublistView(
          decrypted,
          HongguoCencDecryptor.findBox(decrypted, 'moov', 0).$1,
          HongguoCencDecryptor.findBox(decrypted, 'moov', 0).$1 +
              HongguoCencDecryptor.findBox(decrypted, 'moov', 0).$2,
        ),
      );
      expect(meta, isNotNull);
      expect(meta!.durationMs, 95000);
      expect(meta.primaryVideoTrack!.originalFourcc, 'avc1');
      expect(meta.primaryVideoTrack!.width, 1080);
      expect(meta.primaryVideoTrack!.height, 1920);

      // Verify recovered plain samples appear bit-for-bit inside decrypted MP4 (including "encv-sinf").
      final decryptedStr = latin1.decode(decrypted);
      expect(decryptedStr.contains('FRAME0-encv-sinf-keep-me-intact!'), isTrue);
    });

    test('handles subsample CENC, co64, saiz flags&1, saio v1 64-bit, 16-byte IV counter wrap, and arbitrary chunked decryptRange', () {
      final key = Uint8List.fromList(List<int>.generate(16, (i) => 0xA0 + i));
      // 16-byte IV near 0xFF..FF so block 0 -> block 1 wraps all 128 bits cleanly!
      final wrapIv = Uint8List.fromList(List<int>.filled(16, 0xFF));
      final sample0 = Uint8List.fromList(List<int>.generate(120, (i) => (i * 7 + 1) & 0xFF));
      final subs = <({int clearBytes, int encBytes})>[
        (clearBytes: 5, encBytes: 25), // spans block 0 and block 1
        (clearBytes: 7, encBytes: 40), // continues CTR counter seamlessly!
        (clearBytes: 3, encBytes: 40),
      ];

      final fullMp4 = _buildSyntheticCencMp4(
        contentKey: key,
        plainSamples: <Uint8List>[sample0],
        ivs: <Uint8List>[wrapIv],
        ivSize: 16,
        originalFourcc: 'hev1',
        useCo64: true,
        useSaizFlags1: true,
        useSaioV1: true,
        subsamples: <List<({int clearBytes, int encBytes})>>[subs],
        durationSeconds: 132,
      );

      final (moovOff, moovSz) = HongguoCencDecryptor.findBox(fullMp4, 'moov', 0);
      final prepared = HongguoCencDecryptor.prepareFromMoov(
        Uint8List.sublistView(fullMp4, moovOff, moovOff + moovSz),
        moovFileOffset: moovOff,
      );
      expect(prepared.metadata.durationMs, 132000);
      expect(prepared.metadata.primaryVideoTrack!.originalFourcc, 'hev1');
      expect(prepared.auxRanges, isNotEmpty);

      prepared.finalizeWithAuxChunks((off, len) {
        return Uint8List.sublistView(fullMp4, off, off + len);
      });
      expect(prepared.spans.length, 3);

      // Decrypt through arbitrary uneven HTTP Range slices (e.g. 13 bytes at a time!).
      final reassembled = Uint8List(fullMp4.length);
      var pos = 0;
      const step = 13;
      while (pos < fullMp4.length) {
        final end = min(fullMp4.length, pos + step);
        final chunk = Uint8List.fromList(Uint8List.sublistView(fullMp4, pos, end));
        prepared.decryptRange(pos, chunk, contentKey: key);
        reassembled.setAll(pos, chunk);
        pos = end;
      }

      final fullDecrypted = HongguoPreparedCenc.decryptFullBytes(fullMp4, key);
      expect(reassembled, fullDecrypted);

      // Locate sample0 bytes in reassembled MP4 and match original plain sample0 byte-for-byte.
      final mdatOff = HongguoCencDecryptor.findBox(fullMp4, 'mdat', 0).$1 + 8;
      expect(
        reassembled.sublist(mdatOff, mdatOff + sample0.length),
        sample0,
      );
    });

    test('HongguoRemoteVideo streams 206 Partial Content chunks to file with exact decryption', () async {
      final key = Uint8List.fromList(List<int>.generate(16, (i) => 0x33 + i));
      final samples = List<Uint8List>.generate(
        8,
        (s) => Uint8List.fromList(List<int>.generate(256, (i) => (s * 31 + i) & 0xFF)),
      );
      final ivs = List<Uint8List>.generate(
        8,
        (s) => Uint8List.fromList(List<int>.generate(8, (i) => (s * 7 + i) & 0xFF)),
      );
      final fullMp4 = _buildSyntheticCencMp4(
        contentKey: key,
        plainSamples: samples,
        ivs: ivs,
        ivSize: 8,
        originalFourcc: 'avc1',
        useCo64: false,
        useSaizFlags1: false,
        useSaioV1: false,
        durationSeconds: 77,
      );
      final expectedDecrypted = HongguoPreparedCenc.decryptFullBytes(fullMp4, key);

      var rangeCalls = 0;
      final dio = Dio();
      dio.httpClientAdapter = _MockRangeAdapter((options) async {
        rangeCalls++;
        final range = options.headers['Range']?.toString() ?? 'bytes=0-${fullMp4.length - 1}';
        final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
        final start = int.parse(m.group(1)!);
        final end = min(fullMp4.length - 1, int.parse(m.group(2)!));
        final slice = fullMp4.sublist(start, end + 1);
        return ResponseBody.fromBytes(
          slice,
          206,
          headers: <String, List<String>>{
            'content-range': <String>['bytes $start-$end/${fullMp4.length}'],
            'content-length': <String>['${slice.length}'],
          },
        );
      });

      final tempDir = await Directory.systemTemp.createTemp('hg_remote_video_');
      try {
        final remote = HongguoRemoteVideo(
          url: 'https://cdn.example.com/video.mp4',
          contentKey: key,
          dio: dio,
        );
        final outFile = File('${tempDir.path}/out.mp4');
        await remote.streamDecryptedToFile(outFile, chunkSize: 199);

        expect(remote.durationMs, 77000);
        expect(await outFile.readAsBytes(), expectedDecrypted);
        expect(rangeCalls, greaterThan(3));
        remote.close();
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}

class _MockRangeAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) handler;

  _MockRangeAdapter(this.handler);

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
