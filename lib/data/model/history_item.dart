class HistoryItem {
  final String id;
  final String title;
  final String videoPath;
  final String srtPath;
  final String? documentPath;
  final int timestamp;
  final int durationMs;
  final int sentenceCount;
  final String? ttsVoice;

  const HistoryItem({
    required this.id,
    required this.title,
    required this.videoPath,
    required this.srtPath,
    this.documentPath,
    required this.timestamp,
    required this.durationMs,
    this.sentenceCount = 0,
    this.ttsVoice,
  });

  HistoryItem copyWith({
    String? id,
    String? title,
    String? videoPath,
    String? srtPath,
    String? documentPath,
    int? timestamp,
    int? durationMs,
    int? sentenceCount,
    String? ttsVoice,
  }) {
    return HistoryItem(
      id: id ?? this.id,
      title: title ?? this.title,
      videoPath: videoPath ?? this.videoPath,
      srtPath: srtPath ?? this.srtPath,
      documentPath: documentPath ?? this.documentPath,
      timestamp: timestamp ?? this.timestamp,
      durationMs: durationMs ?? this.durationMs,
      sentenceCount: sentenceCount ?? this.sentenceCount,
      ttsVoice: ttsVoice ?? this.ttsVoice,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'videoPath': videoPath,
    'srtPath': srtPath,
    'documentPath': documentPath,
    'timestamp': timestamp,
    'durationMs': durationMs,
    'sentenceCount': sentenceCount,
    if (ttsVoice != null) 'ttsVoice': ttsVoice,
  };

  factory HistoryItem.fromJson(Map<String, dynamic> json) => HistoryItem(
    id: json['id'] as String,
    title: json['title'] as String,
    videoPath: json['videoPath'] as String,
    srtPath: json['srtPath'] as String,
    documentPath: json['documentPath'] as String?,
    timestamp: json['timestamp'] as int,
    durationMs: json['durationMs'] as int? ?? 0,
    sentenceCount: json['sentenceCount'] as int? ?? 0,
    ttsVoice: json['ttsVoice'] as String?,
  );
}
