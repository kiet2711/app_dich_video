class WatchLaterItem {
  final String id;
  final String title;
  final String? originalTitle;
  final String? translatedTitle;
  final String? coverUrl;
  final String source; // 'bilibili' | 'hongguo'
  final String targetUrl;
  final String? seriesId;
  final String? author;
  final int? totalEpisodes;
  final int addedAt;

  const WatchLaterItem({
    required this.id,
    required this.title,
    this.originalTitle,
    this.translatedTitle,
    this.coverUrl,
    required this.source,
    required this.targetUrl,
    this.seriesId,
    this.author,
    this.totalEpisodes,
    required this.addedAt,
  });

  bool get isHongguo => source == 'hongguo';
  bool get isBilibili => source == 'bilibili';

  String get displayTitle {
    if (translatedTitle != null && translatedTitle!.trim().isNotEmpty) {
      return translatedTitle!.trim();
    }
    return title.trim();
  }

  WatchLaterItem copyWith({
    String? id,
    String? title,
    String? originalTitle,
    String? translatedTitle,
    String? coverUrl,
    String? source,
    String? targetUrl,
    String? seriesId,
    String? author,
    int? totalEpisodes,
    int? addedAt,
  }) {
    return WatchLaterItem(
      id: id ?? this.id,
      title: title ?? this.title,
      originalTitle: originalTitle ?? this.originalTitle,
      translatedTitle: translatedTitle ?? this.translatedTitle,
      coverUrl: coverUrl ?? this.coverUrl,
      source: source ?? this.source,
      targetUrl: targetUrl ?? this.targetUrl,
      seriesId: seriesId ?? this.seriesId,
      author: author ?? this.author,
      totalEpisodes: totalEpisodes ?? this.totalEpisodes,
      addedAt: addedAt ?? this.addedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        if (originalTitle != null) 'originalTitle': originalTitle,
        if (translatedTitle != null) 'translatedTitle': translatedTitle,
        if (coverUrl != null) 'coverUrl': coverUrl,
        'source': source,
        'targetUrl': targetUrl,
        if (seriesId != null) 'seriesId': seriesId,
        if (author != null) 'author': author,
        if (totalEpisodes != null) 'totalEpisodes': totalEpisodes,
        'addedAt': addedAt,
      };

  factory WatchLaterItem.fromJson(Map<String, dynamic> json) => WatchLaterItem(
        id: json['id'] as String,
        title: json['title'] as String,
        originalTitle: json['originalTitle'] as String?,
        translatedTitle: json['translatedTitle'] as String?,
        coverUrl: json['coverUrl'] as String?,
        source: json['source'] as String? ?? 'bilibili',
        targetUrl: json['targetUrl'] as String,
        seriesId: json['seriesId'] as String?,
        author: json['author'] as String?,
        totalEpisodes: json['totalEpisodes'] as int?,
        addedAt: json['addedAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      );
}
