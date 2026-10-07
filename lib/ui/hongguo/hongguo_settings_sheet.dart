import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/model/voice_model.dart';
import '../../data/repository/settings_repository.dart';
import '../theme/app_theme.dart';
import '../tts/voice_selector_sheet.dart';

class HongguoSettingsSheet extends StatefulWidget {
  const HongguoSettingsSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => const HongguoSettingsSheet(),
    );
  }

  @override
  State<HongguoSettingsSheet> createState() => _HongguoSettingsSheetState();
}

class _HongguoSettingsSheetState extends State<HongguoSettingsSheet> {
  SettingsRepository? _settings;
  late TextEditingController _promptController;

  String _translationMode = 'api_online';
  String _videoResolverEngine = 'local';
  VoiceItem _selectedVoice = VoicePresets.defaultVoice;
  bool _autoPlay = true;
  int _prefetchCount = 1;
  bool _autoDeleteWatched = true;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _promptController = TextEditingController();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final s = await SettingsRepository.getInstance();
    if (!mounted) return;
    setState(() {
      _settings = s;
      _translationMode = s.hongguoTranslationMode;
      _videoResolverEngine = s.hongguoVideoResolverEngine;
      _selectedVoice = VoicePresets.vietnameseVoices.firstWhere(
        (v) => v.voiceType == s.hongguoSelectedTtsVoice,
        orElse: () => VoicePresets.defaultVoice,
      );
      _autoPlay = s.autoPlayNextEpisode;
      _prefetchCount = s.prefetchEpisodeCount;
      _autoDeleteWatched = s.hongguoAutoDeleteWatched;
      _promptController.text = s.hongguoCustomPrompt;
      _isLoading = false;
    });
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _pickVoice() async {
    HapticFeedback.selectionClick();
    final picked = await VoiceSelectorSheet.show(
      context,
      currentVoiceType: _selectedVoice.voiceType,
      accentColor: AppColors.primaryEmerald,
      title: 'Chọn Giọng Đọc Hồng Quả',
    );

    if (picked != null && mounted) {
      setState(() {
        _selectedVoice = picked;
      });
    }
  }

  Future<void> _saveAndClose() async {
    HapticFeedback.lightImpact();
    if (_settings != null) {
      _settings!.hongguoTranslationMode = _translationMode;
      _settings!.hongguoVideoResolverEngine = _videoResolverEngine;
      _settings!.hongguoSelectedTtsVoice = _selectedVoice.voiceType;
      _settings!.autoPlayNextEpisode = _autoPlay;
      _settings!.prefetchEpisodeCount = _prefetchCount;
      _settings!.hongguoAutoDeleteWatched = _autoDeleteWatched;
      _settings!.hongguoCustomPrompt = _promptController.text.trim();
    }
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Đã cập nhật cài đặt phim ngắn Hồng Quả!'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _resetPromptToDefault() {
    HapticFeedback.selectionClick();
    setState(() {
      _promptController.text = SettingsRepository.defaultHongguoPrompt;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        padding: const EdgeInsets.all(32),
        decoration: const BoxDecoration(
          color: AppColors.darkSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: const Center(
          child: CircularProgressIndicator(color: AppColors.primaryEmerald),
        ),
      );
    }

    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + bottomPadding),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.90,
      ),
      decoration: const BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Thanh kéo Drag handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.cardBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),

            // Tiêu đề
            Row(
              children: [
                const Icon(
                  Icons.tune_rounded,
                  color: AppColors.primaryEmerald,
                  size: 22,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Cài Đặt Dịch & Xem Phim Hồng Quả',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    color: AppColors.textSecondary,
                    size: 20,
                  ),
                  onPressed: () => Navigator.pop(context),
                  tooltip: 'Đóng',
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Nội dung cuộn
            Flexible(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'NGUỒN GIẢI MÃ VIDEO:',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Chạy duy nhất engine đã chọn để kiểm tra độc lập tốc độ & lỗi (Fallback: ĐÃ TẮT).',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: AppColors.darkSurfaceVariant,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _videoResolverEngine == 'local'
                              ? AppColors.primaryEmerald
                              : Colors.orange,
                        ),
                      ),
                      child: SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        secondary: Icon(
                          _videoResolverEngine == 'local'
                              ? Icons.phone_android_rounded
                              : Icons.cloud_rounded,
                          color: _videoResolverEngine == 'local'
                              ? AppColors.primaryEmerald
                              : Colors.orange,
                        ),
                        title: Text(
                          _videoResolverEngine == 'local'
                              ? 'Local trên điện thoại'
                              : 'Hugging Face Space',
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        subtitle: Text(
                          _videoResolverEngine == 'local'
                              ? 'Tự ký request, tải và giải mã CENC ngay trên máy.'
                              : 'Gửi Video ID đến server Hugging Face để xử lý.',
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 11,
                          ),
                        ),
                        value: _videoResolverEngine == 'hf',
                        activeThumbColor: Colors.orange,
                        onChanged: (useHf) {
                          HapticFeedback.selectionClick();
                          setState(() {
                            _videoResolverEngine = useHf ? 'hf' : 'local';
                          });
                        },
                      ),
                    ),
                    const SizedBox(height: 18),

                    // ===== 1. CHỌN CHẾ ĐỘ DỊCH =====
                    const Text(
                      'CHẾ ĐỘ DỊCH PHIM (HỒNG QUẢ):',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Cấu hình độc lập cho phim ngắn Trung ➔ Việt, không phụ thuộc vào trang chủ.',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Lựa chọn chế độ dịch: 1 hàng 2 ô
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: _buildModeOption(
                              mode: 'capcut',
                              title: 'CapCut Free',
                              badge: 'MIỄN PHÍ',
                              badgeColor: Colors.amber,
                              icon: Icons.bolt_rounded,
                              iconColor: Colors.amber,
                              description: 'Không cần API Key\nBóc tách âm & dịch nhanh',
                              isSelected: _translationMode == 'capcut',
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() => _translationMode = 'capcut');
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildModeOption(
                              mode: 'api_online',
                              title: 'API Online',
                              badge: 'XOAY KEY',
                              badgeColor: AppColors.primaryEmerald,
                              icon: Icons.auto_awesome_rounded,
                              iconColor: AppColors.primaryEmerald,
                              description: 'Dịch AI ngữ cảnh\nChuẩn văn phong phim',
                              isSelected: _translationMode == 'api_online',
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() => _translationMode = 'api_online');
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ===== 2. PROMPT NGỮ CẢNH DỊCH (KHI DÙNG API ONLINE) =====
                    if (_translationMode == 'api_online') ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'PROMPT NGỮ CẢNH DỊCH (ZH ➔ VI):',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                            ),
                            icon: const Icon(
                              Icons.refresh_rounded,
                              size: 14,
                              color: AppColors.primaryEmerald,
                            ),
                            label: const Text(
                              'Khôi phục mặc định',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppColors.primaryEmerald,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            onPressed: _resetPromptToDefault,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Prompt chuyên sâu cho phim ngắn Trung Quốc (tổng tài, ngôn tình, xuyên không, đô thị...).',
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 8),

                      Container(
                        decoration: BoxDecoration(
                          color: AppColors.darkSurfaceVariant,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.cardBorder),
                        ),
                        child: TextField(
                          controller: _promptController,
                          maxLines: 4,
                          minLines: 2,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textPrimary,
                            height: 1.4,
                          ),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.all(12),
                            hintText: 'Nhập prompt ngữ cảnh dịch...',
                            hintStyle: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // ===== 3. CHỌN GIỌNG LỒNG TIẾNG AI =====
                    const Text(
                      'GIỌNG LỒNG TIẾNG AI (HỒNG QUẢ):',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Giọng đọc AI tự động lồng tiếng cho các tập phim ngắn Hồng Quả.',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 8),

                    InkWell(
                      onTap: _pickVoice,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.darkSurfaceVariant,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppColors.primaryEmerald.withValues(
                              alpha: 0.3,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: AppColors.primaryEmerald.withValues(
                                  alpha: 0.15,
                                ),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.record_voice_over_rounded,
                                color: AppColors.primaryEmerald,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          _selectedVoice.displayName,
                                          style: const TextStyle(
                                            color: AppColors.textPrimary,
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 1,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppColors.primaryEmerald
                                              .withValues(alpha: 0.2),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: const Text(
                                          'Đang dùng',
                                          style: TextStyle(
                                            color: AppColors.primaryEmerald,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    _selectedVoice.description.isNotEmpty
                                        ? _selectedVoice.description
                                        : 'Giọng đọc CapCut tự nhiên',
                                    style: const TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 11,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.primaryEmerald.withValues(
                                  alpha: 0.15,
                                ),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: AppColors.primaryEmerald.withValues(
                                    alpha: 0.4,
                                  ),
                                ),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Đổi giọng',
                                    style: TextStyle(
                                      color: AppColors.primaryEmerald,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  SizedBox(width: 2),
                                  Icon(
                                    Icons.chevron_right_rounded,
                                    size: 16,
                                    color: AppColors.primaryEmerald,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ===== 4. CÀI ĐẶT PHÁT, CHUYỂN TẬP & BỘ NHỚ =====
                    const Text(
                      'PHÁT PHIM & BỘ NHỚ:',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 8),

                    Container(
                      decoration: BoxDecoration(
                        color: AppColors.darkSurfaceVariant,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppColors.cardBorder),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 1. Tự động chuyển tập & dịch ngầm
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                            child: Row(
                              children: [
                                const Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Tự động chuyển tập & dịch trước',
                                        style: TextStyle(
                                          color: AppColors.textPrimary,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                        ),
                                      ),
                                      SizedBox(height: 2),
                                      Text(
                                        'Tự phát tiếp và dịch ngầm các tập kế tiếp',
                                        style: TextStyle(
                                          color: AppColors.textMuted,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Switch(
                                  value: _autoPlay,
                                  activeThumbColor: AppColors.primaryEmerald,
                                  onChanged: (val) {
                                    setState(() => _autoPlay = val);
                                  },
                                ),
                              ],
                            ),
                          ),

                          // Tùy chọn số tập gối đầu (chỉ mở khi _autoPlay = true)
                          if (_autoPlay) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Row(
                                    children: [
                                      Icon(
                                        Icons.auto_mode_rounded,
                                        size: 13,
                                        color: AppColors.primaryEmerald,
                                      ),
                                      SizedBox(width: 4),
                                      Text(
                                        'Số tập dịch sẵn trong nền:',
                                        style: TextStyle(
                                          color: AppColors.textSecondary,
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    children: [
                                      _buildCompactBufferOption(1, '1 tập'),
                                      const SizedBox(width: 6),
                                      _buildCompactBufferOption(2, '2 tập'),
                                      const SizedBox(width: 6),
                                      _buildCompactBufferOption(3, '3 tập'),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],

                          Divider(
                            height: 1,
                            thickness: 0.8,
                            color: AppColors.cardBorder.withValues(alpha: 0.6),
                          ),

                          // 2. Tự dọn dẹp tập cũ
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            child: Row(
                              children: [
                                const Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Tự xóa tập đã xem',
                                        style: TextStyle(
                                          color: AppColors.textPrimary,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                        ),
                                      ),
                                      SizedBox(height: 2),
                                      Text(
                                        'Dọn video cách 3 tập để tránh đầy bộ nhớ máy',
                                        style: TextStyle(
                                          color: AppColors.textMuted,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Switch(
                                  value: _autoDeleteWatched,
                                  activeThumbColor: AppColors.primaryEmerald,
                                  onChanged: (val) {
                                    setState(() => _autoDeleteWatched = val);
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),

            // Nút Lưu Cài Đặt
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryEmerald,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  elevation: 0,
                ),
                icon: const Icon(Icons.check_circle_rounded, size: 18),
                label: const Text(
                  'Lưu Cài Đặt',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                onPressed: _saveAndClose,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeOption({
    required String mode,
    required String title,
    required String badge,
    required Color badgeColor,
    required IconData icon,
    required Color iconColor,
    required String description,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primaryEmerald.withValues(alpha: 0.12)
              : AppColors.darkSurfaceVariant,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppColors.primaryEmerald : AppColors.cardBorder,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: iconColor, size: 18),
                ),
                Icon(
                  isSelected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  size: 18,
                  color: isSelected
                      ? AppColors.primaryEmerald
                      : AppColors.textMuted,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isSelected
                          ? AppColors.primaryEmerald
                          : AppColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: badgeColor.withValues(alpha: 0.4),
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    badge,
                    style: TextStyle(
                      color: badgeColor,
                      fontSize: 8.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 10.5,
                height: 1.25,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactBufferOption(int count, String label) {
    final isSelected = _prefetchCount == count;
    return Expanded(
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() => _prefetchCount = count);
        },
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.primaryEmerald.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected
                  ? AppColors.primaryEmerald
                  : AppColors.cardBorder,
              width: isSelected ? 1.4 : 1,
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isSelected
                  ? AppColors.primaryEmerald
                  : AppColors.textPrimary,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}
