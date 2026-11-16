import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Mô tả một MP4 box đã parse (hỗ trợ cả extended 64-bit `size == 1` và `size == 0`).
class Mp4BoxRef {
  final String type;
  final int offset;
  final int headerSize;
  final int size;

  const Mp4BoxRef({
    required this.type,
    required this.offset,
    required this.headerSize,
    required this.size,
  });

  int get payloadOffset => offset + headerSize;
  int get endOffset => offset + size;
  int get payloadSize => size - headerSize;
}

/// Thông tin track trích từ `moov`.
class Mp4VideoTrackInfo {
  final String handlerType;
  final String originalFourcc;
  final String sampleEntryFourcc;
  final int width;
  final int height;
  final int durationMs;
  final bool isEncrypted;

  const Mp4VideoTrackInfo({
    required this.handlerType,
    required this.originalFourcc,
    required this.sampleEntryFourcc,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.isEncrypted,
  });
}

/// Siêu dữ liệu tổng hợp từ MP4 `moov`.
class Mp4ContainerMetadata {
  final int durationMs;
  final List<Mp4VideoTrackInfo> tracks;

  const Mp4ContainerMetadata({
    required this.durationMs,
    required this.tracks,
  });

  Mp4VideoTrackInfo? get primaryVideoTrack {
    for (final t in tracks) {
      if (t.handlerType == 'vide') return t;
    }
    return tracks.isNotEmpty ? tracks.first : null;
  }
}

/// Một khoảng byte được mã hoá AES-128-CTR (một phần hoặc toàn bộ sample).
class CencEncryptedSpan {
  final int start;
  final int end;
  final Uint8List iv16;
  final int cipherOffset;

  const CencEncryptedSpan({
    required this.start,
    required this.end,
    required this.iv16,
    required this.cipherOffset,
  });
}

/// Bản vá header tại offset tuyệt đối trong file (ví dụ `encv` -> `avc1`, `sinf` -> `free`).
class Mp4HeaderPatch {
  final int fileOffset;
  final Uint8List replacementBytes;

  const Mp4HeaderPatch({
    required this.fileOffset,
    required this.replacementBytes,
  });
}

/// Một dải byte dữ liệu phụ trợ CENC (SAIO/SAIZ) cần đọc từ file/HTTP trước khi giải mã stream.
class CencAuxFetchRange {
  final int start;
  final int end;

  const CencAuxFetchRange({required this.start, required this.end});
  int get length => end - start;
}

class _ParsedTrackCrypto {
  final List<int> sampleOffsets;
  final List<int> sampleSizes;
  final List<int> auxOffsets;
  final List<int> auxSizes;
  final int ivSize;
  final List<_InlineSencEntry>? inlineSenc;

  const _ParsedTrackCrypto({
    required this.sampleOffsets,
    required this.sampleSizes,
    required this.auxOffsets,
    required this.auxSizes,
    required this.ivSize,
    this.inlineSenc,
  });
}

class _InlineSencEntry {
  final Uint8List iv16;
  final List<({int clearBytes, int encBytes})> subsamples;

  const _InlineSencEntry({required this.iv16, required this.subsamples});
}

/// Bộ giải mã & phân tích ISO BMFF / CENC đầy đủ (hỗ trợ `co64`, `saiz` `flags&1`, `saio` 64-bit,
/// subsample CENC, khôi phục `frma` và giải mã stream theo `decryptRange`).
class HongguoPreparedCenc {
  final Mp4ContainerMetadata metadata;
  final List<Mp4HeaderPatch> headerPatches;
  final List<CencAuxFetchRange> auxRanges;
  final List<_ParsedTrackCrypto> _tracks;
  List<CencEncryptedSpan> _spans = const <CencEncryptedSpan>[];
  bool _finalized = false;

  HongguoPreparedCenc._(
    this._tracks, {
    required this.metadata,
    required this.headerPatches,
    required this.auxRanges,
  });

  bool get isFinalized => _finalized;
  bool get hasEncryptedTracks =>
      _tracks.isNotEmpty || metadata.tracks.any((t) => t.isEncrypted);
  List<CencEncryptedSpan> get spans => _spans;

  /// Bước 1: Parse `moov` để lấy metadata, danh sách vá `frma`/`sinf` và các vùng `saio`/`saiz` cần đọc.
  static HongguoPreparedCenc parseMoov(
    Uint8List moovBytes, {
    required int moovFileOffset,
  }) {
    final bd = ByteData.sublistView(moovBytes);
    final root = Mp4BoxScanner.readBoxHeader(moovBytes, bd, 0, moovBytes.length);
    final int moovPayloadStart;
    final int moovPayloadEnd;
    if (root != null && root.type == 'moov') {
      moovPayloadStart = root.payloadOffset;
      moovPayloadEnd = root.endOffset;
    } else {
      moovPayloadStart = 0;
      moovPayloadEnd = moovBytes.length;
    }

    var mvhdDurationMs = 0;
    final trackInfos = <Mp4VideoTrackInfo>[];
    final parsedTracks = <_ParsedTrackCrypto>[];
    final headerPatches = <Mp4HeaderPatch>[];

    for (final child in Mp4BoxScanner.iterChildren(
      moovBytes,
      bd,
      moovPayloadStart,
      moovPayloadEnd,
    )) {
      if (child.type == 'mvhd') {
        mvhdDurationMs = _parseMvhdDurationMs(moovBytes, bd, child);
      } else if (child.type == 'trak') {
        final trackResult = _parseTrak(
          moovBytes,
          bd,
          child,
          moovFileOffset: moovFileOffset,
        );
        if (trackResult.info != null) {
          trackInfos.add(trackResult.info!);
        }
        headerPatches.addAll(trackResult.patches);
        if (trackResult.crypto != null) {
          parsedTracks.add(trackResult.crypto!);
        }
      }
    }

    var bestDurationMs = mvhdDurationMs;
    if (bestDurationMs <= 0) {
      for (final info in trackInfos) {
        if (info.durationMs > bestDurationMs) {
          bestDurationMs = info.durationMs;
        }
      }
    }

    final auxRanges = _collectCoalescedAuxRanges(parsedTracks);
    final instance = HongguoPreparedCenc._(
      parsedTracks,
      metadata: Mp4ContainerMetadata(
        durationMs: bestDurationMs,
        tracks: trackInfos,
      ),
      headerPatches: headerPatches,
      auxRanges: auxRanges,
    );

    if (auxRanges.isEmpty) {
      instance._buildSpansWithAuxReader(null);
    }
    return instance;
  }

  /// Bước 2 (streaming): Hoàn thiện bảng IV / subsample từ các dải byte phụ trợ đã tải về.
  void finalizeWithAuxChunks(
    Uint8List? Function(int fileOffset, int length) readAuxSlice,
  ) {
    _buildSpansWithAuxReader(readAuxSlice);
  }

  /// Bước 2 (full-file): Hoàn thiện từ buffer MP4 đầy đủ.
  void finalizeFromFullBuffer(Uint8List fullMp4) {
    _buildSpansWithAuxReader((offset, length) {
      if (offset < 0 || offset + length > fullMp4.length) return null;
      return Uint8List.sublistView(fullMp4, offset, offset + length);
    });
  }

  void _buildSpansWithAuxReader(
    Uint8List? Function(int fileOffset, int length)? readAuxSlice,
  ) {
    final allSpans = <CencEncryptedSpan>[];

    for (final track in _tracks) {
      final count = track.sampleOffsets.length;
      if (track.inlineSenc != null && track.auxOffsets.isEmpty) {
        final senc = track.inlineSenc!;
        final limit = min(count, senc.length);
        for (var s = 0; s < limit; s++) {
          final entry = senc[s];
          _appendSampleSpans(
            allSpans,
            sampleOffset: track.sampleOffsets[s],
            sampleSize: track.sampleSizes[s],
            iv16: entry.iv16,
            subsamples: entry.subsamples,
          );
        }
        continue;
      }

      if (readAuxSlice == null) continue;
      final limit = min(
        count,
        min(track.auxOffsets.length, track.auxSizes.length),
      );
      for (var s = 0; s < limit; s++) {
        final auxSize = track.auxSizes[s];
        final auxOff = track.auxOffsets[s];
        if (auxSize < 8 || auxOff < 0) continue;
        final auxBytes = readAuxSlice(auxOff, auxSize);
        if (auxBytes == null || auxBytes.length < 8) continue;

        final ivLen = _resolveSampleIvLen(auxBytes.length, track.ivSize);
        if (auxBytes.length < ivLen) continue;
        final iv16 = Uint8List(16);
        iv16.setAll(0, Uint8List.sublistView(auxBytes, 0, ivLen));

        if (auxBytes.length == ivLen || auxBytes.length < ivLen + 2) {
          _appendSampleSpans(
            allSpans,
            sampleOffset: track.sampleOffsets[s],
            sampleSize: track.sampleSizes[s],
            iv16: iv16,
            subsamples: null,
          );
        } else {
          final auxBd = ByteData.sublistView(auxBytes);
          final subCount = auxBd.getUint16(ivLen, Endian.big);
          final subsamples = <({int clearBytes, int encBytes})>[];
          var pos = ivLen + 2;
          for (var k = 0; k < subCount && pos + 6 <= auxBytes.length; k++) {
            final clearB = auxBd.getUint16(pos, Endian.big);
            final encB = auxBd.getUint32(pos + 2, Endian.big);
            subsamples.add((clearBytes: clearB, encBytes: encB));
            pos += 6;
          }
          _appendSampleSpans(
            allSpans,
            sampleOffset: track.sampleOffsets[s],
            sampleSize: track.sampleSizes[s],
            iv16: iv16,
            subsamples: subsamples,
          );
        }
      }
    }

    allSpans.sort((a, b) => a.start.compareTo(b.start));
    _spans = allSpans;
    _finalized = true;
  }

  static void _appendSampleSpans(
    List<CencEncryptedSpan> out, {
    required int sampleOffset,
    required int sampleSize,
    required Uint8List iv16,
    required List<({int clearBytes, int encBytes})>? subsamples,
  }) {
    if (sampleSize <= 0) return;
    if (subsamples == null || subsamples.isEmpty) {
      out.add(
        CencEncryptedSpan(
          start: sampleOffset,
          end: sampleOffset + sampleSize,
          iv16: iv16,
          cipherOffset: 0,
        ),
      );
      return;
    }

    var filePos = sampleOffset;
    final sampleEnd = sampleOffset + sampleSize;
    var cipherPos = 0;
    for (final sub in subsamples) {
      filePos += sub.clearBytes;
      if (filePos >= sampleEnd) break;
      if (sub.encBytes > 0) {
        final spanEnd = min(sampleEnd, filePos + sub.encBytes);
        if (spanEnd > filePos) {
          out.add(
            CencEncryptedSpan(
              start: filePos,
              end: spanEnd,
              iv16: iv16,
              cipherOffset: cipherPos,
            ),
          );
          cipherPos += spanEnd - filePos;
        }
        filePos = spanEnd;
      }
    }
  }

  static int _resolveSampleIvLen(int auxSize, int tencIvSize) {
    if (tencIvSize == 8 || tencIvSize == 16) {
      if (auxSize == tencIvSize ||
          (auxSize >= tencIvSize + 2 && (auxSize - tencIvSize - 2) % 6 == 0)) {
        return tencIvSize;
      }
    }
    if (auxSize == 16 || (auxSize >= 18 && (auxSize - 18) % 6 == 0)) {
      return 16;
    }
    if (auxSize == 8 || (auxSize >= 10 && (auxSize - 10) % 6 == 0)) {
      return 8;
    }
    return tencIvSize > 0 ? tencIvSize : 8;
  }

  /// Giải mã tại chỗ một chunk byte bất kỳ ở `[fileOffset, fileOffset + buffer.length)`.
  ///
  /// Tự động áp dụng cả vá header (`encv/enca -> frma`, `sinf -> free`) lẫn giải mã AES-CTR CENC
  /// với bộ đếm 128-bit đầy đủ và offset subsample chính xác.
  void decryptRange(
    int fileOffset,
    Uint8List buffer, {
    Uint8List? contentKey,
    int? bufferLen,
  }) {
    final len = bufferLen ?? buffer.length;
    if (len <= 0) return;
    final rangeEnd = fileOffset + len;

    // 1. Áp dụng bản vá header MP4 (`encv/enca -> frma`, `sinf -> free`) trùng dải.
    for (final patch in headerPatches) {
      final pEnd = patch.fileOffset + patch.replacementBytes.length;
      if (patch.fileOffset < rangeEnd && pEnd > fileOffset) {
        final start = max(fileOffset, patch.fileOffset);
        final end = min(rangeEnd, pEnd);
        for (var pos = start; pos < end; pos++) {
          buffer[pos - fileOffset] =
              patch.replacementBytes[pos - patch.fileOffset];
        }
      }
    }

    if (contentKey == null || contentKey.length != 16 || _spans.isEmpty) {
      return;
    }

    // 2. Binary search span đầu tiên có span.end > fileOffset.
    var lo = 0;
    var hi = _spans.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_spans[mid].end <= fileOffset) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo >= _spans.length) return;

    final engine = AESEngine()..init(true, KeyParameter(contentKey));
    final counterBlock = Uint8List(16);
    final keystream = Uint8List(16);
    CencEncryptedSpan? cachedSpan;
    var cachedBlockIdx = -1;

    for (var i = lo; i < _spans.length; i++) {
      final span = _spans[i];
      if (span.start >= rangeEnd) break;
      final start = max(fileOffset, span.start);
      final end = min(rangeEnd, span.end);
      var cipherPos = span.cipherOffset + (start - span.start);

      for (var pos = start; pos < end; pos++) {
        final blockIdx = cipherPos >> 4;
        final inBlock = cipherPos & 15;
        if (!identical(cachedSpan, span) || cachedBlockIdx != blockIdx) {
          _fillCounter128(counterBlock, span.iv16, blockIdx);
          engine.processBlock(counterBlock, 0, keystream, 0);
          cachedSpan = span;
          cachedBlockIdx = blockIdx;
        }
        buffer[pos - fileOffset] ^= keystream[inBlock];
        cipherPos++;
      }
    }
  }

  /// Cộng `blockIdx` vào bộ đếm 128-bit big-endian (có wrap modulo 2^128).
  static void _fillCounter128(Uint8List out, Uint8List iv16, int blockIdx) {
    out.setAll(0, iv16);
    var carry = blockIdx;
    for (var i = 15; i >= 0 && carry > 0; i--) {
      final sum = out[i] + (carry & 0xFF);
      out[i] = sum & 0xFF;
      carry = (carry >>> 8) + (sum >>> 8);
    }
  }

  /// Giải mã toàn bộ MP4 CENC in-memory trong một bước (dùng cho test & file nhỏ).
  static Uint8List decryptFullBytes(Uint8List data, Uint8List contentKey) {
    final bd = ByteData.sublistView(data);
    Mp4BoxRef? moovBox;
    for (final box in Mp4BoxScanner.iterChildren(data, bd, 0, data.length)) {
      if (box.type == 'moov') {
        moovBox = box;
        break;
      }
    }
    if (moovBox == null) {
      return Uint8List.fromList(data);
    }
    final moovSlice = Uint8List.sublistView(data, moovBox.offset, moovBox.endOffset);
    final prepared = parseMoov(moovSlice, moovFileOffset: moovBox.offset);
    prepared.finalizeFromFullBuffer(data);

    final out = Uint8List.fromList(data);
    prepared.decryptRange(0, out, contentKey: contentKey);
    return out;
  }

  /// Thăm dò nhanh thời lượng và thông tin codec từ buffer header `moov`.
  static Mp4ContainerMetadata? probeMoovMetadata(
    Uint8List moovBytes, {
    int moovFileOffset = 0,
  }) {
    try {
      final parsed = parseMoov(moovBytes, moovFileOffset: moovFileOffset);
      return parsed.metadata;
    } catch (_) {
      return null;
    }
  }

  static List<CencAuxFetchRange> _collectCoalescedAuxRanges(
    List<_ParsedTrackCrypto> tracks,
  ) {
    final raw = <CencAuxFetchRange>[];
    for (final t in tracks) {
      final n = min(t.auxOffsets.length, t.auxSizes.length);
      for (var i = 0; i < n; i++) {
        final off = t.auxOffsets[i];
        final sz = t.auxSizes[i];
        if (off >= 0 && sz > 0) {
          raw.add(CencAuxFetchRange(start: off, end: off + sz));
        }
      }
    }
    if (raw.isEmpty) return const <CencAuxFetchRange>[];
    raw.sort((a, b) => a.start.compareTo(b.start));

    const coalesceGapBytes = 64 * 1024;
    final merged = <CencAuxFetchRange>[];
    var curStart = raw.first.start;
    var curEnd = raw.first.end;
    for (var i = 1; i < raw.length; i++) {
      final next = raw[i];
      if (next.start <= curEnd + coalesceGapBytes) {
        if (next.end > curEnd) curEnd = next.end;
      } else {
        merged.add(CencAuxFetchRange(start: curStart, end: curEnd));
        curStart = next.start;
        curEnd = next.end;
      }
    }
    merged.add(CencAuxFetchRange(start: curStart, end: curEnd));
    return merged;
  }

  static int _parseMvhdDurationMs(Uint8List b, ByteData bd, Mp4BoxRef box) {
    final p = box.payloadOffset;
    if (p + 20 > box.endOffset) return 0;
    final version = b[p];
    if (version == 0) {
      final timescale = bd.getUint32(p + 12, Endian.big);
      final duration = bd.getUint32(p + 16, Endian.big);
      if (timescale > 0 && duration > 0 && duration < 0xFFFFFFFF) {
        return (duration * 1000) ~/ timescale;
      }
    } else if (version == 1 && p + 32 <= box.endOffset) {
      final timescale = bd.getUint32(p + 20, Endian.big);
      final duration = bd.getUint64(p + 24, Endian.big);
      if (timescale > 0 && duration > 0) {
        return (duration * 1000) ~/ timescale;
      }
    }
    return 0;
  }

  static ({
    Mp4VideoTrackInfo? info,
    List<Mp4HeaderPatch> patches,
    _ParsedTrackCrypto? crypto,
  }) _parseTrak(
    Uint8List b,
    ByteData bd,
    Mp4BoxRef trakBox, {
    required int moovFileOffset,
  }) {
    var width = 0;
    var height = 0;
    var handlerType = '';
    var mdhdVersion = 0;
    var mdhdTimescale = 0;
    var mdhdDuration = 0;
    Mp4BoxRef? stblBox;

    for (final child in Mp4BoxScanner.iterChildren(
      b,
      bd,
      trakBox.payloadOffset,
      trakBox.endOffset,
    )) {
      if (child.type == 'tkhd') {
        if (child.payloadSize >= 84) {
          final end = child.endOffset;
          width = bd.getUint32(end - 8, Endian.big) >> 16;
          height = bd.getUint32(end - 4, Endian.big) >> 16;
        }
      } else if (child.type == 'mdia') {
        for (final mc in Mp4BoxScanner.iterChildren(
          b,
          bd,
          child.payloadOffset,
          child.endOffset,
        )) {
          if (mc.type == 'mdhd') {
            final p = mc.payloadOffset;
            if (p + 20 <= mc.endOffset) {
              mdhdVersion = b[p];
              if (mdhdVersion == 0) {
                mdhdTimescale = bd.getUint32(p + 12, Endian.big);
                mdhdDuration = bd.getUint32(p + 16, Endian.big);
              } else if (mdhdVersion == 1 && p + 32 <= mc.endOffset) {
                mdhdTimescale = bd.getUint32(p + 20, Endian.big);
                mdhdDuration = bd.getUint64(p + 24, Endian.big);
              }
            }
          } else if (mc.type == 'hdlr') {
            if (mc.payloadSize >= 12) {
              handlerType = ascii.decode(
                Uint8List.sublistView(b, mc.payloadOffset + 8, mc.payloadOffset + 12),
                allowInvalid: true,
              );
            }
          } else if (mc.type == 'minf') {
            stblBox = Mp4BoxScanner.findChild(
              b,
              bd,
              mc.payloadOffset,
              mc.endOffset,
              'stbl',
            );
          }
        }
      }
    }

    if (stblBox == null) {
      return (info: null, patches: const <Mp4HeaderPatch>[], crypto: null);
    }

    final patches = <Mp4HeaderPatch>[];
    var sampleEntryFourcc = '';
    var originalFourcc = '';
    var isEncrypted = false;
    var ivSize = 8;

    Mp4BoxRef? stsdBox;
    Mp4BoxRef? stszBox;
    Mp4BoxRef? stscBox;
    Mp4BoxRef? stcoBox;
    Mp4BoxRef? co64Box;
    Mp4BoxRef? saizBox;
    Mp4BoxRef? saioBox;
    Mp4BoxRef? sencBox;
    Mp4BoxRef? sttsBox;

    for (final sc in Mp4BoxScanner.iterChildren(
      b,
      bd,
      stblBox.payloadOffset,
      stblBox.endOffset,
    )) {
      switch (sc.type) {
        case 'stsd':
          stsdBox = sc;
          break;
        case 'stsz':
          stszBox = sc;
          break;
        case 'stsc':
          stscBox = sc;
          break;
        case 'stco':
          stcoBox = sc;
          break;
        case 'co64':
          co64Box = sc;
          break;
        case 'saiz':
          saizBox = sc;
          break;
        case 'saio':
          saioBox = sc;
          break;
        case 'senc':
          sencBox = sc;
          break;
        case 'stts':
          sttsBox = sc;
          break;
      }
    }

    if (stsdBox != null && stsdBox.payloadSize >= 16) {
      final entryStart = stsdBox.payloadOffset + 8;
      final entryBox = Mp4BoxScanner.readBoxHeader(
        b,
        bd,
        entryStart,
        stsdBox.endOffset,
      );
      if (entryBox != null) {
        sampleEntryFourcc = entryBox.type;
        originalFourcc = entryBox.type;
        if (handlerType == 'vide' && entryBox.payloadSize >= 28 && width == 0) {
          width = bd.getUint16(entryBox.payloadOffset + 24, Endian.big);
          height = bd.getUint16(entryBox.payloadOffset + 26, Endian.big);
        }
        final int fixedFieldsSize;
        if (handlerType == 'vide') {
          fixedFieldsSize = 78;
        } else if (handlerType == 'soun') {
          final ver = entryBox.payloadSize >= 10
              ? bd.getUint16(entryBox.payloadOffset + 8, Endian.big)
              : 0;
          fixedFieldsSize = ver == 2 ? 64 : (ver == 1 ? 44 : 28);
        } else {
          fixedFieldsSize = entryBox.type == 'encv' ? 78 : 28;
        }

        if (entryBox.payloadSize > fixedFieldsSize) {
          for (final ec in Mp4BoxScanner.iterChildren(
            b,
            bd,
            entryBox.payloadOffset + fixedFieldsSize,
            entryBox.endOffset,
          )) {
            if (ec.type == 'sinf') {
              isEncrypted = true;
              patches.add(
                Mp4HeaderPatch(
                  fileOffset: moovFileOffset + ec.offset + 4,
                  replacementBytes: Uint8List.fromList(ascii.encode('free')),
                ),
              );
              for (final sinfChild in Mp4BoxScanner.iterChildren(
                b,
                bd,
                ec.payloadOffset,
                ec.endOffset,
              )) {
                if (sinfChild.type == 'frma' && sinfChild.payloadSize >= 4) {
                  final frmaBytes = Uint8List.fromList(
                    Uint8List.sublistView(
                      b,
                      sinfChild.payloadOffset,
                      sinfChild.payloadOffset + 4,
                    ),
                  );
                  originalFourcc = ascii.decode(frmaBytes, allowInvalid: true);
                  if (sampleEntryFourcc == 'encv' || sampleEntryFourcc == 'enca') {
                    patches.add(
                      Mp4HeaderPatch(
                        fileOffset: moovFileOffset + entryBox.offset + 4,
                        replacementBytes: frmaBytes,
                      ),
                    );
                  }
                } else if (sinfChild.type == 'schi') {
                  final tencBox = Mp4BoxScanner.findChild(
                    b,
                    bd,
                    sinfChild.payloadOffset,
                    sinfChild.endOffset,
                    'tenc',
                  );
                  if (tencBox != null && tencBox.payloadSize >= 8) {
                    final tencIv = b[tencBox.payloadOffset + 7];
                    if (tencIv == 8 || tencIv == 16) {
                      ivSize = tencIv;
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    var durationMs = 0;
    if (mdhdTimescale > 0 &&
        mdhdDuration > 0 &&
        (mdhdVersion == 1 || mdhdDuration < 0xFFFFFFFF)) {
      durationMs = (mdhdDuration * 1000) ~/ mdhdTimescale;
    } else if (mdhdTimescale > 0 && sttsBox != null && sttsBox.payloadSize >= 8) {
      final sp = sttsBox.payloadOffset;
      final ec = bd.getUint32(sp + 4, Endian.big);
      var totalTicks = 0;
      for (var i = 0; i < ec && sp + 8 + i * 8 + 8 <= sttsBox.endOffset; i++) {
        final cnt = bd.getUint32(sp + 8 + i * 8, Endian.big);
        final delta = bd.getUint32(sp + 12 + i * 8, Endian.big);
        totalTicks += cnt * delta;
      }
      if (totalTicks > 0) {
        durationMs = (totalTicks * 1000) ~/ mdhdTimescale;
      }
    }

    final trackInfo = Mp4VideoTrackInfo(
      handlerType: handlerType,
      originalFourcc: originalFourcc,
      sampleEntryFourcc: sampleEntryFourcc,
      width: width,
      height: height,
      durationMs: durationMs,
      isEncrypted: isEncrypted || saizBox != null || saioBox != null || sencBox != null,
    );

    final bool needsCrypto = isEncrypted || saizBox != null || saioBox != null || sencBox != null;
    if (!needsCrypto || stszBox == null || (stcoBox == null && co64Box == null)) {
      return (info: trackInfo, patches: patches, crypto: null);
    }

    final sampleSizes = _parseStsz(b, bd, stszBox);
    final chunkOffsets = co64Box != null
        ? _parseCo64(bd, co64Box)
        : _parseStco(bd, stcoBox!);
    final stscRuns = stscBox != null
        ? _parseStsc(bd, stscBox)
        : const <({int firstChunk, int samplesPerChunk})>[
            (firstChunk: 1, samplesPerChunk: 1),
          ];

    final samplesPerChunkList = _expandSamplesPerChunk(stscRuns, chunkOffsets.length);
    final sampleOffsets = List<int>.filled(sampleSizes.length, 0);
    var sIdx = 0;
    for (var c = 0; c < chunkOffsets.length && sIdx < sampleSizes.length; c++) {
      var off = chunkOffsets[c];
      final nInChunk = samplesPerChunkList[c];
      for (var k = 0; k < nInChunk && sIdx < sampleSizes.length; k++) {
        sampleOffsets[sIdx] = off;
        off += sampleSizes[sIdx];
        sIdx++;
      }
    }

    final auxSizes = saizBox != null ? _parseSaiz(b, bd, saizBox) : const <int>[];
    final saioEntries = saioBox != null ? _parseSaio(b, bd, saioBox) : const <int>[];
    final auxOffsets = _resolveAuxOffsets(
      saioEntries: saioEntries,
      auxSizes: auxSizes,
      samplesPerChunk: samplesPerChunkList,
      sampleCount: sampleSizes.length,
    );

    List<_InlineSencEntry>? inlineSenc;
    if (auxOffsets.isEmpty && sencBox != null) {
      inlineSenc = _parseSenc(b, bd, sencBox, ivSize: ivSize);
    }

    return (
      info: trackInfo,
      patches: patches,
      crypto: _ParsedTrackCrypto(
        sampleOffsets: sampleOffsets,
        sampleSizes: sampleSizes,
        auxOffsets: auxOffsets,
        auxSizes: auxSizes,
        ivSize: ivSize,
        inlineSenc: inlineSenc,
      ),
    );
  }

  static List<int> _parseStsz(Uint8List b, ByteData bd, Mp4BoxRef box) {
    final p = box.payloadOffset;
    if (p + 12 > box.endOffset) return const <int>[];
    final sampleSize = bd.getUint32(p + 4, Endian.big);
    final sampleCount = bd.getUint32(p + 8, Endian.big);
    if (sampleCount == 0) return const <int>[];
    if (sampleSize > 0) {
      return List<int>.filled(sampleCount, sampleSize);
    }
    final out = <int>[];
    var pos = p + 12;
    for (var i = 0; i < sampleCount && pos + 4 <= box.endOffset; i++) {
      out.add(bd.getUint32(pos, Endian.big));
      pos += 4;
    }
    return out;
  }

  static List<int> _parseStco(ByteData bd, Mp4BoxRef box) {
    final p = box.payloadOffset;
    if (p + 8 > box.endOffset) return const <int>[];
    final count = bd.getUint32(p + 4, Endian.big);
    final out = <int>[];
    var pos = p + 8;
    for (var i = 0; i < count && pos + 4 <= box.endOffset; i++) {
      out.add(bd.getUint32(pos, Endian.big));
      pos += 4;
    }
    return out;
  }

  static List<int> _parseCo64(ByteData bd, Mp4BoxRef box) {
    final p = box.payloadOffset;
    if (p + 8 > box.endOffset) return const <int>[];
    final count = bd.getUint32(p + 4, Endian.big);
    final out = <int>[];
    var pos = p + 8;
    for (var i = 0; i < count && pos + 8 <= box.endOffset; i++) {
      out.add(bd.getUint64(pos, Endian.big));
      pos += 8;
    }
    return out;
  }

  static List<({int firstChunk, int samplesPerChunk})> _parseStsc(
    ByteData bd,
    Mp4BoxRef box,
  ) {
    final p = box.payloadOffset;
    if (p + 8 > box.endOffset) return const <({int firstChunk, int samplesPerChunk})>[];
    final count = bd.getUint32(p + 4, Endian.big);
    final runs = <({int firstChunk, int samplesPerChunk})>[];
    var pos = p + 8;
    for (var i = 0; i < count && pos + 12 <= box.endOffset; i++) {
      runs.add((
        firstChunk: bd.getUint32(pos, Endian.big),
        samplesPerChunk: bd.getUint32(pos + 4, Endian.big),
      ));
      pos += 12;
    }
    return runs;
  }

  static List<int> _expandSamplesPerChunk(
    List<({int firstChunk, int samplesPerChunk})> runs,
    int chunkCount,
  ) {
    if (chunkCount <= 0) return const <int>[];
    if (runs.isEmpty) return List<int>.filled(chunkCount, 1);
    final out = List<int>.filled(chunkCount, 1);
    for (var r = 0; r < runs.length; r++) {
      final startChunk = max(0, runs[r].firstChunk - 1);
      final endChunk = r + 1 < runs.length
          ? min(chunkCount, runs[r + 1].firstChunk - 1)
          : chunkCount;
      for (var c = startChunk; c < endChunk; c++) {
        out[c] = runs[r].samplesPerChunk;
      }
    }
    return out;
  }

  static List<int> _parseSaiz(Uint8List b, ByteData bd, Mp4BoxRef box) {
    final p = box.payloadOffset;
    if (p + 9 > box.endOffset) return const <int>[];
    final flags = (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
    var cursor = p + 4;
    if ((flags & 1) != 0) {
      cursor += 8;
    }
    if (cursor + 5 > box.endOffset) return const <int>[];
    final defaultSize = b[cursor];
    final count = bd.getUint32(cursor + 1, Endian.big);
    if (count == 0) return const <int>[];
    if (defaultSize > 0) {
      return List<int>.filled(count, defaultSize);
    }
    final dataStart = cursor + 5;
    final available = max(0, box.endOffset - dataStart);
    final limit = min(count, available);
    return List<int>.generate(limit, (i) => b[dataStart + i]);
  }

  static List<int> _parseSaio(Uint8List b, ByteData bd, Mp4BoxRef box) {
    final p = box.payloadOffset;
    if (p + 8 > box.endOffset) return const <int>[];
    final version = b[p];
    final flags = (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
    var cursor = p + 4;
    if ((flags & 1) != 0) {
      cursor += 8;
    }
    if (cursor + 4 > box.endOffset) return const <int>[];
    final count = bd.getUint32(cursor, Endian.big);
    cursor += 4;
    final out = <int>[];
    if (version == 0) {
      for (var i = 0; i < count && cursor + 4 <= box.endOffset; i++) {
        out.add(bd.getUint32(cursor, Endian.big));
        cursor += 4;
      }
    } else {
      for (var i = 0; i < count && cursor + 8 <= box.endOffset; i++) {
        out.add(bd.getUint64(cursor, Endian.big));
        cursor += 8;
      }
    }
    return out;
  }

  static List<int> _resolveAuxOffsets({
    required List<int> saioEntries,
    required List<int> auxSizes,
    required List<int> samplesPerChunk,
    required int sampleCount,
  }) {
    if (saioEntries.isEmpty || auxSizes.isEmpty || sampleCount <= 0) {
      return const <int>[];
    }
    final count = min(auxSizes.length, sampleCount);
    final out = List<int>.filled(count, -1);

    if (saioEntries.length == 1) {
      var cursor = saioEntries.first;
      for (var s = 0; s < count; s++) {
        out[s] = cursor;
        cursor += auxSizes[s];
      }
      return out;
    }

    if (saioEntries.length == samplesPerChunk.length) {
      var sIdx = 0;
      for (var c = 0; c < samplesPerChunk.length && sIdx < count; c++) {
        var cursor = saioEntries[c];
        final n = samplesPerChunk[c];
        for (var k = 0; k < n && sIdx < count; k++) {
          out[sIdx] = cursor;
          cursor += auxSizes[sIdx];
          sIdx++;
        }
      }
      return out;
    }

    if (saioEntries.length >= count) {
      for (var s = 0; s < count; s++) {
        out[s] = saioEntries[s];
      }
      return out;
    }

    return const <int>[];
  }

  static List<_InlineSencEntry> _parseSenc(
    Uint8List b,
    ByteData bd,
    Mp4BoxRef box, {
    required int ivSize,
  }) {
    final p = box.payloadOffset;
    if (p + 8 > box.endOffset) return const <_InlineSencEntry>[];
    final flags = (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
    final hasSubsamples = (flags & 2) != 0;
    final sampleCount = bd.getUint32(p + 4, Endian.big);
    var cursor = p + 8;
    final out = <_InlineSencEntry>[];

    for (var i = 0; i < sampleCount && cursor + ivSize <= box.endOffset; i++) {
      final iv16 = Uint8List(16);
      iv16.setAll(0, Uint8List.sublistView(b, cursor, cursor + ivSize));
      cursor += ivSize;
      final subsamples = <({int clearBytes, int encBytes})>[];
      if (hasSubsamples && cursor + 2 <= box.endOffset) {
        final subCount = bd.getUint16(cursor, Endian.big);
        cursor += 2;
        for (var k = 0; k < subCount && cursor + 6 <= box.endOffset; k++) {
          subsamples.add((
            clearBytes: bd.getUint16(cursor, Endian.big),
            encBytes: bd.getUint32(cursor + 2, Endian.big),
          ));
          cursor += 6;
        }
      }
      out.add(_InlineSencEntry(iv16: iv16, subsamples: subsamples));
    }
    return out;
  }
}

/// Bộ duyệt cây ISO BMFF (hỗ trợ extended 64-bit `size == 1` và `size == 0`).
class Mp4BoxScanner {
  Mp4BoxScanner._();

  static Mp4BoxRef? readBoxHeader(
    Uint8List data,
    ByteData bd,
    int offset,
    int containerEnd,
  ) {
    if (offset < 0 || offset + 8 > containerEnd) return null;
    final size32 = bd.getUint32(offset, Endian.big);
    final type = ascii.decode(
      Uint8List.sublistView(data, offset + 4, offset + 8),
      allowInvalid: true,
    );
    int headerSize;
    int size;
    if (size32 == 1) {
      if (offset + 16 > containerEnd) return null;
      size = bd.getUint64(offset + 8, Endian.big);
      headerSize = 16;
    } else if (size32 == 0) {
      size = containerEnd - offset;
      headerSize = 8;
    } else if (size32 < 8) {
      return null;
    } else {
      size = size32;
      headerSize = 8;
    }
    if (size < headerSize) return null;
    final cappedEnd = min(containerEnd, offset + size);
    if (cappedEnd < offset + headerSize) return null;
    return Mp4BoxRef(
      type: type,
      offset: offset,
      headerSize: headerSize,
      size: cappedEnd - offset,
    );
  }

  static Iterable<Mp4BoxRef> iterChildren(
    Uint8List data,
    ByteData bd,
    int start,
    int end,
  ) sync* {
    var cursor = start;
    while (cursor + 8 <= end) {
      final box = readBoxHeader(data, bd, cursor, end);
      if (box == null || box.size <= 0) break;
      yield box;
      cursor = box.endOffset;
    }
  }

  static Mp4BoxRef? findChild(
    Uint8List data,
    ByteData bd,
    int start,
    int end,
    String fourcc,
  ) {
    for (final child in iterChildren(data, bd, start, end)) {
      if (child.type == fourcc) return child;
    }
    return null;
  }
}
