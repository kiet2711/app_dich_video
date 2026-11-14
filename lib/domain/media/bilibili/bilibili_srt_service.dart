import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../../data/api/capcut_stt_client.dart';
import '../../../data/api/capcut_vod_uploader.dart';
import '../../../data/model/device_config.dart';
import '../../../data/model/subtitle_document.dart';
import '../../../data/model/subtitle_item.dart';
import '../../../data/repository/history_repository.dart';
import '../../pipeline/subtitling_pipeline.dart';
import '../audio_chunker.dart';
import '../bilibili_resolver.dart';

enum BilibiliSrtSourceKind {
  memoryCache,
  historyCache,
  bilibiliCc,
  capcutStt,
  none,
}

class SrtChunkSlice {
  final int chunkNumber; // 1-based
  final int startMs;
  final int endMs;
  final int startCueIndex;
  final int endCueIndex;
  final String timeRangeLabel;
  final String previewText;
  final String compactTranscript;

  const SrtChunkSlice({
    required this.chunkNumber,
    required this.startMs,
    required this.endMs,
    required this.startCueIndex,
    required this.endCueIndex,
    required this.timeRangeLabel,
    required this.previewText,
    required this.compactTranscript,
  });

  int get cueCount => (endCueIndex - startCueIndex) + 1;
  int get charLength => compactTranscript.length;

  Map<String, dynamic> toMapJson() => {
    'chunkNumber': chunkNumber,
    'timeRange': timeRangeLabel,
    'cueCount': cueCount,
    'preview': previewText,
  };
}

class BilibiliSrtSession {
  final String cacheKey;
  final String bvid;
  final int pageIndex;
  final String title;
  final BilibiliSrtSourceKind sourceKind;
  final String languageLabel;
  final SubtitleDocument document;
  final List<SrtChunkSlice> chunks;
  final DateTime createdAt;

  BilibiliSrtSession({
    required this.cacheKey,
    required this.bvid,
    required this.pageIndex,
    required this.title,
    required this.sourceKind,
    required this.languageLabel,
    required this.document,
    required this.chunks,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  int get totalChunks => chunks.length;
  bool get isLongVideo => chunks.length > 2;

  String get sourceLabel {
    return switch (sourceKind) {
      BilibiliSrtSourceKind.memoryCache => 'Bộ nhớ phiên',
      BilibiliSrtSourceKind.historyCache => 'SRT đã lưu',
      BilibiliSrtSourceKind.bilibiliCc =>
        languageLabel.isNotEmpty ? 'CC Bilibili ($languageLabel)' : 'CC Bilibili',
      BilibiliSrtSourceKind.capcutStt => 'CapCut Audio STT',
      BilibiliSrtSourceKind.none => 'Chưa có SRT',
    };
  }

  SrtChunkSlice? chunkAt(int chunkNumber) {
    if (chunkNumber < 1 || chunkNumber > chunks.length) return null;
    return chunks[chunkNumber - 1];
  }

  int chunkNumberForCueIndex(int cueIdx) {
    for (final chunk in chunks) {
      if (cueIdx >= chunk.startCueIndex && cueIdx <= chunk.endCueIndex) {
        return chunk.chunkNumber;
      }
    }
    return 1;
  }

  /// Tạo payload gọn nhẹ cho Gemini Live khi mới nạp SRT:
  /// - Video ngắn (<= 2 đoạn): đẩy trọn cả các đoạn luôn để AI tóm tắt ngay.
  /// - Video dài (>= 3 đoạn): đẩy bản đồ toàn bộ các đoạn (`chunkMap`) + nội dung trọn vẹn Đoạn 1
  ///   để tiết kiệm token (né 65K TPM) và cho phép đào sâu từng đoạn khi user yêu cầu.
  Map<String, dynamic> buildOverviewPayload() {
    if (chunks.isEmpty) {
      return {
        'hasSrt': false,
        'totalChunks': 0,
        'cueCount': 0,
      };
    }

    if (!isLongVideo) {
      return {
        'hasSrt': true,
        'bvid': bvid,
        'page': pageIndex,
        'srtSource': sourceLabel,
        'cueCount': document.size,
        'totalChunks': totalChunks,
        'sentAllChunks': true,
        'chunkMap': chunks.map((c) => c.toMapJson()).toList(),
        'chunks': [
          for (final c in chunks)
            {
              'chunkNumber': c.chunkNumber,
              'timeRange': c.timeRangeLabel,
              'transcript': c.compactTranscript,
            },
        ],
      };
    }

    final first = chunks.first;
    final last = chunks.last;
    return {
      'hasSrt': true,
      'bvid': bvid,
      'page': pageIndex,
      'srtSource': sourceLabel,
      'cueCount': document.size,
      'totalChunks': totalChunks,
      'sentAllChunks': false,
      'chunkMap': chunks.map((c) => c.toMapJson()).toList(),
      'currentChunk': {
        'chunkNumber': first.chunkNumber,
        'timeRange': first.timeRangeLabel,
        'transcript': first.compactTranscript,
      },
      if (last.chunkNumber != first.chunkNumber)
        'endingSnippet': {
          'chunkNumber': last.chunkNumber,
          'timeRange': last.timeRangeLabel,
          'preview': last.previewText,
        },
      'pagingNote':
          'Video dài được chia thành $totalChunks đoạn SRT để giữ ổn định bộ nhớ Live. '
          'Hiện mới gửi Đoạn 1/$totalChunks kèm bản đồ các đoạn (mục `preview` từng đoạn). '
          'Hãy tóm tắt kỹ Đoạn 1 và khái quát khung sườn từ `chunkMap`; '
          'nếu người dùng muốn đào sâu phần nào hãy gọi `read_srt_chunk(chunk_number)` hoặc `search_srt_topic(keywords)`.',
    };
  }

  Map<String, dynamic> readChunkPayload(int chunkNumber) {
    final slice = chunkAt(chunkNumber);
    if (slice == null) {
      return {
        'ok': false,
        'error':
            'Không có Đoạn #$chunkNumber. Video này chỉ có từ Đoạn 1 đến Đoạn $totalChunks.',
        'totalChunks': totalChunks,
      };
    }
    return {
      'ok': true,
      'bvid': bvid,
      'page': pageIndex,
      'srtSource': sourceLabel,
      'chunkNumber': slice.chunkNumber,
      'totalChunks': totalChunks,
      'timeRange': slice.timeRangeLabel,
      'cueCount': slice.cueCount,
      'hasPrev': slice.chunkNumber > 1,
      'hasNext': slice.chunkNumber < totalChunks,
      if (slice.chunkNumber < totalChunks)
        'nextChunkHint': chunkAt(slice.chunkNumber + 1)?.toMapJson(),
      'transcript': slice.compactTranscript,
    };
  }

  Map<String, dynamic> searchTopicPayload(
    List<String> keywords, {
    int maxWindows = 6,
    int contextRadius = 2,
    int maxTotalChars = 2800,
  }) {
    final cleanKeywords = keywords
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList();
    if (cleanKeywords.isEmpty || document.items.isEmpty) {
      return {
        'ok': false,
        'matches': const [],
        'message': 'Chưa có từ khóa hoặc SRT rỗng để tìm kiếm.',
      };
    }

    final hitCueIndices = <int>[];
    for (var i = 0; i < document.items.length; i++) {
      final text = BilibiliSrtChunker.pickCueText(document.items[i]).toLowerCase();
      if (text.isEmpty) continue;
      if (cleanKeywords.any(text.contains)) {
        hitCueIndices.add(i);
      }
    }

    if (hitCueIndices.isEmpty) {
      return {
        'ok': true,
        'bvid': bvid,
        'keywords': keywords,
        'matchCount': 0,
        'matches': const [],
        'chunkMap': chunks.map((c) => c.toMapJson()).toList(),
        'message':
            'Không tìm thấy chính xác từ khóa ${keywords.join(", ")} trong SRT. '
            'Bạn có thể thử từ khóa tiếng Trung đồng nghĩa hoặc đọc từng đoạn qua `read_srt_chunk`.',
      };
    }

    // Gom các cue khớp gần nhau thành vùng ngữ cảnh không trùng lặp
    final mergedRanges = <(int start, int end, int anchor)>[];
    for (final idx in hitCueIndices) {
      final winStart = (idx - contextRadius).clamp(0, document.items.length - 1);
      final winEnd = (idx + contextRadius).clamp(0, document.items.length - 1);
      if (mergedRanges.isNotEmpty && winStart <= mergedRanges.last.$2 + 1) {
        final prev = mergedRanges.removeLast();
        mergedRanges.add((
          prev.$1,
          winEnd > prev.$2 ? winEnd : prev.$2,
          prev.$3,
        ));
      } else {
        mergedRanges.add((winStart, winEnd, idx));
      }
    }

    final snippets = <Map<String, dynamic>>[];
    var usedChars = 0;
    for (final r in mergedRanges.take(maxWindows)) {
      final buf = StringBuffer();
      for (var i = r.$1; i <= r.$2; i++) {
        final item = document.items[i];
        final line = BilibiliSrtChunker.pickCueText(item);
        if (line.isEmpty) continue;
        final ts = BilibiliSrtChunker.formatTimestamp(item.startMs);
        buf.writeln('[$ts] $line');
      }
      final blockText = buf.toString().trim();
      if (blockText.isEmpty) continue;
      if (usedChars + blockText.length > maxTotalChars && snippets.isNotEmpty) {
        break;
      }
      usedChars += blockText.length;
      final startMs = document.items[r.$1].startMs;
      final endMs = document.items[r.$2].endMs;
      snippets.add({
        'chunkNumber': chunkNumberForCueIndex(r.$3),
        'timeRange':
            '${BilibiliSrtChunker.formatTimestamp(startMs)}-${BilibiliSrtChunker.formatTimestamp(endMs)}',
        'excerpt': blockText,
      });
    }

    return {
      'ok': true,
      'bvid': bvid,
      'keywords': keywords,
      'matchCount': hitCueIndices.length,
      'returnedExcerpts': snippets.length,
      'matches': snippets,
    };
  }
}

class BilibiliSrtLoadResult {
  final BilibiliSrtSession? session;
  final bool loginRequiredForCc;
  final bool sttAvailable;
  final String statusNote;

  const BilibiliSrtLoadResult({
    this.session,
    this.loginRequiredForCc = false,
    this.sttAvailable = true,
    this.statusNote = '',
  });
}

class BilibiliSrtChunker {
  BilibiliSrtChunker._();

  static const int defaultMaxChunkChars = 2600;
  static const int defaultMaxChunkDurationMs = 5 * 60 * 1000;

  static String pickCueText(SubtitleItem item) {
    final orig = item.originalText.trim();
    if (orig.isNotEmpty) return orig;
    return item.translatedText.trim();
  }

  static String formatTimestamp(int ms) {
    final safeSec = (ms <= 0 ? 0 : ms ~/ 1000);
    final h = safeSec ~/ 3600;
    final m = (safeSec % 3600) ~/ 60;
    final s = safeSec % 60;
    final mStr = m.toString().padLeft(2, '0');
    final sStr = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mStr:$sStr' : '$mStr:$sStr';
  }

  /// Chia `SubtitleDocument` thành các phân đoạn vừa tầm Gemini Live, đồng thời nén các
  /// câu liên tiếp ngắn thành dạng `[mm:ss] câu 1 câu 2` để giảm ~45-50% token so với SRT thô.
  static List<SrtChunkSlice> chunkDocument(
    SubtitleDocument doc, {
    int maxChunkChars = defaultMaxChunkChars,
    int maxChunkDurationMs = defaultMaxChunkDurationMs,
  }) {
    if (doc.items.isEmpty) return const [];

    final items = List<SubtitleItem>.from(doc.items)
      ..sort((a, b) => a.startMs.compareTo(b.startMs));

    final slices = <SrtChunkSlice>[];
    var chunkStartCueIdx = 0;

    while (chunkStartCueIdx < items.length) {
      final chunkStartMs = items[chunkStartCueIdx].startMs;
      var chunkEndCueIdx = chunkStartCueIdx;
      var chunkEndMs = items[chunkStartCueIdx].endMs;

      final chunkBuf = StringBuffer();
      var groupStartMs = items[chunkStartCueIdx].startMs;
      final groupText = StringBuffer();
      String firstPreview = '';

      void flushGroupLine() {
        final line = groupText.toString().trim();
        if (line.isEmpty) return;
        if (firstPreview.isEmpty) {
          firstPreview = line.length > 90 ? '${line.substring(0, 90)}...' : line;
        }
        chunkBuf.writeln('[${formatTimestamp(groupStartMs)}] $line');
        groupText.clear();
      }

      for (var i = chunkStartCueIdx; i < items.length; i++) {
        final item = items[i];
        final text = pickCueText(item).replaceAll(RegExp(r'\s+'), ' ').trim();
        if (text.isEmpty) {
          chunkEndCueIdx = i;
          continue;
        }

        final projectedDuration = item.endMs - chunkStartMs;
        final projectedChars =
            chunkBuf.length + groupText.length + text.length + 14;
        if (i > chunkStartCueIdx &&
            (projectedChars > maxChunkChars ||
                projectedDuration > maxChunkDurationMs)) {
          break;
        }

        if (groupText.isEmpty) {
          groupStartMs = item.startMs;
        } else if (groupText.length + text.length > 150 ||
            (item.startMs - groupStartMs) > 15000) {
          flushGroupLine();
          groupStartMs = item.startMs;
        }

        if (groupText.isNotEmpty) groupText.write(' ');
        groupText.write(text);
        chunkEndCueIdx = i;
        if (item.endMs > chunkEndMs) {
          chunkEndMs = item.endMs;
        }
      }

      flushGroupLine();

      final transcript = chunkBuf.toString().trim();
      final timeRangeLabel =
          '${formatTimestamp(chunkStartMs)}-${formatTimestamp(chunkEndMs)}';

      if (transcript.isNotEmpty) {
        slices.add(
          SrtChunkSlice(
            chunkNumber: slices.length + 1,
            startMs: chunkStartMs,
            endMs: chunkEndMs,
            startCueIndex: chunkStartCueIdx,
            endCueIndex: chunkEndCueIdx,
            timeRangeLabel: timeRangeLabel,
            previewText: firstPreview,
            compactTranscript: transcript,
          ),
        );
      }

      chunkStartCueIdx = chunkEndCueIdx + 1;
    }

    return slices;
  }
}

typedef BilibiliHistoryDocLoader =
    Future<SubtitleDocument?> Function(String bvid, int pageIndex);

typedef BilibiliSttDocExtractor =
    Future<SubtitleDocument?> Function(
      BilibiliVideoDetails details, {
      required String cookie,
      required String sourceLanguage,
      void Function(double progress, String message)? onProgress,
    });

/// Dịch vụ tải SRT 3 tầng (Cache/History -> CC Bilibili -> CapCut STT khi yêu cầu)
/// và quản lý cắt nhỏ SRT trong bộ nhớ phiên Bilibili.
class BilibiliSrtService {
  final BilibiliResolver resolver;
  final BilibiliHistoryDocLoader? historyDocLoader;
  final BilibiliSttDocExtractor? sttDocExtractor;

  final Map<String, BilibiliSrtSession> _sessions = {};

  BilibiliSrtService({
    BilibiliResolver? resolver,
    this.historyDocLoader,
    this.sttDocExtractor,
  }) : resolver = resolver ?? BilibiliResolver();

  static String makeCacheKey(String bvid, {int pageIndex = 1}) =>
      '${bvid.trim().toUpperCase()}_p${pageIndex < 1 ? 1 : pageIndex}';

  BilibiliSrtSession? getCachedSession(String bvid, {int pageIndex = 1}) {
    final exact = _sessions[makeCacheKey(bvid, pageIndex: pageIndex)];
    if (exact != null) return exact;
    if (pageIndex == 1) {
      final upper = bvid.trim().toUpperCase();
      for (final entry in _sessions.entries) {
        if (entry.key.startsWith('${upper}_p')) return entry.value;
      }
    }
    return null;
  }

  void cacheSession(BilibiliSrtSession session) {
    _sessions[session.cacheKey] = session;
  }

  void clearCache() {
    _sessions.clear();
  }

  BilibiliSrtSession buildAndCacheSession({
    required BilibiliVideoDetails details,
    required SubtitleDocument document,
    required BilibiliSrtSourceKind sourceKind,
    String languageLabel = '',
  }) {
    final doc = SubtitleDocument(List<SubtitleItem>.from(document.items))
      ..reindex();
    final key = makeCacheKey(
      details.bvid,
      pageIndex: details.selectedPageIndex,
    );
    final chunks = BilibiliSrtChunker.chunkDocument(doc);
    final session = BilibiliSrtSession(
      cacheKey: key,
      bvid: details.bvid,
      pageIndex: details.selectedPageIndex,
      title: details.title,
      sourceKind: sourceKind,
      languageLabel: languageLabel,
      document: doc,
      chunks: chunks,
    );
    cacheSession(session);
    return session;
  }

  /// Tầng 1 & 2 (Siêu tốc < 0.5s): Đọc từ cache RAM -> Lịch sử máy -> Phụ đề CC Bilibili.
  /// Không tự chạy STT audio trừ khi user chủ động gọi `extractSrtWithCapCutStt` (Phương án A).
  Future<BilibiliSrtLoadResult> loadFastSrt(
    BilibiliVideoDetails details, {
    String cookie = '',
    String sourceLanguage = 'zh',
  }) async {
    final existing = getCachedSession(
      details.bvid,
      pageIndex: details.selectedPageIndex,
    );
    if (existing != null) {
      return BilibiliSrtLoadResult(
        session: existing,
        statusNote: 'Đã nạp SRT từ bộ nhớ phiên (${existing.totalChunks} đoạn).',
      );
    }

    // Tầng 1b: Kiểm tra file SRT đã xử lý trước đây trong HistoryRepository
    try {
      final historyDoc = await _tryLoadFromHistory(
        details.bvid,
        details.selectedPageIndex,
      );
      if (historyDoc != null && historyDoc.isNotEmpty) {
        final session = buildAndCacheSession(
          details: details,
          document: historyDoc,
          sourceKind: BilibiliSrtSourceKind.historyCache,
          languageLabel: 'Lịch sử',
        );
        return BilibiliSrtLoadResult(
          session: session,
          statusNote:
              'Đã tìm thấy SRT có sẵn trong Lịch sử (${session.totalChunks} đoạn).',
        );
      }
    } catch (_) {}

    // Tầng 2: Kiểm tra CC / AI Subtitle trực tiếp trên Bilibili (< 0.5s)
    var loginRequired = false;
    try {
      final tracks = await resolver.getSubtitles(details, cookie);
      final preferred = SubtitlingPipeline.selectBestBilibiliSubtitle(
        tracks,
        sourceLanguage: sourceLanguage,
      );
      if (preferred != null) {
        final doc = await resolver.downloadSubtitle(preferred);
        if (doc != null && doc.isNotEmpty) {
          final session = buildAndCacheSession(
            details: details,
            document: doc,
            sourceKind: BilibiliSrtSourceKind.bilibiliCc,
            languageLabel: preferred.languageName,
          );
          return BilibiliSrtLoadResult(
            session: session,
            statusNote:
                'Đã tải nhanh phụ đề CC (${preferred.languageName}, ${session.totalChunks} đoạn).',
          );
        }
      }
    } on BilibiliSubtitleLoginRequiredException {
      loginRequired = true;
    } catch (_) {}

    return BilibiliSrtLoadResult(
      session: null,
      loginRequiredForCc: loginRequired,
      sttAvailable: true,
      statusNote: loginRequired
          ? 'Video này Bilibili yêu cầu đăng nhập tài khoản mới mở CC (hoặc có thể tạo SRT nhanh bằng CapCut STT).'
          : 'Video chưa có sẵn phụ đề CC (có thể tạo SRT nhanh bằng CapCut Audio STT nếu muốn đọc chi tiết).',
    );
  }

  /// Tầng 3 (Phương án A - chạy khi người dùng đồng ý/yêu cầu):
  /// Tải luồng audio DASH nhẹ (~64kbps) -> băm đa luồng -> CapCut STT tạo SRT sạch.
  Future<BilibiliSrtLoadResult> extractSrtWithCapCutStt(
    BilibiliVideoDetails details, {
    String cookie = '',
    String sourceLanguage = 'zh',
    int concurrency = 4,
    int chunkDurationSec = 600,
    void Function(double progress, String message)? onProgress,
  }) async {
    final fast = await loadFastSrt(
      details,
      cookie: cookie,
      sourceLanguage: sourceLanguage,
    );
    if (fast.session != null) return fast;

    if (sttDocExtractor != null) {
      final doc = await sttDocExtractor!(
        details,
        cookie: cookie,
        sourceLanguage: sourceLanguage,
        onProgress: onProgress,
      );
      if (doc != null && doc.isNotEmpty) {
        final session = buildAndCacheSession(
          details: details,
          document: doc,
          sourceKind: BilibiliSrtSourceKind.capcutStt,
          languageLabel: sourceLanguage,
        );
        return BilibiliSrtLoadResult(
          session: session,
          statusNote:
              'Đã tạo SRT bằng CapCut STT (${session.totalChunks} đoạn).',
        );
      }
      return const BilibiliSrtLoadResult(
        session: null,
        sttAvailable: false,
        statusNote: 'Không nhận diện được lời thoại từ âm thanh video.',
      );
    }

    Directory? workDir;
    try {
      onProgress?.call(0.05, 'Đang lấy luồng âm thanh nhẹ từ Bilibili...');
      final audioUrl = await resolver.getAudioUrl(details, cookie);

      final tmpRoot = await getTemporaryDirectory();
      workDir = Directory(
        '${tmpRoot.path}${Platform.pathSeparator}bili_ai_srt_${details.bvid}_${DateTime.now().millisecondsSinceEpoch}',
      );
      await workDir.create(recursive: true);

      final audioFile = File(
        '${workDir.path}${Platform.pathSeparator}audio.m4a',
      );
      await resolver.downloadAudio(
        audioUrl,
        audioFile,
        cookie,
        concurrency: concurrency.clamp(2, 16),
        onProgress: (p, msg) {
          onProgress?.call(0.08 + p * 0.25, 'Tải audio: ${(p * 100).round()}%');
        },
      );

      final totalDurationMs =
          (details.durationSeconds > 0 ? details.durationSeconds : 300) * 1000;
      onProgress?.call(0.35, 'Đang chia nhỏ audio để nhận diện lời thoại...');
      final audioChunks = await AudioChunker.sliceMedia(
        videoPath: audioFile.path,
        totalDurationMs: totalDurationMs,
        tempDir: workDir,
        chunkDurationSec: chunkDurationSec,
        concurrency: concurrency.clamp(1, 4),
      );

      if (audioChunks.isEmpty) {
        return const BilibiliSrtLoadResult(
          session: null,
          statusNote: 'Không trích xuất được đoạn âm thanh nào để nhận diện STT.',
        );
      }

      final total = audioChunks.length;
      final results = List<List<SubtitleItem>?>.filled(total, null);
      var nextIdx = 0;
      var completed = 0;
      final workerCount = concurrency.clamp(1, total);

      Future<void> worker() async {
        while (nextIdx < total) {
          final idx = nextIdx++;
          if (idx >= total) break;
          final chunk = audioChunks[idx];
          final device = DeviceConfig().randomize();
          final uploader = CapCutVodUploader(device: device);
          final uploaded = await uploader.uploadFile(chunk.file);
          final sttClient = CapCutSttClient(device: device);
          final chunkDoc = await sttClient.transcribeAudio(
            audioVid: uploaded.vid,
            audioMd5: uploaded.md5,
            durationMs: chunk.durationMs,
            language: sourceLanguage,
            useTranslation: false,
            timeOffsetMs: chunk.startMs,
          );
          results[idx] = chunkDoc.items;
          completed++;
          onProgress?.call(
            0.38 + (completed / total) * 0.58,
            'CapCut STT: Đã xong $completed/$total đoạn audio...',
          );
        }
      }

      await Future.wait(List.generate(workerCount, (_) => worker()));

      final allItems = <SubtitleItem>[];
      for (final part in results) {
        if (part != null) allItems.addAll(part);
      }

      if (allItems.isEmpty) {
        return const BilibiliSrtLoadResult(
          session: null,
          statusNote: 'CapCut STT không phát hiện lời thoại trong video này.',
        );
      }

      final fullDoc = SubtitleDocument(allItems)..reindex();
      final session = buildAndCacheSession(
        details: details,
        document: fullDoc,
        sourceKind: BilibiliSrtSourceKind.capcutStt,
        languageLabel: sourceLanguage,
      );
      onProgress?.call(
        1.0,
        'Hoàn tất SRT (${session.document.size} câu · ${session.totalChunks} đoạn).',
      );
      return BilibiliSrtLoadResult(
        session: session,
        statusNote:
            'Đã tạo nhanh SRT từ âm thanh (${session.document.size} câu, chia ${session.totalChunks} đoạn).',
      );
    } catch (e) {
      return BilibiliSrtLoadResult(
        session: null,
        statusNote: 'Không tạo được SRT bằng CapCut STT: $e',
      );
    } finally {
      if (workDir != null) {
        try {
          if (await workDir.exists()) {
            await workDir.delete(recursive: true);
          }
        } catch (_) {}
      }
    }
  }

  /// Xuất file `.srt` chuẩn từ session đang giữ trong RAM vào thư mục `saved_subtitles`.
  Future<File> exportSrtFile(BilibiliSrtSession session) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final outDir = Directory(
      '${docsDir.path}${Platform.pathSeparator}saved_subtitles',
    );
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }
    final safeBvid = session.bvid.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final file = File(
      '${outDir.path}${Platform.pathSeparator}bili_${safeBvid}_p${session.pageIndex}.srt',
    );
    await file.writeAsString(
      session.document.toSrtString('original'),
      flush: true,
    );
    return file;
  }

  Future<SubtitleDocument?> _tryLoadFromHistory(
    String bvid,
    int pageIndex,
  ) async {
    if (historyDocLoader != null) {
      return historyDocLoader!(bvid, pageIndex);
    }
    final repo = await HistoryRepository.getInstance();
    final targetUrl = pageIndex > 1
        ? 'https://www.bilibili.com/video/$bvid?p=$pageIndex'
        : 'https://www.bilibili.com/video/$bvid';
    final match = repo.getHistory().where((item) {
      return HistoryRepository.matchesBilibiliUrl(item.videoPath, targetUrl) ||
          HistoryRepository.matchesBilibiliUrl(item.id, targetUrl);
    }).firstOrNull;
    if (match == null) return null;
    return repo.loadSubtitleDocument(match);
  }
}
