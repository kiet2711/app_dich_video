import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/repository/settings_repository.dart';
import '../theme/app_theme.dart';

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
  bool _autoPlay = true;
  int _prefetchCount = 1;
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
      _autoPlay = s.autoPlayNextEpisode;
      _prefetchCount = s.prefetchEpisodeCount;
      _promptController.text = s.hongguoCustomPrompt;
      _isLoading = false;
    });
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _saveAndClose() async {
    HapticFeedback.lightImpact();
    if (_settings != null) {
      _settings!.hongguoTranslationMode = _translationMode;
      _settings!.autoPlayNextEpisode = _autoPlay;
      _settings!.prefetchEpisodeCount = _prefetchCount;
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
                  icon: const Icon(Icons.close_rounded,
                      color: AppColors.textSecondary, size: 20),
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
                      style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                    ),
                    const SizedBox(height: 10),

                    // Lựa chọn 1: CapCut Free
                    _buildModeOption(
                      mode: 'capcut',
                      title: 'CapCut Free',
                      badge: 'MIỄN PHÍ',
                      badgeColor: Colors.amber,
                      icon: Icons.bolt_rounded,
                      iconColor: Colors.amber,
                      description:
                          'Nhận diện âm thanh & dịch trực tiếp miễn phí qua CapCut. Không cần API Key, xử lý nhanh chóng.',
                      isSelected: _translationMode == 'capcut',
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _translationMode = 'capcut');
                      },
                    ),
                    const SizedBox(height: 10),

                    // Lựa chọn 2: API Online
                    _buildModeOption(
                      mode: 'api_online',
                      title: 'API Online',
                      badge: 'XOAY KEY TỰ ĐỘNG',
                      badgeColor: AppColors.primaryEmerald,
                      icon: Icons.auto_awesome_rounded,
                      iconColor: AppColors.primaryEmerald,
                      description:
                          'Dịch AI ngữ cảnh thông minh, tự động xoay Model & Key, câu từ mượt mà chuẩn văn phong phim.',
                      isSelected: _translationMode == 'api_online',
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _translationMode = 'api_online');
                      },
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
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                            ),
                            icon: const Icon(Icons.refresh_rounded,
                                size: 14, color: AppColors.primaryEmerald),
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
                        style: TextStyle(color: AppColors.textMuted, fontSize: 11),
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

                    // ===== 3. TỰ ĐỘNG CHUYỂN TẬP & DỊCH NGẦM =====
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.darkSurfaceVariant,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.cardBorder),
                      ),
                      child: SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        activeThumbColor: AppColors.primaryEmerald,
                        title: const Text(
                          'Tự động chuyển tập & dịch ngầm',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        subtitle: const Text(
                          'Tự chuyển tập kế tiếp khi hết video và gối đầu dịch ngầm trước',
                          style: TextStyle(
                              color: AppColors.textMuted, fontSize: 11),
                        ),
                        value: _autoPlay,
                        onChanged: (val) {
                          setState(() => _autoPlay = val);
                        },
                      ),
                    ),
                    const SizedBox(height: 14),

                    // ===== 4. SỐ TẬP DỊCH NGẦM TRƯỚC (GỐI ĐẦU) =====
                    const Text(
                      'SỐ TẬP DỊCH NGẦM TRƯỚC (GỐI ĐẦU):',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Số tập tiếp theo sẽ được tự động dịch & tạo lồng tiếng sẵn trong nền.',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                    ),
                    const SizedBox(height: 8),

                    Row(
                      children: [
                        _buildBufferOption(
                          count: 1,
                          label: '1 tập',
                          desc: 'Tiết kiệm pin',
                          isSelected: _prefetchCount == 1,
                          onTap: () {
                            setState(() => _prefetchCount = 1);
                          },
                        ),
                        const SizedBox(width: 8),
                        _buildBufferOption(
                          count: 2,
                          label: '2 tập',
                          desc: 'Khuyên dùng',
                          isSelected: _prefetchCount == 2,
                          onTap: () {
                            setState(() => _prefetchCount = 2);
                          },
                        ),
                        const SizedBox(width: 8),
                        _buildBufferOption(
                          count: 3,
                          label: '3 tập',
                          desc: 'Xem liên tục',
                          isSelected: _prefetchCount == 3,
                          onTap: () {
                            setState(() => _prefetchCount = 3);
                          },
                        ),
                      ],
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
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primaryEmerald.withValues(alpha: 0.12)
              : AppColors.darkSurfaceVariant,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? AppColors.primaryEmerald
                : AppColors.cardBorder,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 2),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: isSelected
                              ? AppColors.primaryEmerald
                              : AppColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
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
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        isSelected
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_off_rounded,
                        size: 20,
                        color: isSelected
                            ? AppColors.primaryEmerald
                            : AppColors.textMuted,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBufferOption({
    required int count,
    required String label,
    required String desc,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.primaryEmerald.withValues(alpha: 0.15)
                : AppColors.darkSurfaceVariant,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected
                  ? AppColors.primaryEmerald
                  : AppColors.cardBorder,
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: Column(
            children: [
              Text(
                label,
                style: TextStyle(
                  color: isSelected
                      ? AppColors.primaryEmerald
                      : AppColors.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                desc,
                style: TextStyle(
                  color: isSelected
                      ? AppColors.primaryEmerald
                      : AppColors.textMuted,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
