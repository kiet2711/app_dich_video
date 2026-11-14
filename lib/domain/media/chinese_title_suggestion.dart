/// Mô hình & công cụ dùng chung cho tính năng **Chuyển đổi tên/mô tả Tiếng Việt → Tiếng Trung**
/// ở cả Trợ lý AI Hồng Quả và Trợ lý AI Bilibili (chỉ gợi ý tên/từ khóa để người dùng tự copy tìm,
/// KHÔNG truy vấn kho phim và KHÔNG trả thẻ phim/video).
class ChineseTitleSuggestionItem {
  final String zhTitle;
  final String hanVietOrMeaning;
  final String tag;
  final String note;

  const ChineseTitleSuggestionItem({
    required this.zhTitle,
    this.hanVietOrMeaning = '',
    this.tag = '',
    this.note = '',
  });

  Map<String, dynamic> toJson() => {
    'zh_title': zhTitle,
    if (hanVietOrMeaning.isNotEmpty) 'han_viet_meaning': hanVietOrMeaning,
    if (tag.isNotEmpty) 'tag': tag,
    if (note.isNotEmpty) 'note': note,
  };
}

class ChineseTitleSuggestionBatch {
  final String platformLabel;
  final String viInputSummary;
  final List<ChineseTitleSuggestionItem> suggestions;

  const ChineseTitleSuggestionBatch({
    required this.platformLabel,
    this.viInputSummary = '',
    required this.suggestions,
  });
}

class ChineseTitleSuggestionHelper {
  ChineseTitleSuggestionHelper._();

  static const String toolName = 'suggest_chinese_search_terms';

  /// Đoạn chỉ dẫn dùng chung trong System Prompt cho cả Bilibili và Hồng Quả.
  static const String systemPromptSection =
      'CHẾ ĐỘ CHUYỂN TÊN VIỆT → TRUNG (KHÔNG ĐỀ XUẤT PHIM):\n'
      '   - Khi [NGỮ CẢNH UI] bật `CHẾ ĐỘ: Chỉ chuyển tên Việt -> Trung` HOẶC người dùng mô tả tên/cốt truyện bằng Tiếng Việt để xin gợi ý tên/từ khóa Tiếng Trung tự copy đi tìm (vd: *"đổi tên sang tiếng Trung"*, *"cho mình tên tiếng Trung để tự copy tìm, không cần đề xuất phim"*):\n'
      '   - BẮT BUỘC CHỈ gọi tool `suggest_chinese_search_terms`. TUYỆT ĐỐI KHÔNG gọi bất kỳ tool tìm kiếm hay bảng xếp hạng nào (`search_*`, `progressive_search`, `explore_*`, `browse_by_category`, `get_rankings`) và KHÔNG tự bịa hay đề xuất thẻ phim/video!\n'
      '   - Trong `suggestions`, đưa 3–6 phương án `zh_title` tiếng Trung Giản thể sát nghĩa nhất theo thứ tự: (1) tên gốc quen thuộc nếu nhận ra được (`exact_title`), (2) dịch sát nghĩa/Hán Việt (`literal_han_viet`), (3) biến thể đồng nghĩa hay dùng trên web Trung (`synonym_variant`), (4) tổ hợp từ khóa thể loại/nhân vật ngắn gọn dễ ra kết quả (`trope_keyword`).\n'
      '   - Trường `han_viet_meaning` dùng Tiếng Việt + âm Hán Việt có dấu chuẩn (TUYỆT ĐỐI CẤM Pinyin).\n'
      '   - Trong câu trả lời chữ/thoại, liệt kê ngắn gọn lại các tên gợi ý đó kèm ghi chú cách dùng để user copy ngay, không rủ xem hay đề xuất phim thay.';

  /// Khai báo Function Calling chuẩn Gemini Live API dùng chung cho cả 2 trợ lý.
  static Map<String, dynamic> buildToolDeclaration({
    String platformHint = 'nền tảng Trung Quốc',
  }) {
    return {
      'name': toolName,
      'description':
          'Chuyển đổi tên hoặc mô tả phim/video từ Tiếng Việt sang 3–6 tên gọi và từ khóa Tiếng Trung chuẩn để người dùng TỰ COPY và tự tìm trên $platformHint. Dùng hàm này khi người dùng muốn lấy tên tiếng Trung để copy/tự tìm hoặc chế độ Chỉ đổi tên Việt -> Trung đang bật; KHÔNG gọi tool tìm kiếm/đề xuất phim cùng lúc.',
      'parameters': {
        'type': 'OBJECT',
        'properties': {
          'vi_input_summary': {
            'type': 'STRING',
            'description':
                'Tóm tắt ngắn gọn tên hoặc mô tả Tiếng Việt mà người dùng vừa cung cấp.',
          },
          'suggestions': {
            'type': 'ARRAY',
            'description':
                'Danh sách 3–6 phương án tên / cụm từ khóa tiếng Trung Giản thể để người dùng copy tự tìm kiếm.',
            'items': {
              'type': 'OBJECT',
              'properties': {
                'zh_title': {
                  'type': 'STRING',
                  'description':
                      'Tên phim/video hoặc cụm từ khóa bằng chữ Hán Giản thể (sẵn sàng để copy tìm kiếm).',
                },
                'han_viet_meaning': {
                  'type': 'STRING',
                  'description':
                      'Tên Hán Việt hoặc nghĩa Tiếng Việt tương ứng (TUYỆT ĐỐI KHÔNG dùng Pinyin).',
                },
                'match_type': {
                  'type': 'STRING',
                  'enum': [
                    'exact_title',
                    'literal_han_viet',
                    'synonym_variant',
                    'trope_keyword',
                  ],
                  'description':
                      'Loại gợi ý: exact_title (sát tên gốc), literal_han_viet (dịch sát Hán Việt), synonym_variant (tên gọi khác thường gặp), trope_keyword (từ khóa mô tả ngắn).',
                },
                'note': {
                  'type': 'STRING',
                  'description': 'Ghi chú ngắn gọn khi nào nên dùng từ khóa này.',
                },
              },
              'required': ['zh_title', 'han_viet_meaning'],
            },
          },
        },
        'required': ['vi_input_summary', 'suggestions'],
      },
    };
  }

  /// Nhận diện câu yêu cầu chỉ chuyển đổi tên/mô tả Tiếng Việt → tên Tiếng Trung để tự copy tìm
  /// (và KHÔNG muốn app tự tìm/đề xuất danh sách phim/video).
  static bool looksLikeChineseTitleOnlyRequest(String rawInput) {
    final lower = rawInput.trim().toLowerCase();
    if (lower.isEmpty) return false;

    final explicitlyRefusesRecommendations = RegExp(
      r'(?:k(?:hông|o)?\s*(?:cần\s*)?(?:đề xuất|gợi ý\s*(?:phim|video)|tìm\s*(?:phim|video)|hiện\s*(?:thẻ|phim|video)|lấy\s*(?:phim|video))|đừng\s*(?:đề xuất|gợi ý\s*(?:phim|video)|tìm)|chỉ\s*(?:cần|muốn|lấy|xin|đưa)\s*(?:tên|từ khóa|tên\s*tiếng\s*trung))',
    ).hasMatch(lower);

    final explicitlyForManualCopySearch = RegExp(
      r'(?:tự\s*(?:mình\s*)?(?:copy|sao chép|tìm|search|gõ)|để\s*(?:mình|tôi|em|tui|người dùng)\s*(?:tự\s*)?(?:copy|sao chép|tìm|search)|copy\s*(?:và|rồi)?\s*(?:tự\s*)?tìm)',
    ).hasMatch(lower);

    final asksConvertViToZh = RegExp(
      r'(?:(?:chuyển(?:\s*đổi)?|quy\s*đổi|đổi|biên\s*dịch|dịch)\b[^.!?\n]{0,120}?(?:sang|ra|thành)\s*(?:tên|từ khóa|chữ)?\s*(?:tiếng\s*trung|chữ\s*trung|chữ\s*hán|trung\s*quốc|hoa)|(?:từ\s*tên\s*tiếng\s*việt\s*sang\s*(?:tiếng\s*)?trung)|(?:tên\s*gợi ý\s*(?:bằng\s*)?(?:tiếng\s*trung|chữ\s*hán)))',
    ).hasMatch(lower);

    final asksChineseNameFromDescription = RegExp(
      r'(?:mô tả\s*(?:phim|video)?\s*(?:bằng\s*)?tiếng\s*việt.*(?:tên|từ khóa)\s*(?:bằng\s*)?(?:tiếng\s*trung|chữ\s*hán)|(?:cho|gợi ý|xin)\s*(?:mình|tôi|em|tui)?\s*(?:vài|mấy|các)?\s*(?:tên|từ khóa)\s*(?:bằng\s*)?(?:tiếng\s*trung|chữ\s*trung|chữ\s*hán))',
    ).hasMatch(lower);

    // Tránh bắt nhầm câu kiểu "Tìm đúng phim Phàm Nhân Tu Tiên bản gốc tiếng Trung"
    final explicitlyWantsCatalogResults = RegExp(
      r'(?:rồi\s*tìm\s*(?:luôn|giúp)|tìm\s*(?:giúp|cho\s*(?:mình|tôi|em))\s*(?:\d+\s*)?(?:phim|video|bộ)|lấy\s*(?:link|video|phim|top|bxh)|đưa\s*ra\s*(?:các\s*)?video\s*(?:ở\s*mục|đầu|thẻ))',
    ).hasMatch(lower);

    if (explicitlyRefusesRecommendations) {
      return true;
    }
    if ((asksConvertViToZh || asksChineseNameFromDescription) &&
        explicitlyForManualCopySearch) {
      return true;
    }
    if ((asksConvertViToZh || asksChineseNameFromDescription) &&
        !explicitlyWantsCatalogResults) {
      return true;
    }
    return false;
  }

  /// Thực thi tool `suggest_chinese_search_terms` (thuần cục bộ, không gọi API tìm phim).
  static Map<String, dynamic> executeToolCall(
    Map<String, dynamic> args, {
    required String platformLabel,
    void Function(String statusText)? onProgress,
    void Function(ChineseTitleSuggestionBatch batch)? onSuggestionsUpdated,
  }) {
    onProgress?.call('Đang tổng hợp tên tiếng Trung để bạn copy...');

    final viSummary = (args['vi_input_summary'] ??
            args['vi_description'] ??
            args['description'] ??
            '')
        .toString()
        .trim();

    final parsed = <ChineseTitleSuggestionItem>[];
    final seenZh = <String>{};

    void addCandidate(
      String rawZh, {
      String hanViet = '',
      String matchType = '',
      String note = '',
    }) {
      final zh = rawZh.trim();
      if (zh.isEmpty) return;
      final key = zh.toLowerCase();
      if (!seenZh.add(key)) return;
      parsed.add(
        ChineseTitleSuggestionItem(
          zhTitle: zh,
          hanVietOrMeaning: hanViet.trim(),
          tag: _labelForMatchType(matchType),
          note: note.trim(),
        ),
      );
    }

    final rawList =
        args['suggestions'] ?? args['titles'] ?? args['keywords'] ?? const [];
    if (rawList is List) {
      for (final entry in rawList) {
        if (entry is String) {
          addCandidate(entry);
        } else if (entry is Map) {
          final zh = (entry['zh_title'] ??
                  entry['zhTitle'] ??
                  entry['title'] ??
                  entry['keyword'] ??
                  entry['zh'] ??
                  '')
              .toString();
          final hv = (entry['han_viet_meaning'] ??
                  entry['hanVietMeaning'] ??
                  entry['han_viet'] ??
                  entry['vi_meaning'] ??
                  entry['meaning'] ??
                  '')
              .toString();
          final type = (entry['match_type'] ?? entry['type'] ?? '').toString();
          final note = (entry['note'] ?? entry['reason'] ?? '').toString();
          addCandidate(zh, hanViet: hv, matchType: type, note: note);
        }
      }
    }

    if (parsed.isNotEmpty) {
      final batch = ChineseTitleSuggestionBatch(
        platformLabel: platformLabel,
        viInputSummary: viSummary,
        suggestions: parsed,
      );
      onSuggestionsUpdated?.call(batch);
    }

    return {
      'ok': parsed.isNotEmpty,
      'mode': 'title_translate_only',
      'platform': platformLabel,
      'vi_input_summary': viSummary,
      'count': parsed.length,
      'suggestions': parsed.map((e) => e.toJson()).toList(),
      'instruction': parsed.isEmpty
          ? 'Chưa nhận được tên tiếng Trung nào; hãy truyền mảng `suggestions` gồm 3-6 phương án có `zh_title` tiếng Trung và `han_viet_meaning` Tiếng Việt/Hán Việt.'
          : 'App đã hiển thị bảng tên tiếng Trung có nút Copy 1 chạm cho người dùng. Hãy liệt kê ngắn gọn các tên vừa gợi ý kèm Hán Việt/ý nghĩa và ghi chú cách tìm; TUYỆT ĐỐI KHÔNG gọi tool tìm phim hay đề xuất thêm thẻ phim/video.',
    };
  }

  /// Dự phòng nhẹ khi model Live trả thẳng danh sách chữ Hán trong văn bản mà quên gọi tool
  /// lúc đang ở chế độ Chỉ đổi tên Việt -> Trung.
  static ChineseTitleSuggestionBatch? extractFallbackBatchFromReplyText(
    String replyText, {
    required String platformLabel,
    String viInputSummary = '',
  }) {
    final clean = replyText.trim();
    if (clean.isEmpty) return null;

    final cjkSpanRe = RegExp(r'[\u4e00-\u9fff][^\n*`•—\-–:()\[\]【】]{1,42}');
    final items = <ChineseTitleSuggestionItem>[];
    final seen = <String>{};

    for (final rawLine in clean.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final match = cjkSpanRe.firstMatch(line);
      if (match == null) continue;
      final zh = match.group(0)!.trim();
      // Bỏ những mảnh chỉ có 1 ký tự đơn lẻ hoặc không phải cụm có ý nghĩa
      if (zh.replaceAll(RegExp(r'[^\u4e00-\u9fff]'), '').length < 2) continue;
      if (!seen.add(zh)) continue;

      var remainder = line
          .replaceFirst(match.group(0)!, '')
          .replaceAll(RegExp(r'^[\s\-–—•*`:#\d.)(\[\]【】]+'), '')
          .replaceAll(RegExp(r'[\*`]+'), '')
          .trim();
      if (remainder.length > 110) {
        remainder = '${remainder.substring(0, 110).trimRight()}...';
      }

      items.add(
        ChineseTitleSuggestionItem(
          zhTitle: zh,
          hanVietOrMeaning: remainder,
          tag: items.isEmpty ? 'Gợi ý 1' : 'Biến thể',
        ),
      );
      if (items.length >= 6) break;
    }

    if (items.isEmpty) return null;
    return ChineseTitleSuggestionBatch(
      platformLabel: platformLabel,
      viInputSummary: viInputSummary,
      suggestions: items,
    );
  }

  static String _labelForMatchType(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'exact_title':
        return 'Sát tên gốc';
      case 'literal_han_viet':
        return 'Hán Việt';
      case 'synonym_variant':
        return 'Biến thể';
      case 'trope_keyword':
        return 'Từ khóa';
      default:
        return 'Gợi ý';
    }
  }
}

