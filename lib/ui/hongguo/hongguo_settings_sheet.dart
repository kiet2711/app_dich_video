import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/model/voice_model.dart';
import '../../data/repository/settings_repository.dart';
import '../../domain/media/hongguo/hongguo_codec_capabilities.dart';
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
  int _prefetchCount = 2;
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
    final accent = AppThemePalette.of(context).accentFor(AppTabId.hongguo);
    final picked = await VoiceSelectorSheet.show(
      context,
      currentVoiceType: _selectedVoice.voiceType,
      accentColor: accent,
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
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.hongguo);
    final secondary = palette.secondaryFor(AppTabId.hongguo);
    final onAccent = palette.onColor(accent);

    if (_isLoading) {
      return Container(
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Center(
          child: CircularProgressIndicator(color: accent),
        ),
      );
    }

    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + bottomPadding),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.90,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: palette.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),

            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.settings_rounded,
                    color: accent,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Cài Đặt Dịch & Xem Phim Hồng Quả',
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.close_rounded,
                    color: palette.textSecondary,
                    size: 20,
                  ),
                  onPressed: () => Navigator.pop(context),
                  tooltip: 'Đóng',
                ),
              ],
            ),
            const SizedBox(height: 8),

            Flexible(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'NGUỒN GIẢI MÃ VIDEO:',
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Tự động kết hợp nguồn web, chữ ký thiết bị tạm và fallback giữa Local & Cloud.',
                      style: TextStyle(
                        color: palette.textMuted,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: palette.surfaceAlt,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: _videoResolverEngine == 'local'
                              ? accent
                              : secondary,
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
                              ? accent
                              : secondary,
                        ),
                        title: Text(
                          _videoResolverEngine == 'local'
                              ? 'Local trên điện thoại'
                              : 'Hugging Face Space',
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        subtitle: Text(
                          _videoResolverEngine == 'local'
                              ? 'Tự ký request ByteDance, tải và giải mã CENC ngay trên máy.'
                              : 'Gửi Video ID đến server Hugging Face để xử lý.',
                          style: TextStyle(
                            color: palette.textMuted,
                            fontSize: 11,
                          ),
                        ),
                        value: _videoResolverEngine == 'hf',
                        activeThumbColor: secondary,
                        onChanged: (useHf) {
                          HapticFeedback.selectionClick();
                          setState(() {
                            _videoResolverEngine = useHf ? 'hf' : 'local';
                          });
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(foregroundColor: accent),
                        onPressed: () async {
                          await HongguoCodecCapabilities.instance.lessons
                              .clearAll();
                          if (!mounted) return;
                          ScaffoldMessenger.of(this.context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Đã xoá ghi nhớ tránh lỗi giải mã thiết bị',
                              ),
                            ),
                          );
                          setState(() {});
                        },
                        icon: const Icon(Icons.cleaning_services_outlined, size: 16),
                        label: Text(
                          'Xoá lịch sử hạ cấp codec (${HongguoCodecCapabilities.instance.lessons.count})',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ===== 1. CHỌN CHẾ ĐỘ DỊCH =====
                    Text(
                      'CHẾ ĐỘ DỊCH PHIM (HỒNG QUẢ):',
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Cấu hình độc lập cho phim ngắn Trung ➔ Việt, không phụ thuộc vào trang chủ.',
                      style: TextStyle(
                        color: palette.textMuted,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 10),

                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: _buildModeOption(
                              palette: palette,
                              accent: accent,
                              mode: 'capcut',
                              title: 'CapCut Free',
                              badge: 'MIỄN PHÍ',
                              badgeColor: const Color(0xFFD97706),
                              icon: Icons.bolt_rounded,
                              iconColor: const Color(0xFFD97706),
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
                              palette: palette,
                              accent: accent,
                              mode: 'api_online',
                              title: 'API Online',
                              badge: 'XOAY KEY',
                              badgeColor: accent,
                              icon: Icons.auto_awesome_rounded,
                              iconColor: accent,
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

                    if (_translationMode == 'api_online') ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'PROMPT NGỮ CẢNH DỊCH (ZH ➔ VI):',
                            style: TextStyle(
                              color: palette.textSecondary,
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
                            icon: Icon(
                              Icons.refresh_rounded,
                              size: 14,
                              color: accent,
                            ),
                            label: Text(
                              'Khôi phục mặc định',
                              style: TextStyle(
                                fontSize: 11,
                                color: accent,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            onPressed: _resetPromptToDefault,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Prompt chuyên sâu cho phim ngắn Trung Quốc (tổng tài, ngôn tình, xuyên không, đô thị...).',
                        style: TextStyle(
                          color: palette.textMuted,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 8),

                      Container(
                        decoration: BoxDecoration(
                          color: palette.surfaceAlt,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: palette.border),
                        ),
                        child: TextField(
                          controller: _promptController,
                          maxLines: 4,
                          minLines: 2,
                          style: TextStyle(
                            fontSize: 12,
                            color: palette.textPrimary,
                            height: 1.4,
                          ),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.all(12),
                            hintText: 'Nhập prompt ngữ cảnh dịch...',
                            hintStyle: TextStyle(
                              color: palette.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    Text(
                      'GIỌNG LỒNG TIẾNG AI (HỒNG QUẢ):',
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Giọng đọc AI tự động lồng tiếng cho các tập phim ngắn Hồng Quả.',
                      style: TextStyle(
                        color: palette.textMuted,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 8),

                    InkWell(
                      onTap: _pickVoice,
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: palette.surfaceAlt,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: accent.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.14),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.record_voice_over_rounded,
                                color: accent,
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
                                          style: TextStyle(
                                            color: palette.textPrimary,
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
                                          color: accent.withValues(alpha: 0.16),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          'Đang dùng',
                                          style: TextStyle(
                                            color: accent,
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
                                    style: TextStyle(
                                      color: palette.textSecondary,
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
                                color: accent.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: accent.withValues(alpha: 0.4),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Đổi giọng',
                                    style: TextStyle(
                                      color: accent,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  Icon(
                                    Icons.chevron_right_rounded,
                                    size: 16,
                                    color: accent,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    Text(
                      'PHÁT PHIM & BỘ NHỚ:',
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 8),

                    Container(
                      decoration: BoxDecoration(
                        color: palette.surfaceAlt,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: palette.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Tự động chuyển tập & dịch trước',
                                        style: TextStyle(
                                          color: palette.textPrimary,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Tự phát tiếp và dịch ngầm các tập kế tiếp',
                                        style: TextStyle(
                                          color: palette.textMuted,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Switch(
                                  value: _autoPlay,
                                  activeThumbColor: accent,
                                  onChanged: (val) {
                                    setState(() => _autoPlay = val);
                                  },
                                ),
                              ],
                            ),
                          ),

                          if (_autoPlay) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.auto_mode_rounded,
                                        size: 13,
                                        color: accent,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        'Số tập dịch sẵn trong nền:',
                                        style: TextStyle(
                                          color: palette.textSecondary,
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    children: [
                                      _buildCompactBufferOption(
                                          palette, accent, 1, '1 tập'),
                                      const SizedBox(width: 6),
                                      _buildCompactBufferOption(
                                          palette, accent, 2, '2 tập'),
                                      const SizedBox(width: 6),
                                      _buildCompactBufferOption(
                                          palette, accent, 3, '3 tập'),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],

                          Divider(
                            height: 1,
                            thickness: 0.8,
                            color: palette.border,
                          ),

                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Tự xóa tập đã xem',
                                        style: TextStyle(
                                          color: palette.textPrimary,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Dọn sạch video, phụ đề & lồng tiếng cách 3 tập',
                                        style: TextStyle(
                                          color: palette.textMuted,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Switch(
                                  value: _autoDeleteWatched,
                                  activeThumbColor: accent,
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

            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: onAccent,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
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
    required AppThemePalette palette,
    required Color accent,
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
              ? accent.withValues(alpha: 0.12)
              : palette.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? accent : palette.border,
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
                  color: isSelected ? accent : palette.textMuted,
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
                      color: isSelected ? accent : palette.textPrimary,
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
                    color: badgeColor.withValues(alpha: 0.14),
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
              style: TextStyle(
                color: palette.textSecondary,
                fontSize: 10.5,
                height: 1.25,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactBufferOption(
    AppThemePalette palette,
    Color accent,
    int count,
    String label,
  ) {
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
                ? accent.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected ? accent : palette.border,
              width: isSelected ? 1.4 : 1,
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isSelected ? accent : palette.textPrimary,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}
