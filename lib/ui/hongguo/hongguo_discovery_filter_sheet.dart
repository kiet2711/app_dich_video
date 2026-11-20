import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/media/hongguo/hongguo_discovery_service.dart';
import '../theme/app_theme.dart';

/// Tổ hợp lọc nhanh 1 chạm cho những gu phim phổ biến nhất (học đường AI/2D, tu tiên 3D, ngôn tình...).
class HongguoQuickPreset {
  final String label;
  final HongguoDiscoverySelection selection;

  const HongguoQuickPreset({
    required this.label,
    required this.selection,
  });
}

const List<HongguoQuickPreset> kHongguoQuickPresets = <HongguoQuickPreset>[
  HongguoQuickPreset(
    label: '🎓 Anime 2D · Học đường',
    selection: HongguoDiscoverySelection(
      genreKind: HongguoGenreKind.comicSeries,
      filters: <String, String>{
        'category_dim_art_style': 'cate_5416',
        'category_dim_epoch': 'cate_4',
        'gender': '0',
        'sort': 'hot_score',
      },
    ),
  ),
  HongguoQuickPreset(
    label: '🤖 Phim AI · Học đường · Nữ tần',
    selection: HongguoDiscoverySelection(
      genreKind: HongguoGenreKind.aiSeries,
      filters: <String, String>{
        'category_dim_epoch': 'cate_4',
        'gender': '0',
        'sort': 'hot_score',
      },
    ),
  ),
  HongguoQuickPreset(
    label: '✨ Hoạt hình 3D · Tu tiên',
    selection: HongguoDiscoverySelection(
      genreKind: HongguoGenreKind.comicSeries,
      filters: <String, String>{
        'category_dim_art_style': 'cate_5415',
        'category_dim_theme': 'cate_7',
        'sort': 'hot_score',
      },
    ),
  ),
  HongguoQuickPreset(
    label: '💘 Người thật · Thanh xuân',
    selection: HongguoDiscoverySelection(
      genreKind: HongguoGenreKind.realPlay,
      filters: <String, String>{
        'category_dim_theme': 'cate_5023',
        'gender': '0',
        'sort': 'hot_score',
      },
    ),
  ),
  HongguoQuickPreset(
    label: '⚡ Người thật · Nghịch tập',
    selection: HongguoDiscoverySelection(
      genreKind: HongguoGenreKind.realPlay,
      filters: <String, String>{
        'category_dim_theme': 'cate_5031',
        'gender': '1',
        'sort': 'hot_score',
      },
    ),
  ),
  HongguoQuickPreset(
    label: '🆕 Phim AI mới lên sóng',
    selection: HongguoDiscoverySelection(
      genreKind: HongguoGenreKind.aiSeries,
      filters: <String, String>{
        'sort': 'online_time',
      },
    ),
  ),
];

/// BottomSheet Bộ lọc Đa chiều dùng chung cho Kho Phim và Lướt Shorts Hồng Quả.
/// Phản ánh đúng taxonomy nhiều trục của ByteDance (`genre`, `art_style`, `epoch`, `theme`, `role`, `gender`, `sort`...).
class HongguoDiscoveryFilterSheet extends StatefulWidget {
  final HongguoDiscoverySelection initialSelection;
  final Color? accentColor;

  const HongguoDiscoveryFilterSheet({
    super.key,
    required this.initialSelection,
    this.accentColor,
  });

  static Future<HongguoDiscoverySelection?> show(
    BuildContext context, {
    required HongguoDiscoverySelection initialSelection,
    Color? accentColor,
  }) {
    HapticFeedback.mediumImpact();
    final inheritedTheme = Theme.of(context);
    return showModalBottomSheet<HongguoDiscoverySelection>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Theme(
        data: inheritedTheme,
        child: HongguoDiscoveryFilterSheet(
          initialSelection: initialSelection,
          accentColor: accentColor,
        ),
      ),
    );
  }

  @override
  State<HongguoDiscoveryFilterSheet> createState() =>
      _HongguoDiscoveryFilterSheetState();
}

class _HongguoDiscoveryFilterSheetState
    extends State<HongguoDiscoveryFilterSheet> {
  late HongguoDiscoverySelection _selection;
  late List<HongguoSelectorGroup> _groups;
  final Set<String> _expandedGroups = <String>{};
  bool _refreshingGroups = false;

  @override
  void initState() {
    super.initState();
    _selection = widget.initialSelection;
    _groups = HongguoDiscoveryService.instance.getSelectorGroups(_selection.genreKind);
    unawaited(_refreshServerGroups(_selection.genreKind));
  }

  Future<void> _refreshServerGroups(HongguoGenreKind kind) async {
    setState(() => _refreshingGroups = true);
    try {
      final page = await HongguoDiscoveryService.instance.fetchDiscovery(
        HongguoDiscoverySelection(genreKind: kind),
      );
      if (!mounted || _selection.genreKind != kind) return;
      if (page.selectorGroups.isNotEmpty) {
        setState(() {
          _groups = page.selectorGroups;
          _refreshingGroups = false;
        });
        return;
      }
    } catch (_) {}
    if (mounted) {
      setState(() => _refreshingGroups = false);
    }
  }

  void _selectGenreKind(HongguoGenreKind next) {
    if (_selection.genreKind == next) return;
    HapticFeedback.selectionClick();
    setState(() {
      _selection = _selection.withGenreKind(next);
      _groups = HongguoDiscoveryService.instance.getSelectorGroups(next);
      _expandedGroups.clear();
    });
    unawaited(_refreshServerGroups(next));
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppThemePalette.of(context);
    final accent = widget.accentColor ?? palette.accentFor(AppTabId.hongguo);
    final summary = _selection.buildSummaryLabel(_groups);
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.86,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: palette.isDark ? 0.55 : 0.16),
            blurRadius: 20,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: palette.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 12, 10),
            child: Row(
              children: [
                Icon(Icons.tune_rounded, color: accent, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Bộ lọc (筛选)',
                        style: TextStyle(
                          color: palette.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Chủ đề · Thiết lập · Bối cảnh · Kho nội dung',
                        style: TextStyle(color: palette.textMuted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                if (_refreshingGroups)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.8, color: accent),
                    ),
                  ),
                IconButton(
                  icon: Icon(Icons.close_rounded, color: palette.textMuted, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Divider(color: palette.border, height: 1),
          Expanded(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 0. GỢI Ý NHANH 1 CHẠM
                  Text(
                    '⚡ Chọn nhanh gu phổ biến',
                    style: TextStyle(
                      color: palette.textSecondary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    child: Row(
                      children: kHongguoQuickPresets.map((preset) {
                        final isSel = _selection == preset.selection;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _buildChip(
                            palette: palette,
                            accent: accent,
                            label: preset.label,
                            isSelected: isSel,
                            onTap: () {
                              setState(() {
                                _selection = preset.selection;
                                _groups = HongguoDiscoveryService.instance
                                    .getSelectorGroups(preset.selection.genreKind);
                              });
                              unawaited(_refreshServerGroups(preset.selection.genreKind));
                            },
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 1. KHO NỘI DUNG (NGƯỜI THẬT / HOẠT HÌNH / PHIM AI)
                  Row(
                    children: [
                      Text(
                        '1. Kho nội dung',
                        style: TextStyle(
                          color: palette.textSecondary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'Tách riêng hệ sinh thái',
                        style: TextStyle(
                          color: palette.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: HongguoGenreKind.values.map((kind) {
                      final isSel = _selection.genreKind == kind;
                      return _buildChip(
                        palette: palette,
                        accent: accent,
                        label: '${kind.emoji} ${kind.label}',
                        isSelected: isSel,
                        onTap: () => _selectGenreKind(kind),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 18),

                  // 2. CÁC TRỤC LỌC ĐA CHIỀU TỪ SERVER
                  for (final group in _orderedGroups(_groups)) ...[
                    _buildGroupSection(palette, accent, group),
                    const SizedBox(height: 16),
                  ],
                ],
              ),
            ),
          ),
          Container(
            padding: EdgeInsets.fromLTRB(16, 10, 16, bottomInset + 12),
            decoration: BoxDecoration(
              color: palette.surface,
              border: Border(top: BorderSide(color: palette.border)),
            ),
            child: Row(
              children: [
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: palette.textSecondary,
                    side: BorderSide(color: palette.border),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    setState(
                      () => _selection = HongguoDiscoverySelection(
                        genreKind: _selection.genreKind,
                      ),
                    );
                  },
                  child: const Text('Xóa lọc', style: TextStyle(fontSize: 13)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: Text(
                      'Áp dụng: $summary',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: palette.onColor(accent),
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: () => Navigator.pop(context, _selection),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<HongguoSelectorGroup> _orderedGroups(List<HongguoSelectorGroup> raw) {
    const priority = <String>[
      'category_dim_theme',
      'category_dim_role',
      'category_dim_epoch',
      'category_dim_art_style',
      'gender',
      'creation_status',
      'online_time',
      'sort',
    ];
    final sorted = List<HongguoSelectorGroup>.from(raw);
    sorted.sort((a, b) {
      final ia = priority.indexOf(a.type);
      final ib = priority.indexOf(b.type);
      return (ia < 0 ? 99 : ia).compareTo(ib < 0 ? 99 : ib);
    });
    return sorted;
  }

  Widget _buildGroupSection(
    AppThemePalette palette,
    Color accent,
    HongguoSelectorGroup group,
  ) {
    final current = _selection.valueOf(group.type);
    final isSort = group.type == 'sort';
    final effectiveCurrent = current;

    final isMainCatalogAxis = group.type == 'category_dim_theme' ||
        group.type == 'category_dim_role' ||
        group.type == 'category_dim_epoch';
    final isExpanded = isMainCatalogAxis || _expandedGroups.contains(group.type);
    const collapseLimit = 14;
    final needsCollapse = !isExpanded && group.options.length > collapseLimit;
    var visibleOptions = needsCollapse
        ? group.options.take(collapseLimit).toList()
        : group.options;

    if (needsCollapse && effectiveCurrent.isNotEmpty) {
      final selectedOpt = group.options.where((o) => o.id == effectiveCurrent);
      if (selectedOpt.isNotEmpty &&
          visibleOptions.every((o) => o.id != effectiveCurrent)) {
        visibleOptions = <HongguoSelectorOption>[
          ...visibleOptions,
          selectedOpt.first,
        ];
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              group.label,
              style: TextStyle(
                color: palette.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 6),
            if (group.type == 'category_dim_epoch')
              Flexible(
                child: Text(
                  '(Đô thị, Học đường, Cổ đại...)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.textMuted,
                    fontSize: 11,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (isMainCatalogAxis)
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = 8.0;
              final itemWidth = (constraints.maxWidth - spacing * 2) / 3;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  for (final opt in visibleOptions)
                    SizedBox(
                      width: itemWidth,
                      child: _buildGridChip(
                        palette: palette,
                        accent: accent,
                        label: opt.viLabel,
                        isSelected: effectiveCurrent == opt.id,
                        onTap: () => setState(
                          () => _selection = _selection.withFilter(
                            group.type,
                            effectiveCurrent == opt.id ? '' : opt.id,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildChip(
                palette: palette,
                accent: accent,
                label: isSort ? '✨ Theo tài khoản' : 'Tất cả',
                isSelected: effectiveCurrent.isEmpty,
                onTap: () => setState(
                  () => _selection = _selection.withFilter(group.type, ''),
                ),
              ),
              for (final opt in visibleOptions)
                _buildChip(
                  palette: palette,
                  accent: accent,
                  label: opt.viLabel,
                  isSelected: effectiveCurrent == opt.id,
                  onTap: () => setState(
                    () => _selection = _selection.withFilter(
                      group.type,
                      effectiveCurrent == opt.id ? '' : opt.id,
                    ),
                  ),
                ),
              if (needsCollapse)
                _buildChip(
                  palette: palette,
                  accent: accent,
                  label: 'Xem tất cả (${group.options.length}) ▾',
                  isSelected: false,
                  onTap: () => setState(() => _expandedGroups.add(group.type)),
                ),
            ],
          ),
      ],
    );
  }

  Widget _buildGridChip({
    required AppThemePalette palette,
    required Color accent,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected
              ? accent.withValues(alpha: palette.isDark ? 0.22 : 0.14)
              : palette.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? accent : palette.border,
            width: isSelected ? 1.3 : 0.7,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: isSelected ? accent : palette.textSecondary,
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildChip({
    required AppThemePalette palette,
    required Color accent,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected
              ? accent.withValues(alpha: palette.isDark ? 0.2 : 0.14)
              : palette.surfaceAlt,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isSelected ? accent : palette.border,
            width: isSelected ? 1.3 : 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? accent : palette.textSecondary,
            fontSize: 12.5,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

