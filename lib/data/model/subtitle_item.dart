class SubtitleItem {
  int id;
  final int startMs;
  final int endMs;
  String originalText;
  String translatedText;
  String? audioFilePath;
  int audioDurationMs;
  double playbackSpeed;

  SubtitleItem({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.originalText,
    this.translatedText = '',
    this.audioFilePath,
    this.audioDurationMs = 0,
    this.playbackSpeed = 1.0,
  });

  String getDisplayText([String mode = 'translated']) {
    final translationOnly = getTranslationOnlyText();
    switch (mode.toLowerCase()) {
      case 'original':
        return originalText;
      case 'bilingual':
        if (translationOnly.isNotEmpty &&
            translationOnly != originalText.trim()) {
          return '$originalText\n$translationOnly';
        }
        return originalText;
      default:
        return translationOnly.isNotEmpty ? translationOnly : originalText;
    }
  }

  String getTranslationOnlyText() {
    final source = _normalizeLineBreaks(originalText).trim();
    final value = _normalizeLineBreaks(translatedText).trim();
    if (source.isEmpty || value.isEmpty || value == source) return value;

    if (value.startsWith(source)) {
      final remainder = value
          .substring(source.length)
          .replaceAll(RegExp(r'^[\n \t:\-–—]+'), '');
      if (remainder.isNotEmpty) return remainder.trim();
    }

    final sourceLines = source
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final valueLines = value
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (sourceLines.isNotEmpty && valueLines.length > sourceLines.length) {
      var matches = true;
      for (var i = 0; i < sourceLines.length; i++) {
        if (valueLines[i] != sourceLines[i]) {
          matches = false;
          break;
        }
      }
      if (matches) {
        return valueLines.sublist(sourceLines.length).join('\n').trim();
      }
    }
    return value;
  }

  void normalizeTranslation() {
    translatedText = getTranslationOnlyText();
  }

  String formatSrtTimecode() {
    return '${msToSrt(startMs)} --> ${msToSrt(endMs)}';
  }

  Map<String, String> formatAssTimecode() {
    return {'start': msToAss(startMs), 'end': msToAss(endMs)};
  }

  static String _normalizeLineBreaks(String text) =>
      text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  static String msToSrt(int ms) {
    final safeMs = ms < 0 ? 0 : ms;
    final totalSec = safeMs ~/ 1000;
    final milli = safeMs % 1000;
    final hours = totalSec ~/ 3600;
    final mins = (totalSec % 3600) ~/ 60;
    final secs = totalSec % 60;
    return '${hours.toString().padLeft(2, '0')}:${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')},${milli.toString().padLeft(3, '0')}';
  }

  static String msToAss(int ms) {
    final safeMs = ms < 0 ? 0 : ms;
    final totalSec = safeMs ~/ 1000;
    final centi = (safeMs % 1000) ~/ 10;
    final hours = totalSec ~/ 3600;
    final mins = (totalSec % 3600) ~/ 60;
    final secs = totalSec % 60;
    return '$hours:${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}.${centi.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'startMs': startMs,
    'endMs': endMs,
    'originalText': originalText,
    'translatedText': translatedText,
    'audioFilePath': audioFilePath,
    'audioDurationMs': audioDurationMs,
    'playbackSpeed': playbackSpeed,
  };

  factory SubtitleItem.fromJson(Map<String, dynamic> json) => SubtitleItem(
    id: json['id'] as int,
    startMs: json['startMs'] as int,
    endMs: json['endMs'] as int,
    originalText: json['originalText'] as String,
    translatedText: json['translatedText'] as String? ?? '',
    audioFilePath: json['audioFilePath'] as String?,
    audioDurationMs: json['audioDurationMs'] as int? ?? 0,
    playbackSpeed: (json['playbackSpeed'] as num?)?.toDouble() ?? 1.0,
  );
}
