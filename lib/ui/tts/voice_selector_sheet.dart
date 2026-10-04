import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/model/voice_model.dart';
import '../../domain/tts/voice_preview_helper.dart';
import '../theme/app_theme.dart';

class VoiceSelectorSheet extends StatefulWidget {
  final String currentVoiceType;
  final Color accentColor;
  final String title;
  final bool allowPreview;
  final String? initialPreviewText;

  const VoiceSelectorSheet({
    super.key,
    required this.currentVoiceType,
    this.accentColor = AppColors.primaryEmerald,
    this.title = 'Chọn Giọng Lồng Tiếng AI',
    this.allowPreview = false,
    this.initialPreviewText,
  });

  static Future<VoiceItem?> show(
    BuildContext context, {
    required String currentVoiceType,
    Color accentColor = AppColors.primaryEmerald,
    String title = 'Chọn Giọng Lồng Tiếng AI',
    bool allowPreview = false,
    String? initialPreviewText,
  }) {
    return showModalBottomSheet<VoiceItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => VoiceSelectorSheet(
        currentVoiceType: currentVoiceType,
        accentColor: accentColor,
        title: title,
        allowPreview: allowPreview,
        initialPreviewText: initialPreviewText,
      ),
    );
  }

  @override
  State<VoiceSelectorSheet> createState() => _VoiceSelectorSheetState();
}

class _VoiceSelectorSheetState extends State<VoiceSelectorSheet> {
  late String _selectedVoiceType;
  String _searchQuery = '';
  String _selectedCategory = 'all';

  VoicePreviewHelper? _previewHelper;
  late final TextEditingController _previewController;

  @override
  void initState() {
    super.initState();
    _selectedVoiceType = widget.currentVoiceType;
    if (widget.allowPreview) {
      _previewHelper = VoicePreviewHelper();
      _previewController = TextEditingController(
        text: widget.initialPreviewText?.trim().isNotEmpty == true
            ? widget.initialPreviewText!
            : VoicePreviewHelper.defaultPreviewText,
      );
    }
  }

  @override
  void dispose() {
    _previewHelper?.dispose();
    if (widget.allowPreview) {
      _previewController.dispose();
    }
    super.dispose();
  }

  bool _isMaleVoice(VoiceItem v) {
    final t = v.voiceType.toLowerCase();
    final d = v.displayName.toLowerCase();
    return t.contains('male') && !t.contains('female') ||
        d.contains('nam') ||
        d.contains('chàng trai') ||
        d.contains('thanh niên') ||
        d.contains('người kể') ||
        d.contains('alex');
  }

  bool _isReviewPhimVoice(VoiceItem v) {
    final d = v.displayName.toLowerCase();
    final desc = v.description.toLowerCase();
    return d.contains('review') || desc.contains('review');
  }

  List<VoiceItem> _getFilteredVoices() {
    return VoicePresets.vietnameseVoices.where((v) {
      // 1. Category filter
      if (_selectedCategory == 'female') {
        if (_isMaleVoice(v)) return false;
      } else if (_selectedCategory == 'male') {
        if (!_isMaleVoice(v)) return false;
      } else if (_selectedCategory == 'review') {
        if (!_isReviewPhimVoice(v)) return false;
      }

      // 2. Search query filter
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final matchesName = v.displayName.toLowerCase().contains(q);
        final matchesDesc = v.description.toLowerCase().contains(q);
        if (!matchesName && !matchesDesc) return false;
      }

      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filteredVoices = _getFilteredVoices();
    final screenHeight = MediaQuery.of(context).size.height;

    return Container(
      constraints: BoxConstraints(
        maxHeight: screenHeight * 0.85,
      ),
      decoration: const BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag handle
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.cardBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: widget.accentColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.record_voice_over_rounded,
                      color: widget.accentColor,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '21 giọng đọc CapCut tiếng Việt chuẩn cảm xúc',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: AppColors.textSecondary),
                    tooltip: 'Đóng',
                  ),
                ],
              ),
            ),

            // Search bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Container(
                height: 38,
                decoration: BoxDecoration(
                  color: AppColors.darkSurfaceVariant,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 10),
                    const Icon(Icons.search_rounded, size: 18, color: AppColors.textMuted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        style: const TextStyle(fontSize: 12, color: AppColors.textPrimary),
                        decoration: const InputDecoration(
                          hintText: 'Tìm giọng theo tên hoặc phong cách...',
                          hintStyle: TextStyle(fontSize: 12, color: AppColors.textMuted),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                        onChanged: (val) {
                          setState(() {
                            _searchQuery = val.trim();
                          });
                        },
                      ),
                    ),
                    if (_searchQuery.isNotEmpty)
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _searchQuery = '';
                          });
                        },
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 10),
                          child: Icon(Icons.close_rounded, size: 16, color: AppColors.textMuted),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // Ô nhập câu nghe thử giọng (Chỉ hiện khi allowPreview = true)
            if (widget.allowPreview) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.darkSurfaceVariant,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: widget.accentColor.withValues(alpha: 0.35),
                      width: 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.record_voice_over_rounded,
                            size: 14,
                            color: widget.accentColor,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Câu nghe thử (100% tiếng Việt):',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: widget.accentColor,
                            ),
                          ),
                          const Spacer(),
                          if (_previewController.text !=
                              VoicePreviewHelper.defaultPreviewText)
                            GestureDetector(
                              onTap: () {
                                setState(() {
                                  _previewController.text =
                                      VoicePreviewHelper.defaultPreviewText;
                                });
                              },
                              child: const Text(
                                'Đặt lại câu mẫu',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.white70,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      TextField(
                        controller: _previewController,
                        style: const TextStyle(fontSize: 12, color: Colors.white),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                          hintText: 'Nhập câu tiếng Việt muốn nghe thử...',
                          hintStyle:
                              TextStyle(fontSize: 12, color: AppColors.textMuted),
                        ),
                        maxLines: 2,
                        minLines: 1,
                      ),
                    ],
                  ),
                ),
              ),
            ],

            // Filter Chips
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  _buildCategoryChip('all', 'Tất cả (${VoicePresets.vietnameseVoices.length})'),
                  const SizedBox(width: 8),
                  _buildCategoryChip('female', 'Giọng Nữ'),
                  const SizedBox(width: 8),
                  _buildCategoryChip('male', 'Giọng Nam'),
                  const SizedBox(width: 8),
                  _buildCategoryChip('review', 'Review Phim'),
                ],
              ),
            ),

            const Divider(color: AppColors.cardBorder, height: 1),

            // Voices List
            Flexible(
              child: filteredVoices.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(
                        child: Text(
                          'Không tìm thấy giọng đọc phù hợp.',
                          style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      itemCount: filteredVoices.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, idx) {
                        final voice = filteredVoices[idx];
                        final isSelected = voice.voiceType == _selectedVoiceType;
                        final isMale = _isMaleVoice(voice);
                        final isReview = _isReviewPhimVoice(voice);

                        return InkWell(
                          onTap: () {
                            _previewHelper?.stop();
                            HapticFeedback.selectionClick();
                            setState(() {
                              _selectedVoiceType = voice.voiceType;
                            });
                            Navigator.pop(context, voice);
                          },
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? widget.accentColor.withValues(alpha: 0.12)
                                  : AppColors.darkSurfaceVariant,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isSelected ? widget.accentColor : AppColors.cardBorder,
                                width: isSelected ? 1.5 : 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                // Icon with Badge
                                Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: (isSelected
                                            ? widget.accentColor
                                            : (isReview
                                                ? Colors.amber
                                                : (isMale ? Colors.blueAccent : Colors.pinkAccent)))
                                        .withValues(alpha: 0.15),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    isReview
                                        ? Icons.movie_filter_rounded
                                        : (isMale ? Icons.face_rounded : Icons.face_3_rounded),
                                    color: isSelected
                                        ? widget.accentColor
                                        : (isReview
                                            ? Colors.amber
                                            : (isMale ? Colors.blueAccent : Colors.pinkAccent)),
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 12),

                                // Name & Description
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              voice.displayName,
                                              style: TextStyle(
                                                color: isSelected
                                                    ? widget.accentColor
                                                    : AppColors.textPrimary,
                                                fontSize: 14,
                                                fontWeight: FontWeight.bold,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          if (isReview) ...[
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(
                                                  horizontal: 5, vertical: 1),
                                              decoration: BoxDecoration(
                                                color: Colors.amber.withValues(alpha: 0.2),
                                                borderRadius: BorderRadius.circular(4),
                                                border: Border.all(
                                                    color: Colors.amber.withValues(alpha: 0.4),
                                                    width: 0.8),
                                              ),
                                              child: const Text(
                                                'Phim',
                                                style: TextStyle(
                                                  color: Colors.amber,
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        voice.description.isNotEmpty
                                            ? voice.description
                                            : 'Giọng đọc CapCut tự nhiên',
                                        style: const TextStyle(
                                          color: AppColors.textMuted,
                                          fontSize: 11,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),

                                // Nút Nghe thử giọng (Chỉ hiện khi allowPreview = true)
                                if (widget.allowPreview && _previewHelper != null) ...[
                                  ValueListenableBuilder<VoicePreviewState>(
                                    valueListenable: _previewHelper!.stateNotifier,
                                    builder: (context, pState, _) {
                                      final isThisVoice =
                                          pState.activeVoiceType == voice.voiceType;
                                      final isLoading =
                                          isThisVoice && pState.isLoading;
                                      final isPlaying =
                                          isThisVoice && pState.isPlaying;

                                      return Padding(
                                        padding: const EdgeInsets.only(right: 8),
                                        child: InkWell(
                                          onTap: () {
                                            HapticFeedback.selectionClick();
                                            _previewHelper!.togglePreview(
                                              voice: voice,
                                              text: _previewController.text,
                                            );
                                          },
                                          borderRadius:
                                              BorderRadius.circular(16),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: isThisVoice
                                                  ? widget.accentColor
                                                      .withValues(alpha: 0.22)
                                                  : Colors.white.withValues(
                                                      alpha: 0.06),
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              border: Border.all(
                                                color: isThisVoice
                                                    ? widget.accentColor
                                                    : Colors.white12,
                                                width: 1,
                                              ),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                if (isLoading)
                                                  SizedBox(
                                                    width: 12,
                                                    height: 12,
                                                    child:
                                                        CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      color: widget.accentColor,
                                                    ),
                                                  )
                                                else
                                                  Icon(
                                                    isPlaying
                                                        ? Icons.stop_rounded
                                                        : Icons
                                                            .volume_up_rounded,
                                                    size: 15,
                                                    color: isThisVoice
                                                        ? widget.accentColor
                                                        : Colors.white70,
                                                  ),
                                                const SizedBox(width: 4),
                                                Text(
                                                  isPlaying
                                                      ? 'Dừng'
                                                      : 'Thử giọng',
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    fontWeight:
                                                        FontWeight.bold,
                                                    color: isThisVoice
                                                        ? widget.accentColor
                                                        : Colors.white70,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ],

                                // Checkmark / Radio
                                if (isSelected)
                                  Icon(
                                    Icons.check_circle_rounded,
                                    color: widget.accentColor,
                                    size: 22,
                                  )
                                else
                                  Icon(
                                    Icons.radio_button_unchecked_rounded,
                                    color: AppColors.textMuted.withValues(alpha: 0.4),
                                    size: 20,
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryChip(String catKey, String label) {
    final isSelected = _selectedCategory == catKey;
    return InkWell(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() {
          _selectedCategory = catKey;
        });
      },
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? widget.accentColor.withValues(alpha: 0.2)
              : AppColors.darkSurfaceVariant,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? widget.accentColor : AppColors.cardBorder,
            width: isSelected ? 1.2 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? widget.accentColor : AppColors.textSecondary,
            fontSize: 11.5,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
