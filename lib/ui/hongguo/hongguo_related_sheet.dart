import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/ai/offline_mlkit_translator.dart';
import '../../domain/media/hongguo/hongguo_cloud_account_service.dart';
import '../../domain/media/hongguo/hongguo_discovery_service.dart';
import '../../domain/media/hongguo/hongguo_similar_engine.dart';
import '../../domain/media/hongguo_resolver.dart';
import '../../domain/media/network_header_helper.dart';
import '../theme/app_theme.dart';

/// BottomSheet "Phim tương tự & Đề xuất liên quan (`相关推荐`)" dùng chung cho cả Shorts Feed và Chi tiết phim.
/// Gọi trực tiếp API ByteDance `/reading/bookapi/plan/v:version/` (`show_type == 547` + `506`),
/// hiển thị các mùa/phần liên quan kèm lưới poster 3 cột chuẩn app Hồng Quả gốc.
class HongguoRelatedDramaSheet extends StatefulWidget {
  final HongguoDramaDetail currentDetail;
  final bool isTranslationEnabled;
  final void Function(HongguoDramaItem drama) onSelectDrama;
  final void Function(List<HongguoDramaItem> dramas)? onPlaySimilarFeed;

  const HongguoRelatedDramaSheet({
    super.key,
    required this.currentDetail,
    this.isTranslationEnabled = true,
    required this.onSelectDrama,
    this.onPlaySimilarFeed,
  });

  static Future<void> show(
    BuildContext context, {
    required HongguoDramaDetail currentDetail,
    bool isTranslationEnabled = true,
    required void Function(HongguoDramaItem drama) onSelectDrama,
    void Function(List<HongguoDramaItem> dramas)? onPlaySimilarFeed,
  }) {
    HapticFeedback.mediumImpact();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => HongguoRelatedDramaSheet(
        currentDetail: currentDetail,
        isTranslationEnabled: isTranslationEnabled,
        onSelectDrama: onSelectDrama,
        onPlaySimilarFeed: onPlaySimilarFeed,
      ),
    );
  }

  @override
  State<HongguoRelatedDramaSheet> createState() =>
      _HongguoRelatedDramaSheetState();
}

class _HongguoRelatedDramaSheetState extends State<HongguoRelatedDramaSheet> {
  bool _isLoading = true;
  SimilarBundleResult _bundle = const SimilarBundleResult();
  final Set<String> _reservedIds = <String>{};

  @override
  void initState() {
    super.initState();
    _loadRelated();
  }

  Future<void> _loadRelated() async {
    try {
      final result = await HongguoSimilarEngine.instance.findSimilarBundle(
        detail: widget.currentDetail,
      );
      if (mounted) {
        setState(() {
          _bundle = result;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _reserveSeason(HongguoRelatedSeasonItem item) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ok = await HongguoCloudAccountService.instance
          .reserveSeries(item.drama.seriesId);
      if (!mounted) return;
      if (ok) {
        setState(() => _reservedIds.add(item.drama.seriesId));
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? 'Đã đặt lịch hẹn phần mới "${item.drama.title}"'
                : 'Không thể đặt lịch lúc này',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final curTitle = widget.isTranslationEnabled
        ? (OfflineMlKitTranslator.getCachedTitle(widget.currentDetail.title) ??
            widget.currentDetail.title)
        : widget.currentDetail.title;
    final curTags = HongguoSimilarEngine.instance.extractTagsFromDrama(
      tags: widget.currentDetail.tags,
      title: widget.currentDetail.title,
      intro: widget.currentDetail.intro,
    );
    final sourceCat = widget.currentDetail.sourceCategory.isNotEmpty
        ? widget.currentDetail.sourceCategory
        : HongguoResolver.inferSourceCategoryFromIds(
            widget.currentDetail.categoryIds,
            tags: curTags,
          );
    final sourceKind = sourceCat.isNotEmpty
        ? HongguoGenreKind.fromAny(sourceCat)
        : null;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.80,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF16181D),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black87,
            blurRadius: 18,
            offset: Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 12, 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: AppColors.primaryEmerald.withValues(alpha: 0.16),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.auto_awesome_motion_rounded,
                    color: AppColors.primaryEmerald,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text(
                            'Đề xuất tương tự',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (sourceKind != null) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                '${sourceKind.emoji} ${sourceKind.shortLabel}',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Cùng thể loại với: $curTitle',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    color: Colors.white70,
                    size: 20,
                  ),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          if (curTags.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: Colors.black12,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    const Text(
                      'Thể loại: ',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                    for (final tag in curTags.take(5))
                      Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.white12, width: 0.6),
                        ),
                        child: Text(
                          HongguoSimilarEngine.getTagLabel(tag),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          const Divider(color: Colors.white12, height: 1),
          Expanded(
            child: _isLoading
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(
                            color: AppColors.primaryEmerald,
                            strokeWidth: 2.2,
                          ),
                        ),
                        SizedBox(height: 10),
                        Text(
                          'Đang tải đề xuất chuẩn từ Hồng Quả...',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ],
                    ),
                  )
                : (_bundle.seasons.isEmpty && _bundle.similar.isEmpty)
                    ? const Center(
                        child: Text(
                          'Chưa có đề xuất liên quan cho bộ phim này.',
                          style: TextStyle(color: Colors.white54, fontSize: 13),
                        ),
                      )
                    : CustomScrollView(
                        physics: const BouncingScrollPhysics(),
                        slivers: [
                          if (widget.onPlaySimilarFeed != null &&
                              _bundle.similar.isNotEmpty)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(14, 12, 14, 6),
                                child: SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton.icon(
                                    icon: const Icon(
                                      Icons.play_arrow_rounded,
                                      size: 20,
                                    ),
                                    label: Text(
                                      '⚡ Lướt chuỗi ${_bundle.similar.length} phim cùng gu này',
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.primaryEmerald,
                                      foregroundColor: Colors.black,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(18),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 10,
                                      ),
                                    ),
                                    onPressed: () => widget.onPlaySimilarFeed!(
                                      _bundle.similar
                                          .map((r) => r.drama)
                                          .toList(),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (_bundle.seasons.isNotEmpty) ...[
                            const SliverToBoxAdapter(
                              child: Padding(
                                padding: EdgeInsets.fromLTRB(14, 10, 14, 8),
                                child: Text(
                                  '📚 Các phần / Mùa liên quan',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                            SliverToBoxAdapter(
                              child: SizedBox(
                                height: 158,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                  ),
                                  itemCount: _bundle.seasons.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(width: 10),
                                  itemBuilder: (_, i) {
                                    final season = _bundle.seasons[i];
                                    return _buildSeasonCard(season);
                                  },
                                ),
                              ),
                            ),
                          ],
                          if (_bundle.similar.isNotEmpty) ...[
                            const SliverToBoxAdapter(
                              child: Padding(
                                padding: EdgeInsets.fromLTRB(14, 14, 14, 10),
                                child: Text(
                                  '✨ Có thể bạn sẽ thích',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                            SliverPadding(
                              padding:
                                  const EdgeInsets.fromLTRB(14, 0, 14, 24),
                              sliver: SliverGrid(
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  childAspectRatio: 0.54,
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 12,
                                ),
                                delegate: SliverChildBuilderDelegate(
                                  (ctx, i) => _buildGridCard(
                                    _bundle.similar[i],
                                  ),
                                  childCount: _bundle.similar.length,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildSeasonCard(HongguoRelatedSeasonItem season) {
    final drama = season.drama;
    final reserved = _reservedIds.contains(drama.seriesId);
    return SizedBox(
      width: 98,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: season.upcoming
            ? () => _reserveSeason(season)
            : () => widget.onSelectDrama(drama),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: _buildPosterImage(drama.cover),
                  ),
                  if (season.seasonLabel.isNotEmpty)
                    Positioned(
                      top: 5,
                      left: 5,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.72),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          season.seasonLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  if (season.upcoming)
                    Positioned(
                      bottom: 5,
                      left: 5,
                      right: 5,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: reserved
                              ? Colors.white24
                              : const Color(0xFFFF6A00),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          reserved ? 'Đã hẹn' : 'Đặt lịch',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 5),
            _buildDramaTitle(drama.title),
          ],
        ),
      ),
    );
  }

  Widget _buildGridCard(SimilarDramaResult item) {
    final drama = item.drama;
    final primaryTag = item.matchedTags.isNotEmpty
        ? HongguoSimilarEngine.getTagLabel(item.matchedTags.first)
        : (drama.tags.isNotEmpty
            ? HongguoSimilarEngine.getTagLabel(drama.tags.first)
            : '');
    final subLine = [
      if (drama.metricText.isNotEmpty) drama.metricText,
      if (primaryTag.isNotEmpty) primaryTag,
      if (drama.metricText.isEmpty && primaryTag.isEmpty && drama.episodeCount > 0)
        '${drama.episodeCount} tập',
    ].join(' · ');

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => widget.onSelectDrama(drama),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: _buildPosterImage(drama.cover),
                ),
                if (drama.episodeCount > 0)
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${drama.episodeCount}T',
                        style: const TextStyle(
                          color: AppColors.accentGold,
                          fontSize: 9.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          _buildDramaTitle(drama.title),
          if (subLine.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subLine,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white54, fontSize: 10.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPosterImage(String cover) {
    if (cover.isEmpty) {
      return Container(
        color: const Color(0xFF26282E),
        child: const Center(
          child: Icon(Icons.movie_rounded, color: Colors.white30, size: 28),
        ),
      );
    }
    return Image.network(
      cover,
      headers: NetworkHeaderHelper.getHeadersForUrl(cover),
      cacheWidth: 280,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => Container(
        color: const Color(0xFF26282E),
        child: const Center(
          child: Icon(Icons.movie_rounded, color: Colors.white30, size: 28),
        ),
      ),
    );
  }

  Widget _buildDramaTitle(String title) {
    if (!widget.isTranslationEnabled) {
      return Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11.8,
          fontWeight: FontWeight.w600,
          height: 1.25,
        ),
      );
    }
    final cached = OfflineMlKitTranslator.getCachedTitle(title);
    if (cached != null) {
      return Text(
        cached,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11.8,
          fontWeight: FontWeight.w600,
          height: 1.25,
        ),
      );
    }
    return FutureBuilder<String>(
      future: OfflineMlKitTranslator.translateHongguoTitle(title),
      initialData: title,
      builder: (_, snap) {
        return Text(
          snap.data ?? title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11.8,
            fontWeight: FontWeight.w600,
            height: 1.25,
          ),
        );
      },
    );
  }
}

