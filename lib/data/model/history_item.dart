class HistoryItem {
  final String id;
  final String title;
  final String videoPath;
  final String srtPath;
  final String? documentPath;
  final int timestamp;
  final int durationMs;

  const HistoryItem({
    required this.id,
    required this.title,
    required this.videoPath,
    required this.srtPath,
    this.documentPath,
    required this.timestamp,
    required this.durationMs,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'videoPath': videoPath,
    'srtPath': srtPath,
    'documentPath': documentPath,
    'timestamp': timestamp,
    'durationMs': durationMs,
  };

  factory HistoryItem.fromJson(Map<String, dynamic> json) => HistoryItem(
    id: json['id'] as String,
    title: json['title'] as String,
    videoPath: json['videoPath'] as String,
    srtPath: json['srtPath'] as String,
    documentPath: json['documentPath'] as String?,
    timestamp: json['timestamp'] as int,
    durationMs: json['durationMs'] as int? ?? 0,
  );
}
