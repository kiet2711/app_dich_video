import 'package:flutter/material.dart';
import '../../domain/ai/offline_mlkit_translator.dart';
import '../../domain/media/bilibili_resolver.dart';

class BilibiliSeasonSheet extends StatelessWidget {
  final BilibiliUgcSeason season;
  final String currentBvid;
  final void Function(BilibiliUgcEpisode episode) onSelectEpisode;

  const BilibiliSeasonSheet({
    super.key,
    required this.season,
    required this.currentBvid,
    required this.onSelectEpisode,
  });

  static Future<void> show({
    required BuildContext context,
    required BilibiliUgcSeason season,
    required String currentBvid,
    required void Function(BilibiliUgcEpisode episode) onSelectEpisode,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => BilibiliSeasonSheet(
        season: season,
        currentBvid: currentBvid,
        onSelectEpisode: onSelectEpisode,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: const BoxDecoration(
        color: Color(0xFF14161E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Drag handle
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 8),
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header Hợp tập
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFB7299).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(
                    Icons.video_library_rounded,
                    color: Color(0xFFFB7299),
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Hợp tập: ${season.title}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Tổng cộng ${season.episodes.length} tập',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white60, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white12, height: 1),

          // Danh sách tập
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              itemCount: season.episodes.length,
              itemBuilder: (ctx, index) {
                final ep = season.episodes[index];
                final isCurrent = ep.bvid == currentBvid;

                return InkWell(
                  onTap: () {
                    Navigator.pop(context);
                    if (!isCurrent) {
                      onSelectEpisode(ep);
                    }
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isCurrent
                          ? const Color(0xFFFB7299).withValues(alpha: 0.15)
                          : const Color(0xFF1E212B),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isCurrent
                            ? const Color(0xFFFB7299)
                            : Colors.transparent,
                        width: isCurrent ? 1.2 : 0,
                      ),
                    ),
                    child: Row(
                      children: [
                        // Số thứ tự hoặc icon equalizer nếu đang phát
                        Container(
                          width: 32,
                          alignment: Alignment.center,
                          child: isCurrent
                              ? const Icon(
                                  Icons.graphic_eq_rounded,
                                  color: Color(0xFFFB7299),
                                  size: 18,
                                )
                              : Text(
                                  '${index + 1}',
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                        ),
                        const SizedBox(width: 8),

                        // Thumbnail nhỏ
                        if (ep.cover.isNotEmpty) ...[
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: SizedBox(
                              width: 64,
                              height: 38,
                              child: Image.network(
                                ep.cover,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => Container(
                                  color: Colors.black26,
                                  child: const Icon(Icons.movie_rounded, size: 16, color: Colors.white24),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],

                        // Tiêu đề tập
                        Expanded(
                          child: FutureBuilder<String>(
                            future: OfflineMlKitTranslator.translateHongguoTitle(ep.title),
                            initialData: ep.title,
                            builder: (context, snapshot) {
                              return Text(
                                snapshot.data ?? ep.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: isCurrent
                                      ? const Color(0xFFFB7299)
                                      : Colors.white,
                                  fontSize: 12.5,
                                  fontWeight: isCurrent
                                      ? FontWeight.bold
                                      : FontWeight.w500,
                                ),
                              );
                            },
                          ),
                        ),

                        if (ep.durationSeconds > 0) ...[
                          const SizedBox(width: 8),
                          Text(
                            BilibiliAnimeItem.formatDuration(ep.durationSeconds),
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
