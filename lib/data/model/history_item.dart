class HistoryItem {
  final String id;
  final String title;
  final String? originalTitle;
  final String? translatedTitle;
  final String videoPath;
  final String srtPath;
  final String? documentPath;
  final int timestamp;
  final int durationMs;
  final int sentenceCount;
  final String? ttsVoice;
  final String? docKey;
  final int lastPositionMs;

  // Thuộc tính phục vụ ảnh bìa & gom nhóm phim bộ (Hồng Quả, Bilibili, Short Drama)
  final String? seriesId;
  final String? seriesCover;
  final int? episodeIndex;
  final int? totalEpisodes;

  String? get coverUrl => seriesCover;

  const HistoryItem({
    required this.id,
    required this.title,
    this.originalTitle,
    this.translatedTitle,
    required this.videoPath,
    required this.srtPath,
    this.documentPath,
    required this.timestamp,
    required this.durationMs,
    this.sentenceCount = 0,
    this.ttsVoice,
    this.docKey,
    this.lastPositionMs = 0,
    this.seriesId,
    this.seriesCover,
    this.episodeIndex,
    this.totalEpisodes,
  });

  bool get isSeriesEpisode {
    if (seriesId != null && seriesId!.isNotEmpty) return true;
    return RegExp(r'-\s*Tập\s*\d+', caseSensitive: false).hasMatch(title);
  }

  String get extractedSeriesTitle {
    final match = RegExp(
      r'^(.*?)\s*-\s*Tập\s*\d+',
      caseSensitive: false,
    ).firstMatch(title);
    if (match != null) {
      return match.group(1)!.trim();
    }
    return title.replaceAll(RegExp(r'\.mp4$', caseSensitive: false), '').trim();
  }

  int get extractedEpisodeIndex {
    if (episodeIndex != null && episodeIndex! > 0) return episodeIndex!;
    final match = RegExp(
      r'Tập\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(title);
    if (match != null) {
      return int.tryParse(match.group(1)!) ?? 1;
    }
    return 1;
  }

  /// Tiêu đề gốc (tiếng Trung hoặc nguyên bản)
  String get displayOriginalTitle {
    if (originalTitle != null && originalTitle!.trim().isNotEmpty) {
      return originalTitle!.replaceAll(RegExp(r'\.mp4$', caseSensitive: false), '').trim();
    }
    return title.replaceAll(RegExp(r'\.mp4$', caseSensitive: false), '').trim();
  }

  /// Tiêu đề đã dịch sang tiếng Việt (nếu có)
  String? get displayTranslatedTitle {
    if (translatedTitle != null && translatedTitle!.trim().isNotEmpty) {
      return translatedTitle!.replaceAll(RegExp(r'\.mp4$', caseSensitive: false), '').trim();
    }
    return null;
  }

  HistoryItem copyWith({
    String? id,
    String? title,
    String? originalTitle,
    String? translatedTitle,
    String? videoPath,
    String? srtPath,
    String? documentPath,
    int? timestamp,
    int? durationMs,
    int? sentenceCount,
    String? ttsVoice,
    String? docKey,
    int? lastPositionMs,
    String? seriesId,
    String? seriesCover,
    String? coverUrl,
    int? episodeIndex,
    int? totalEpisodes,
  }) {
    return HistoryItem(
      id: id ?? this.id,
      title: title ?? this.title,
      originalTitle: originalTitle ?? this.originalTitle,
      translatedTitle: translatedTitle ?? this.translatedTitle,
      videoPath: videoPath ?? this.videoPath,
      srtPath: srtPath ?? this.srtPath,
      documentPath: documentPath ?? this.documentPath,
      timestamp: timestamp ?? this.timestamp,
      durationMs: durationMs ?? this.durationMs,
      sentenceCount: sentenceCount ?? this.sentenceCount,
      ttsVoice: ttsVoice ?? this.ttsVoice,
      docKey: docKey ?? this.docKey,
      lastPositionMs: lastPositionMs ?? this.lastPositionMs,
      seriesId: seriesId ?? this.seriesId,
      seriesCover: coverUrl ?? seriesCover ?? this.seriesCover,
      episodeIndex: episodeIndex ?? this.episodeIndex,
      totalEpisodes: totalEpisodes ?? this.totalEpisodes,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (originalTitle != null) 'originalTitle': originalTitle,
    if (translatedTitle != null) 'translatedTitle': translatedTitle,
    'videoPath': videoPath,
    'srtPath': srtPath,
    'documentPath': documentPath,
    'timestamp': timestamp,
    'durationMs': durationMs,
    'sentenceCount': sentenceCount,
    if (ttsVoice != null) 'ttsVoice': ttsVoice,
    if (docKey != null) 'docKey': docKey,
    'lastPositionMs': lastPositionMs,
    if (seriesId != null) 'seriesId': seriesId,
    if (seriesCover != null) 'seriesCover': seriesCover,
    if (episodeIndex != null) 'episodeIndex': episodeIndex,
    if (totalEpisodes != null) 'totalEpisodes': totalEpisodes,
  };

  factory HistoryItem.fromJson(Map<String, dynamic> json) => HistoryItem(
    id: json['id'] as String,
    title: json['title'] as String,
    originalTitle: json['originalTitle'] as String?,
    translatedTitle: json['translatedTitle'] as String?,
    videoPath: json['videoPath'] as String,
    srtPath: json['srtPath'] as String,
    documentPath: json['documentPath'] as String?,
    timestamp: json['timestamp'] as int,
    durationMs: json['durationMs'] as int? ?? 0,
    sentenceCount: json['sentenceCount'] as int? ?? 0,
    ttsVoice: json['ttsVoice'] as String?,
    docKey: json['docKey'] as String?,
    lastPositionMs: json['lastPositionMs'] as int? ?? 0,
    seriesId: json['seriesId'] as String?,
    seriesCover: (json['seriesCover'] ?? json['coverUrl']) as String?,
    episodeIndex: json['episodeIndex'] as int?,
    totalEpisodes: json['totalEpisodes'] as int?,
  );
}
