import 'package:flutter/material.dart';

import '../../domain/storage/storage_cleaner_service.dart';
import '../theme/app_theme.dart';

class StorageCleanerScreen extends StatefulWidget {
  const StorageCleanerScreen({super.key});

  @override
  State<StorageCleanerScreen> createState() => _StorageCleanerScreenState();
}

class _StorageCleanerScreenState extends State<StorageCleanerScreen> {
  bool _isLoading = true;
  StorageScanResult? _scanResult;
  StorageCategory? _selectedCategory; // null = Tất cả
  final Set<String> _selectedPaths = {};
  bool _isDeleting = false;

  @override
  void initState() {
    super.initState();
    _loadStorageData();
  }

  Future<void> _loadStorageData() async {
    setState(() {
      _isLoading = true;
      _selectedPaths.clear();
    });
    final result = await StorageCleanerService.scanStorage();
    if (!mounted) return;
    setState(() {
      _scanResult = result;
      _isLoading = false;
    });
  }

  List<StorageFileItem> get _filteredItems {
    if (_scanResult == null) return [];
    if (_selectedCategory == null) return _scanResult!.items;
    return _scanResult!.items
        .where((it) => it.category == _selectedCategory)
        .toList();
  }

  int get _selectedTotalBytes {
    if (_scanResult == null) return 0;
    var total = 0;
    for (final it in _scanResult!.items) {
      if (_selectedPaths.contains(it.path)) {
        total += it.sizeBytes;
      }
    }
    return total;
  }

  void _toggleSelectAll() {
    final currentList = _filteredItems;
    final allSelected = currentList.every((it) => _selectedPaths.contains(it.path));

    setState(() {
      if (allSelected) {
        for (final it in currentList) {
          _selectedPaths.remove(it.path);
        }
      } else {
        for (final it in currentList) {
          _selectedPaths.add(it.path);
        }
      }
    });
  }

  Future<void> _confirmDeleteSelected() async {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.history);
    final itemsToDelete = _scanResult!.items
        .where((it) => _selectedPaths.contains(it.path))
        .toList();
    if (itemsToDelete.isEmpty) return;

    final freedMb = StorageScanResult.format(_selectedTotalBytes);

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: palette.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 28),
            SizedBox(width: 10),
            Expanded(
              child: Text('Xác nhận dọn dẹp', style: TextStyle(fontSize: 18)),
            ),
          ],
        ),
        content: Text(
          'Bạn có chắc chắn muốn giải phóng $freedMb bằng cách xóa ${itemsToDelete.length} tệp đã chọn?\n\n(Lưu ý: Phụ đề hoặc video offline bị xóa sẽ không thể phục hồi).',
          style: TextStyle(color: palette.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Hủy', style: TextStyle(color: palette.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Xóa $freedMb'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isDeleting = true);
    final freed = await StorageCleanerService.deleteItems(itemsToDelete);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '✅ Đã dọn dẹp thành công! Giải phóng ${StorageScanResult.format(freed)} dung lượng máy.',
          style: TextStyle(color: palette.onColor(accent)),
        ),
        backgroundColor: accent,
      ),
    );

    await _loadStorageData();
    if (mounted) setState(() => _isDeleting = false);
  }

  Future<void> _smartCleanJunk() async {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.history);
    if (_scanResult == null || _scanResult!.safeCleanSizeBytes == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✨ Bộ nhớ rác tạm rất sạch sẽ! Không có file dở dang.')),
      );
      return;
    }

    final safeMb = _scanResult!.formattedSafeClean;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: palette.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.auto_delete_rounded, color: accent, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Dọn rác nhanh an toàn',
                style: TextStyle(color: palette.textPrimary, fontSize: 18),
              ),
            ),
          ],
        ),
        content: Text(
          'Hệ thống sẽ tự động quét và xóa sạch $safeMb gồm:\n• Tệp video tải dở dang (.part)\n• Bộ nhớ cache tạm thời hệ thống (iOS picker / audio tạm)\n• Các phiên cache cũ không còn dùng\n\n(Không xóa video offline hay phụ đề của bạn).',
          style: TextStyle(color: palette.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Hủy', style: TextStyle(color: palette.textMuted)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: palette.onColor(accent),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.bolt, size: 18),
            onPressed: () => Navigator.pop(ctx, true),
            label: Text('Dọn ngay $safeMb'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isDeleting = true);
    final freed = await StorageCleanerService.smartCleanJunk(_scanResult!);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '⚡ Đã dọn sạch rác an toàn! Giải phóng ${StorageScanResult.format(freed)}.',
          style: TextStyle(color: palette.onColor(accent)),
        ),
        backgroundColor: accent,
      ),
    );

    await _loadStorageData();
    if (mounted) setState(() => _isDeleting = false);
  }

  Future<void> _deleteSingleItem(StorageFileItem item) async {
    final palette = AppThemePalette.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: palette.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Xóa tệp này?', style: TextStyle(color: palette.textPrimary, fontSize: 17)),
        content: Text(
          'Bạn có muốn xóa "${item.displayName}" (${item.formattedSize}) không?',
          style: TextStyle(color: palette.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Hủy', style: TextStyle(color: palette.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    await StorageCleanerService.deleteItems([item]);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Đã xóa "${item.displayName}" (${item.formattedSize})'),
        duration: const Duration(seconds: 2),
      ),
    );
    await _loadStorageData();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.history);
    final bg = palette.backgroundFor(AppTabId.history);

    final filtered = _filteredItems;
    final allSelected = filtered.isNotEmpty && filtered.every((it) => _selectedPaths.contains(it.path));

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: palette.textPrimary,
        title: Text(
          'Dọn Dẹp Bộ Nhớ Thông Minh',
          style: TextStyle(
            color: palette.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          if (!_isLoading && filtered.isNotEmpty)
            TextButton(
              onPressed: _toggleSelectAll,
              child: Text(
                allSelected ? 'Bỏ chọn' : 'Chọn tất cả',
                style: TextStyle(color: accent, fontWeight: FontWeight.bold),
              ),
            ),
          IconButton(
            icon: Icon(Icons.refresh, color: palette.textSecondary),
            tooltip: 'Quét lại bộ nhớ',
            onPressed: _isLoading ? null : _loadStorageData,
          ),
        ],
      ),
      body: _isLoading
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: accent),
                  const SizedBox(height: 16),
                  Text(
                    'Đang phân tích bộ nhớ ứng dụng...',
                    style: TextStyle(color: palette.textSecondary),
                  ),
                ],
              ),
            )
          : Stack(
              children: [
                Column(
                  children: [
                    _buildOverviewCard(),
                    _buildCategoryFilterBar(),
                    Expanded(
                      child: filtered.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.check_circle_outline_rounded,
                                    size: 64,
                                    color: palette.textMuted.withValues(alpha: 0.35),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    'Danh mục này không có tệp nào',
                                    style: TextStyle(color: palette.textMuted, fontSize: 14),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.only(
                                left: 16,
                                right: 16,
                                top: 8,
                                bottom: 96,
                              ),
                              itemCount: filtered.length,
                              itemBuilder: (ctx, index) {
                                final item = filtered[index];
                                final isSelected = _selectedPaths.contains(item.path);
                                return _buildFileItemCard(item, isSelected);
                              },
                            ),
                    ),
                  ],
                ),
                if (_selectedPaths.isNotEmpty) _buildBottomActionBar(),
                if (_isDeleting)
                  Container(
                    color: Colors.black54,
                    alignment: Alignment.center,
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: palette.surface,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: accent),
                          const SizedBox(height: 16),
                          Text(
                            'Đang dọn dẹp các tệp đã chọn...',
                            style: TextStyle(color: palette.textPrimary),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildOverviewCard() {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.history);
    final audioColor =
        palette.isDark ? Colors.lightBlueAccent : const Color(0xFF0284C7);
    final subColor =
        palette.isDark ? Colors.amberAccent : const Color(0xFFD97706);
    final tempColor =
        palette.isDark ? Colors.orangeAccent : const Color(0xFFEA580C);

    final result = _scanResult!;
    final totalBytes = result.totalSizeBytes;

    final vidPct = totalBytes > 0 ? (result.videoSizeBytes / totalBytes) : 0.0;
    final audPct = totalBytes > 0 ? (result.audioSizeBytes / totalBytes) : 0.0;
    final subPct = totalBytes > 0 ? (result.subtitleSizeBytes / totalBytes) : 0.0;
    final tmpPct = totalBytes > 0 ? (result.tempSizeBytes / totalBytes) : 0.0;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.border),
        boxShadow: palette.cardShadows,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'DUNG LƯỢNG ĐÃ DÙNG',
                      style: TextStyle(
                        color: palette.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          result.formattedTotal,
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '(${result.items.length} tệp)',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: palette.textMuted, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (result.safeCleanSizeBytes > 0) ...[
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: palette.onColor(accent),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.bolt, size: 18),
                  onPressed: _smartCleanJunk,
                  label: Text(
                    'Dọn rác: ${result.formattedSafeClean}',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),

          // Thanh phân bổ màu sắc (Multi-segment Storage Bar)
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              height: 10,
              child: Row(
                children: [
                  if (vidPct > 0)
                    Expanded(
                      flex: (vidPct * 1000).toInt().clamp(1, 1000),
                      child: Container(color: accent),
                    ),
                  if (audPct > 0)
                    Expanded(
                      flex: (audPct * 1000).toInt().clamp(1, 1000),
                      child: Container(color: audioColor),
                    ),
                  if (subPct > 0)
                    Expanded(
                      flex: (subPct * 1000).toInt().clamp(1, 1000),
                      child: Container(color: subColor),
                    ),
                  if (tmpPct > 0)
                    Expanded(
                      flex: (tmpPct * 1000).toInt().clamp(1, 1000),
                      child: Container(color: tempColor),
                    ),
                  if (totalBytes == 0)
                    Expanded(
                      child: Container(color: palette.surfaceAlt),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Chú thích các loại tệp (Legend)
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              _buildLegendItem(palette, 'Video', result.formattedVideo, accent),
              _buildLegendItem(palette, 'Âm thanh TTS', result.formattedAudio, audioColor),
              _buildLegendItem(palette, 'Phụ đề SRT', result.formattedSubtitle, subColor),
              _buildLegendItem(palette, 'Rác & Tạm', result.formattedTemp, tempColor),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLegendItem(
    AppThemePalette palette,
    String label,
    String sizeStr,
    Color color,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          '$label: ',
          style: TextStyle(color: palette.textSecondary, fontSize: 11),
        ),
        Text(
          sizeStr,
          style: TextStyle(
            color: palette.textPrimary,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildCategoryFilterBar() {
    final res = _scanResult!;
    final vidCount = res.items.where((i) => i.category == StorageCategory.video).length;
    final audCount = res.items.where((i) => i.category == StorageCategory.audio).length;
    final subCount = res.items.where((i) => i.category == StorageCategory.subtitle).length;
    final tmpCount = res.items.where((i) => i.category == StorageCategory.temp).length;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          _buildFilterChip('Tất cả (${res.items.length})', null),
          const SizedBox(width: 8),
          _buildFilterChip('🎬 Video ($vidCount)', StorageCategory.video),
          const SizedBox(width: 8),
          _buildFilterChip('🔊 Âm thanh ($audCount)', StorageCategory.audio),
          const SizedBox(width: 8),
          _buildFilterChip('📝 Phụ đề ($subCount)', StorageCategory.subtitle),
          const SizedBox(width: 8),
          _buildFilterChip('🧹 Rác & Tạm ($tmpCount)', StorageCategory.temp),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, StorageCategory? cat) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.history);
    final isSelected = _selectedCategory == cat;
    return InkWell(
      onTap: () => setState(() => _selectedCategory = cat),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? accent : palette.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? accent : palette.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? palette.onColor(accent) : palette.textSecondary,
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildFileItemCard(StorageFileItem item, bool isSelected) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.history);
    Color iconColor;
    IconData iconData;

    switch (item.category) {
      case StorageCategory.video:
        iconColor = accent;
        iconData = Icons.movie_filter_rounded;
        break;
      case StorageCategory.audio:
        iconColor =
            palette.isDark ? Colors.lightBlueAccent : const Color(0xFF0284C7);
        iconData = Icons.record_voice_over_rounded;
        break;
      case StorageCategory.subtitle:
        iconColor =
            palette.isDark ? Colors.amberAccent : const Color(0xFFD97706);
        iconData = Icons.subtitles_rounded;
        break;
      case StorageCategory.temp:
        iconColor =
            palette.isDark ? Colors.orangeAccent : const Color(0xFFEA580C);
        iconData = Icons.delete_sweep_rounded;
        break;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isSelected
            ? iconColor.withValues(alpha: 0.12)
            : palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSelected ? iconColor.withValues(alpha: 0.5) : palette.border,
          width: isSelected ? 1.5 : 1,
        ),
        boxShadow: palette.cardShadows,
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              value: isSelected,
              activeColor: iconColor,
              checkColor: palette.onColor(iconColor),
              side: BorderSide(color: palette.textMuted, width: 1.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
              onChanged: (val) {
                setState(() {
                  if (val == true) {
                    _selectedPaths.add(item.path);
                  } else {
                    _selectedPaths.remove(item.path);
                  }
                });
              },
            ),
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(iconData, color: iconColor, size: 20),
            ),
          ],
        ),
        title: Text(
          item.displayName,
          style: TextStyle(
            color: palette.textPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 13.5,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            item.description,
            style: TextStyle(color: palette.textMuted, fontSize: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: palette.surfaceAlt,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                item.formattedSize,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
            IconButton(
              icon: Icon(Icons.delete_outline, color: palette.textMuted, size: 20),
              tooltip: 'Xóa tệp này',
              onPressed: () => _deleteSingleItem(item),
            ),
          ],
        ),
        onTap: () {
          setState(() {
            if (isSelected) {
              _selectedPaths.remove(item.path);
            } else {
              _selectedPaths.add(item.path);
            }
          });
        },
      ),
    );
  }

  Widget _buildBottomActionBar() {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.history);
    final count = _selectedPaths.length;
    final totalSizeStr = StorageScanResult.format(_selectedTotalBytes);

    return Positioned(
      left: 16,
      right: 16,
      bottom: MediaQuery.paddingOf(context).bottom + 12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: palette.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: palette.isDark ? 0.5 : 0.14),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Đã chọn $count tệp',
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    'Giải phóng $totalSizeStr',
                    style: TextStyle(
                      color: accent,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.delete_forever, size: 18),
              onPressed: _confirmDeleteSelected,
              label: const Text(
                'Dọn Dẹp Ngay',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
