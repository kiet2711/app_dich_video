/// Tiện ích dùng chung cho các Trợ lý Gemini Live (Hồng Quả & Bilibili):
/// chuẩn hóa trạng thái kết nối, quy tắc Hán Việt (cấm Pinyin) và đồng bộ
/// tiêu đề `#1..#N` từ câu trả lời trực tiếp của model Live về lại thẻ giao diện.
enum AssistantConnectionState {
  disconnected,
  connecting,
  ready,
  reconnecting,
  error,
}

class LiveReplyTitleSync {
  LiveReplyTitleSync._();

  static const String hanVietRulesPrompt =
      'MỌI tên nhân vật, họ tên, địa danh, chức tước, môn phái và danh từ riêng Hán Việt BẮT BUỘC chuyển sang âm Hán Việt có dấu Tiếng Việt. '
      'TUYỆT ĐỐI CẤM dùng phiên âm Pinyin tiếng Anh (Lin Fan, Shen Yan, Gu Qing, Xiao, Ye, Lu, Su, Jiang, Mu, Tang, Huo, Fu, Si, Bai...).\n'
      'Bảng chuẩn Hán Việt tham khảo nhanh: 林→Lâm, 沈→Thẩm, 顾→Cố, 萧→Tiêu, 叶→Diệp, 陆→Lục, 苏→Tô, 江→Giang, 白→Bạch, 慕→Mộ, 唐→Đường, 楚→Sở, 秦→Tần, 裴→Bùi, 霍→Hoắc, 傅→Phó, 薄→Bạc, 厉→Lệ, 司→Tư, 温→Ôn, 陈→Trần, 赵→Triệu, 许→Hứa, 周→Chu, 程→Trình, 谢→Tạ, 季→Quý, 乔→Kiều, 姜→Khương, 阮→Nguyễn, 夏→Hạ, 宁→Ninh, 墨→Mặc, 夜→Dạ, 凡→Phàm, 宴→Yến, 柔→Nhu, 晚→Vãn.';

  static bool hasChineseChars(String text) =>
      RegExp(r'[\u4e00-\u9fff]').hasMatch(text);

  static bool isUntranslatedTitle(String displayTitle, String originalTitle) {
    final vi = displayTitle.trim();
    final zh = originalTitle.trim();
    if (vi.isEmpty) return true;
    if (vi == zh && RegExp(r'[\u4e00-\u9fff]{2,}').hasMatch(vi)) return true;
    if (RegExp(r'[\u4e00-\u9fff]{2,}').hasMatch(vi)) return true;
    return false;
  }

  /// Trích xuất cặp `STT -> Tên Tiếng Việt` từ phản hồi trực tiếp của model Gemini Live
  /// theo các định dạng `#1. Tên — mô tả`, `1. Tên: mô tả`, `- #2 Tên - mô tả`, v.v.
  ///
  /// Khi đang stream (`isFinal == false`), chỉ nhận những dòng đã hoàn chỉnh
  /// (đã xuống dòng hoặc đã qua dấu ngăn cách mô tả) để tránh giật chữ khi stream.
  static Map<int, String> extractAiTitlesFromLiveReply(
    String replyText, {
    int maxIndex = 25,
    bool isFinal = false,
  }) {
    final result = <int, String>{};
    if (replyText.trim().isEmpty) return result;

    var normalized = replyText
        .replaceAll(RegExp(r'\*\*|__|`|“|”|「|」|『|』'), '')
        .replaceAll('\r\n', '\n');

    const ordinalWords = {
      'một': '1',
      'nhất': '1',
      'hai': '2',
      'nhì': '2',
      'ba': '3',
      'bốn': '4',
      'tư': '4',
      'năm': '5',
      'sáu': '6',
      'bảy': '7',
      'tám': '8',
      'chín': '9',
      'mười': '10',
    };
    for (final e in ordinalWords.entries) {
      normalized = normalized.replaceAllMapped(
        RegExp(
          '(?:(?:phim|video|kênh|mục)\\s+)?(?:số|thứ)\\s+${e.key}\\b',
          caseSensitive: false,
        ),
        (_) => '#${e.value}',
      );
    }
    normalized = normalized.replaceAllMapped(
      RegExp(
        r'(?:(?:phim|video|kênh|mục)\s+)?(?:số|thứ)\s+(\d{1,2})\b',
        caseSensitive: false,
      ),
      (m) => '#${m.group(1)}',
    );

    final markerPattern = RegExp(
      r'(?:^|\n)\s*(?:[-*•]\s*)?(?:#(\d{1,2})|(\d{1,2})\.)\s*[:.)\-–—]?\s*(.+)|'
      r'#(\d{1,2})\s*(?:[:.\-–—]|\s+(?:là|tên|–|—))\s*(.+)',
      multiLine: true,
    );

    for (final match in markerPattern.allMatches(normalized)) {
      final idxStr = match.group(1) ?? match.group(2) ?? match.group(4);
      final rawLine = (match.group(3) ?? match.group(5) ?? '').trim();
      final idx = int.tryParse(idxStr ?? '');
      if (idx == null || idx < 1 || idx > maxIndex || rawLine.isEmpty) continue;

      final matchEnd = match.end;
      final hasLineEnded =
          isFinal || (matchEnd < normalized.length && normalized[matchEnd] == '\n');
      final hasInlineSeparator = RegExp(
        r'\s+[—–]\s+|\s+-\s+|:\s+|\.\s+',
      ).hasMatch(rawLine);
      if (!hasLineEnded && !hasInlineSeparator) {
        continue;
      }

      final cleaned = _cleanExtractedTitleSegment(rawLine);
      if (cleaned != null && cleaned.isNotEmpty) {
        final existing = result[idx];
        if (existing == null || cleaned.length >= existing.length) {
          result[idx] = cleaned;
        }
      }
    }
    return result;
  }

  static String? _cleanExtractedTitleSegment(String rawLine) {
    var seg = rawLine.trim();
    final dashSplit = RegExp(r'\s+[—–]\s+|\s+-\s+').firstMatch(seg);
    if (dashSplit != null) {
      seg = seg.substring(0, dashSplit.start).trim();
    } else {
      final colonOrDotSplit = RegExp(r':\s+|\.\s+').firstMatch(seg);
      if (colonOrDotSplit != null) {
        seg = seg.substring(0, colonOrDotSplit.start).trim();
      }
    }

    seg = seg
        .replaceAll(
          RegExp(
            r'\s*\([^)]*(?:tên\s*gốc|gốc|[\u4e00-\u9fff])[^)]*\)\s*$',
            caseSensitive: false,
          ),
          '',
        )
        .trim();

    seg = seg
        .replaceAll(RegExp(r'^[\s"«<\[\x27:.\-–—]+'), '')
        .replaceAll(RegExp(r'[\s"»>\]\x27:.,\-–—]+$'), '')
        .trim();

    if (seg.length < 2 || seg.length > 90) return null;
    if (!RegExp(r'[A-Za-zÀ-ỹ]').hasMatch(seg)) return null;
    if (RegExp(r'[\u4e00-\u9fff]{2,}').hasMatch(seg)) return null;

    final lower = seg.toLowerCase();
    if (lower.startsWith('đây là ') ||
        lower.startsWith('dưới đây là ') ||
        lower.startsWith('tổng hợp')) {
      return null;
    }
    return seg;
  }
}
