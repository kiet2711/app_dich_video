import 'dart:io';

import 'subtitle_item.dart';

class SubtitleDocument {
  final List<SubtitleItem> items;

  SubtitleDocument([List<SubtitleItem>? items]) : items = items ?? [];

  int get size => items.length;
  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;

  void reindex() {
    items.sort((a, b) => a.startMs.compareTo(b.startMs));
    for (var i = 0; i < items.length; i++) {
      items[i].id = i + 1;
    }
  }

  void normalizeTranslations() {
    for (final item in items) {
      item.normalizeTranslation();
    }
  }

  void recoverLegacyBilingualText(String sourceLanguage) {
    if (!sourceLanguage.toLowerCase().startsWith('zh')) return;
    for (final item in items) {
      if (item.translatedText.trim() != item.originalText.trim()) continue;
      final split = splitChineseSourceAndTranslation(item.originalText);
      if (split != null) {
        item.originalText = split['source']!;
        item.translatedText = split['translation']!;
      }
    }
  }

  SubtitleItem? getActiveItem(int currentPositionMs) {
    var low = 0;
    var high = items.length - 1;
    while (low <= high) {
      final mid = low + ((high - low) ~/ 2);
      final item = items[mid];
      if (currentPositionMs < item.startMs) {
        high = mid - 1;
      } else if (currentPositionMs >= item.endMs) {
        low = mid + 1;
      } else {
        return item;
      }
    }
    return null;
  }

  String toSrtString([String mode = 'translated']) {
    final sb = StringBuffer();
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      sb.writeln(i + 1);
      sb.writeln(item.formatSrtTimecode());
      sb.writeln(item.getDisplayText(mode));
      sb.writeln();
    }
    return '${sb.toString().trimRight()}\n';
  }

  Future<void> saveToFile(File file, [String mode = 'translated']) async {
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }
    await file.writeAsString(toSrtString(mode));
  }

  String toAssString([String mode = 'translated']) {
    const header = """[Script Info]
Title: CapSub Studio Subtitles with BlackBox
ScriptType: v4.00+
WrapStyle: 0
PlayResX: 1920
PlayResY: 1080
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: BlackBox,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,3,14,0,2,30,30,95,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
""";

    final dialogues = items
        .map((item) {
          final ass = item.formatAssTimecode();
          final text = item.getDisplayText(mode).replaceAll('\n', r'\N');
          return 'Dialogue: 0,${ass['start']},${ass['end']},BlackBox,,0,0,0,,$text';
        })
        .join('\n');

    return '$header$dialogues\n';
  }

  static final RegExp _hanCharacter = RegExp(
    r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]',
  );

  static Map<String, String>? splitChineseSourceAndTranslation(String text) {
    final lines = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length < 2 || !_hanCharacter.hasMatch(lines.first)) return null;

    final translationStart = lines.indexWhere(
      (l) => !_hanCharacter.hasMatch(l),
    );
    if (translationStart <= 0 || translationStart >= lines.length) return null;

    final source = lines.sublist(0, translationStart).join('\n').trim();
    final translation = lines.sublist(translationStart).join('\n').trim();
    if (source.isNotEmpty && translation.isNotEmpty) {
      return {'source': source, 'translation': translation};
    }
    return null;
  }

  static SubtitleDocument parseSrt(String srtContent) {
    final list = <SubtitleItem>[];
    if (srtContent.trim().isEmpty) return SubtitleDocument(list);

    final cleaned = srtContent
        .replaceAll(RegExp(r'```srt', caseSensitive: false), '')
        .replaceAll('```', '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .trim();

    final blocks = cleaned.split(RegExp(r'\n\s*\n+'));
    for (final block in blocks) {
      final lines = block
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      if (lines.isEmpty) continue;

      final timecodeIndex = lines.indexWhere((l) => l.contains('-->'));
      if (timecodeIndex == -1) continue;

      final timeParts = lines[timecodeIndex].split(RegExp(r'\s*-->\s*'));
      if (timeParts.length != 2) continue;

      final startMs = parseSrtTimestamp(timeParts[0]);
      final endMs = parseSrtTimestamp(timeParts[1]);

      final textLines = lines.sublist(timecodeIndex + 1);
      final text = textLines.join('\n').trim();

      int id = list.length + 1;
      if (timecodeIndex > 0) {
        final rawId = int.tryParse(lines[0].replaceAll(RegExp(r'[^0-9]'), ''));
        if (rawId != null) id = rawId;
      }

      list.add(
        SubtitleItem(
          id: id,
          startMs: startMs,
          endMs: endMs,
          originalText: text,
          translatedText: text,
        ),
      );
    }

    final timecodeMatches = RegExp(
      r'\d{1,2}:\d{1,2}:\d{1,2}(?:[,\.]\d{1,3})?\s*-->\s*\d{1,2}:\d{1,2}:\d{1,2}(?:[,\.]\d{1,3})?',
    ).allMatches(cleaned).toList();
    if (list.length < timecodeMatches.length && timecodeMatches.isNotEmpty) {
      list.clear();
      final lines = cleaned.split('\n');
      var currentId = 1;
      String? currentTimecode;
      final currentTextLines = <String>[];

      void pushCurrent() {
        if (currentTimecode == null) return;
        final parts = currentTimecode.split(RegExp(r'\s*-->\s*'));
        if (parts.length == 2) {
          final startMs = parseSrtTimestamp(parts[0]);
          final endMs = parseSrtTimestamp(parts[1]);
          final text = currentTextLines.join('\n').trim();
          list.add(
            SubtitleItem(
              id: currentId,
              startMs: startMs,
              endMs: endMs,
              originalText: text,
              translatedText: text,
            ),
          );
        }
        currentTextLines.clear();
      }

      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.contains('-->') &&
            RegExp(r'.*\d{1,2}:\d{1,2}:\d{1,2}.*-->.*\d{1,2}:\d{1,2}:\d{1,2}.*')
                .hasMatch(trimmed)) {
          final possibleId = currentTextLines.isNotEmpty
              ? int.tryParse(
                  currentTextLines.last.replaceAll(RegExp(r'[^0-9]'), ''),
                )
              : null;
          if (possibleId != null && currentTextLines.isNotEmpty) {
            currentTextLines.removeLast();
            pushCurrent();
            currentId = possibleId;
          } else {
            pushCurrent();
            currentId = list.length + 1;
          }
          currentTimecode = trimmed;
        } else if (currentTimecode != null) {
          currentTextLines.add(trimmed);
        }
      }
      pushCurrent();
    }

    final doc = SubtitleDocument(list);
    doc.reindex();
    return doc;
  }

  static int parseSrtTimestamp(String timestampStr) {
    try {
      final cleaned = timestampStr.trim().replaceAll('.', ',');
      final parts = cleaned.split(',');
      final hms = parts[0];
      final milli = parts.length > 1
          ? (int.tryParse(parts[1].padRight(3, '0').substring(0, 3)) ?? 0)
          : 0;

      final hmsParts = hms.split(':');
      final h = hmsParts.isNotEmpty ? (int.tryParse(hmsParts[0]) ?? 0) : 0;
      final m = hmsParts.length > 1 ? (int.tryParse(hmsParts[1]) ?? 0) : 0;
      final s = hmsParts.length > 2 ? (int.tryParse(hmsParts[2]) ?? 0) : 0;

      return (h * 3600 + m * 60 + s) * 1000 + milli;
    } catch (_) {
      return 0;
    }
  }

  Map<String, dynamic> toJson() => {
    'items': items.map((it) => it.toJson()).toList(),
  };

  factory SubtitleDocument.fromJson(Map<String, dynamic> json) =>
      SubtitleDocument(
        (json['items'] as List<dynamic>?)
            ?.map((e) => SubtitleItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
