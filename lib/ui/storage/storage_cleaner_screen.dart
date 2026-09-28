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
    final itemsToDelete = _scanResult!.items
        .where((it) => _selectedPaths.contains(it.path))
        .toList();
    if (itemsToDelete.isEmpty) return;

    final freedMb = StorageScanResult.format(_selectedTotalBytes);

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2029),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: const [
            Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 28),
            SizedBox(width: 10),
            Text('Xác nhận dọn dẹp', style: TextStyle(color: Colors.white, fontSize: 18)),
          ],
        ),
        content: Text(
          'Bạn có chắc chắn muốn giải phóng $freedMb bằng cách xóa ${itemsToDelete.length} tệp đã chọn?\n\n(Lưu ý: Phụ đề hoặc video offline bị xóa sẽ không thể phục hồi).',
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy', style: TextStyle(color: Colors.white60)),
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
        ),
        backgroundColor: AppTheme.primaryEmerald,
      ),
    );

    await _loadStorageData();
    if (mounted) setState(() => _isDeleting = false);
  }

  Future<void> _smartCleanJunk() async {
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
        backgroundColor: const Color(0xFF1E2029),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: const [
            Icon(Icons.auto_delete_rounded, color: AppTheme.primaryEmerald, size: 28),
            SizedBox(width: 10),
            Text('Dọn rác nhanh an toàn', style: TextStyle(color: Colors.white, fontSize: 18)),
          ],
        ),
        content: Text(
          'Hệ thống sẽ tự động quét và xóa sạch $safeMb gồm:\n• Tệp video tải dở dang (.part)\n• Bộ nhớ cache tạm thời hệ thống (iOS picker / audio tạm)\n• Các phiên cache cũ không còn dùng\n\n(Không xóa video offline hay phụ đề của bạn).',
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryEmerald,
              foregroundColor: Colors.black,
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
        ),
        backgroundColor: AppTheme.primaryEmerald,
      ),
    );

    await _loadStorageData();
    if (mounted) setState(() => _isDeleting = false);
  }

  Future<void> _deleteSingleItem(StorageFileItem item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2029),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Xóa tệp này?', style: TextStyle(color: Colors.white, fontSize: 17)),
        content: Text(
          'Bạn có muốn xóa "${item.displayName}" (${item.formattedSize}) không?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy', style: TextStyle(color: Colors.white60)),
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
    final filtered = _filteredItems;
    final allSelected = filtered.isNotEmpty && filtered.every((it) => _selectedPaths.contains(it.path));

    return Scaffold(
      backgroundColor: AppTheme.darkBackground,
      appBar: AppBar(
        backgroundColor: AppTheme.darkBackground,
        elevation: 0,
        title: const Text(
          'Dọn Dẹp Bộ Nhớ Thông Minh',
          style: TextStyle(
            color: Colors.white,
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
                style: const TextStyle(color: AppTheme.primaryEmerald, fontWeight: FontWeight.bold),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            tooltip: 'Quét lại bộ nhớ',
            onPressed: _isLoading ? null : _loadStorageData,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: AppTheme.primaryEmerald),
                  SizedBox(height: 16),
                  Text(
                    'Đang phân tích bộ nhớ ứng dụng...',
                    style: TextStyle(color: Colors.white70),
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
                                    color: Colors.white.withValues(alpha: 0.2),
                                  ),
                                  const SizedBox(height: 12),
                                  const Text(
                                    'Danh mục này không có tệp nào',
                                    style: TextStyle(color: Colors.grey, fontSize: 14),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.only(
                                left: 16,
                                right: 16,
                                top: 8,
                                bottom: 90,
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
                        color: const Color(0xFF1E2029),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: AppTheme.primaryEmerald),
                          SizedBox(height: 16),
                          Text('Đang dọn dẹp các tệp đã chọn...', style: TextStyle(color: Colors.white)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildOverviewCard() {
    final result = _scanResult!;
    final totalBytes = result.totalSizeBytes;

    // Tỉ lệ phần trăm cho visual bar
    final vidPct = totalBytes > 0 ? (result.videoSizeBytes / totalBytes) : 0.0;
    final audPct = totalBytes > 0 ? (result.audioSizeBytes / totalBytes) : 0.0;
    final subPct = totalBytes > 0 ? (result.subtitleSizeBytes / totalBytes) : 0.0;
    final tmpPct = totalBytes > 0 ? (result.tempSizeBytes / totalBytes) : 0.0;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.darkCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.cardBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'DUNG LƯỢNG ĐÃ DÙNG',
                    style: TextStyle(
                      color: Colors.grey,
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
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '(${result.items.length} tệp)',
                        style: const TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                    ],
                  ),
                ],
              ),
              if (result.safeCleanSizeBytes > 0)
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryEmerald,
                    foregroundColor: Colors.black,
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
                      flex: (vidPct * 1000).toInt(),
                      child: Container(color: AppTheme.primaryEmerald),
                    ),
                  if (audPct > 0)
                    Expanded(
                      flex: (audPct * 1000).toInt(),
                      child: Container(color: Colors.blueAccent),
                    ),
                  if (subPct > 0)
                    Expanded(
                      flex: (subPct * 1000).toInt(),
                      child: Container(color: Colors.amberAccent),
                    ),
                  if (tmpPct > 0)
                    Expanded(
                      flex: (tmpPct * 1000).toInt(),
                      child: Container(color: Colors.orangeAccent),
                    ),
                  if (totalBytes == 0)
                    Expanded(
                      child: Container(color: Colors.white12),
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
              _buildLegendItem('Video', result.formattedVideo, AppTheme.primaryEmerald),
              _buildLegendItem('Âm thanh TTS', result.formattedAudio, Colors.blueAccent),
              _buildLegendItem('Phụ đề SRT', result.formattedSubtitle, Colors.amberAccent),
              _buildLegendItem('Rác & Tạm', result.formattedTemp, Colors.orangeAccent),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLegendItem(String label, String sizeStr, Color color) {
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
          style: const TextStyle(color: Colors.white60, fontSize: 11),
        ),
        Text(
          sizeStr,
          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
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
    final isSelected = _selectedCategory == cat;
    return InkWell(
      onTap: () => setState(() => _selectedCategory = cat),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.primaryEmerald : const Color(0xFF1E2029),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? AppTheme.primaryEmerald : Colors.white12,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.black : Colors.white70,
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildFileItemCard(StorageFileItem item, bool isSelected) {
    Color iconColor;
    IconData iconData;

    switch (item.category) {
      case StorageCategory.video:
        iconColor = AppTheme.primaryEmerald;
        iconData = Icons.movie_filter_rounded;
        break;
      case StorageCategory.audio:
        iconColor = Colors.blueAccent;
        iconData = Icons.record_voice_over_rounded;
        break;
      case StorageCategory.subtitle:
        iconColor = Colors.amberAccent;
        iconData = Icons.subtitles_rounded;
        break;
      case StorageCategory.temp:
        iconColor = Colors.orangeAccent;
        iconData = Icons.delete_sweep_rounded;
        break;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isSelected
            ? iconColor.withValues(alpha: 0.12)
            : const Color(0xFF191B22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSelected ? iconColor.withValues(alpha: 0.5) : Colors.white10,
          width: isSelected ? 1.5 : 1,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              value: isSelected,
              activeColor: iconColor,
              checkColor: Colors.black,
              side: const BorderSide(color: Colors.white30, width: 1.5),
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
                color: iconColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(iconData, color: iconColor, size: 20),
            ),
          ],
        ),
        title: Text(
          item.displayName,
          style: const TextStyle(
            color: Colors.white,
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
            style: const TextStyle(color: Colors.white54, fontSize: 11),
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
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                item.formattedSize,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.white38, size: 20),
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
    final count = _selectedPaths.length;
    final totalSizeStr = StorageScanResult.format(_selectedTotalBytes);

    return Positioned(
      left: 16,
      right: 16,
      bottom: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF222430),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
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
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    'Giải phóng $totalSizeStr',
                    style: const TextStyle(
                      color: AppTheme.primaryEmerald,
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
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
