import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/model/voice_model.dart';
import '../../data/repository/settings_repository.dart';
import '../../domain/media/bilibili_resolver.dart';
import '../theme/app_theme.dart';
import '../tts/voice_selector_sheet.dart';
import 'bilibili_login_sheet.dart';

class BilibiliSettingsSheet extends StatefulWidget {
  const BilibiliSettingsSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const BilibiliSettingsSheet(),
    );
  }

  @override
  State<BilibiliSettingsSheet> createState() => _BilibiliSettingsSheetState();
}

class _BilibiliSettingsSheetState extends State<BilibiliSettingsSheet> {
  final BilibiliResolver _resolver = BilibiliResolver();
  SettingsRepository? _settings;
  BilibiliUserProfile? _profile;
  bool _isLoadingProfile = true;

  String _translationMode = 'capcut';
  VoiceItem _selectedVoice = VoicePresets.defaultVoice;
  bool _downloadOffline = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final settings = await SettingsRepository.getInstance();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _translationMode = settings.bilibiliTranslationMode;
      _selectedVoice = VoicePresets.vietnameseVoices.firstWhere(
        (v) => v.voiceType == settings.bilibiliSelectedTtsVoice,
        orElse: () => VoicePresets.defaultVoice,
      );
      _downloadOffline = settings.downloadBilibiliVideo;
    });

    final sess = settings.bilibiliSessData;
    if (sess.isNotEmpty) {
      final profile = await _resolver.getUserProfile(sess);
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _isLoadingProfile = false;
      });
    } else {
      if (!mounted) return;
      setState(() {
        _profile = null;
        _isLoadingProfile = false;
      });
    }
  }

  Future<void> _openLogin() async {
    final result = await BilibiliLoginSheet.show(context);
    if (result == true) {
      _loadData();
    }
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.darkSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.cardBorder),
        ),
        title: const Text('Đăng xuất Bilibili?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Sau khi đăng xuất, bạn sẽ không thể xem chất lượng 1080p hoặc video Hội Viên.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Hủy', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Đăng xuất', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      _settings?.bilibiliSessData = '';
      if (!mounted) return;
      setState(() {
        _profile = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã đăng xuất tài khoản Bilibili')),
      );
    }
  }

  Future<void> _pickVoice() async {
    HapticFeedback.selectionClick();
    final picked = await VoiceSelectorSheet.show(
      context,
      currentVoiceType: _selectedVoice.voiceType,
      accentColor: const Color(0xFF00AEEC),
      title: 'Chọn Giọng Đọc Bilibili',
    );

    if (picked != null && mounted) {
      setState(() {
        _selectedVoice = picked;
      });
      _settings?.bilibiliSelectedTtsVoice = picked.voiceType;
    }
  }

  Future<void> _saveAndClose() async {
    HapticFeedback.lightImpact();
    if (_settings != null) {
      _settings!.bilibiliTranslationMode = _translationMode;
      _settings!.bilibiliSelectedTtsVoice = _selectedVoice.voiceType;
      _settings!.downloadBilibiliVideo = _downloadOffline;
    }
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Đã cập nhật cài đặt Bilibili thành công!'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.90,
      ),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + bottomPadding),
      decoration: const BoxDecoration(
        color: AppTheme.darkSurface,
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
                margin: const EdgeInsets.only(bottom: 12),
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00AEEC).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.tune_rounded, color: Color(0xFF00AEEC), size: 20),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Cài đặt Bilibili',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white70),
                  tooltip: 'Đóng',
                ),
              ],
            ),

            const SizedBox(height: 10),

            // Scrollable Settings Content
            Flexible(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Account Profile Box
                    _buildAccountBox(),

                    const SizedBox(height: 18),

                    // ===== 1. CHỌN CHẾ ĐỘ DỊCH (CAPCUT VS AI) =====
                    const Text(
                      'CHẾ ĐỘ DỊCH PHỤ ĐỀ (BILIBILI):',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Tùy chọn phương thức bóc tách & dịch thuật khi xem video Bilibili.',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
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
                              title: 'AI Online',
                              badge: 'GEMINI/GROQ',
                              badgeColor: const Color(0xFF00AEEC),
                              icon: Icons.auto_awesome_rounded,
                              iconColor: const Color(0xFF00AEEC),
                              description: 'Dịch AI ngữ cảnh\nChuẩn xác & mượt mà',
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

                    const SizedBox(height: 18),

                    // ===== 2. CHỌN GIỌNG LỒNG TIẾNG AI =====
                    const Text(
                      'GIỌNG LỒNG TIẾNG AI (BILIBILI):',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Giọng đọc AI tự động phát khi bật chế độ "Lồng tiếng AI" cho video.',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                    ),
                    const SizedBox(height: 8),

                    InkWell(
                      onTap: _pickVoice,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.darkSurfaceVariant,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: const Color(0xFF00AEEC).withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00AEEC).withValues(alpha: 0.15),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.record_voice_over_rounded,
                                color: Color(0xFF00AEEC),
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
                                            color: AppTheme.textPrimary,
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
                                            horizontal: 6, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF00AEEC).withValues(alpha: 0.2),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Text(
                                          'Đang dùng',
                                          style: TextStyle(
                                            color: Color(0xFF00AEEC),
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
                                        : 'Giọng đọc chuẩn tiếng Việt',
                                    style: const TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 11,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00AEEC).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFF00AEEC).withValues(alpha: 0.4),
                                ),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Đổi giọng',
                                    style: TextStyle(
                                      color: Color(0xFF00AEEC),
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  SizedBox(width: 2),
                                  Icon(Icons.chevron_right_rounded,
                                      size: 16, color: Color(0xFF00AEEC)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 18),

                    // ===== 3. CÀI ĐẶT PHÁT VIDEO & TẢI VỀ =====
                    const Text(
                      'TÙY CHỌN PHÁT & TẢI VIDEO:',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 8),

                    if (settings != null)
                      Container(
                        decoration: BoxDecoration(
                          color: AppTheme.darkSurfaceVariant,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppTheme.cardBorder),
                        ),
                        child: Column(
                          children: [
                            // Video Quality Option
                            ListTile(
                              leading: const Icon(Icons.high_quality_rounded, color: Color(0xFF00AEEC)),
                              title: const Text(
                                'Độ phân giải ưu tiên',
                                style: TextStyle(color: AppTheme.textPrimary, fontSize: 13.5),
                              ),
                              subtitle: Text(
                                _getQualityLabel(settings.bilibiliPreferredQuality),
                                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11.5),
                              ),
                              trailing: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: settings.bilibiliPreferredQuality,
                                  dropdownColor: AppTheme.darkSurfaceVariant,
                                  icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                                  items: const [
                                    DropdownMenuItem(value: '1080', child: Text('1080p FHD', style: TextStyle(color: Colors.white, fontSize: 12.5))),
                                    DropdownMenuItem(value: '720', child: Text('720p HD', style: TextStyle(color: Colors.white, fontSize: 12.5))),
                                    DropdownMenuItem(value: '480', child: Text('480p SD', style: TextStyle(color: Colors.white, fontSize: 12.5))),
                                    DropdownMenuItem(value: '360', child: Text('360p Tiết kiệm', style: TextStyle(color: Colors.white, fontSize: 12.5))),
                                  ],
                                  onChanged: (val) {
                                    if (val != null) {
                                      setState(() {
                                        settings.bilibiliPreferredQuality = val;
                                      });
                                    }
                                  },
                                ),
                              ),
                            ),
                            const Divider(color: AppTheme.cardBorder, height: 1),
                            // Download offline toggle
                            SwitchListTile(
                              dense: true,
                              activeThumbColor: const Color(0xFF00AEEC),
                              secondary: const Icon(Icons.download_rounded, color: Color(0xFF00AEEC)),
                              title: const Text(
                                'Tự động tải video về máy',
                                style: TextStyle(color: AppTheme.textPrimary, fontSize: 13.5),
                              ),
                              subtitle: const Text(
                                'Tải trước MP4 để phát offline 100% mượt mà không giật lag',
                                style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                              ),
                              value: _downloadOffline,
                              onChanged: (val) {
                                setState(() => _downloadOffline = val);
                              },
                            ),
                          ],
                        ),
                      ),

                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 10),

            // Nút Lưu Cài Đặt
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00AEEC),
                  foregroundColor: Colors.white,
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
    const activeColor = Color(0xFF00AEEC);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? activeColor.withValues(alpha: 0.12)
              : AppTheme.darkSurfaceVariant,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? activeColor : AppTheme.cardBorder,
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
                  color: isSelected ? activeColor : AppTheme.textMuted,
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
                      color: isSelected ? activeColor : AppTheme.textPrimary,
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
                color: AppTheme.textSecondary,
                fontSize: 10.5,
                height: 1.25,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountBox() {
    if (_isLoadingProfile) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.darkSurfaceVariant,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: const Center(
          child: CircularProgressIndicator(color: Color(0xFF00AEEC)),
        ),
      );
    }

    final profile = _profile;
    final isLoggedIn = profile != null && profile.isLogin;

    if (isLoggedIn) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              const Color(0xFF00AEEC).withValues(alpha: 0.15),
              AppTheme.darkSurfaceVariant,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: profile.isVip ? const Color(0xFFFFD700) : const Color(0xFF00AEEC).withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          children: [
            // Avatar
            CircleAvatar(
              radius: 26,
              backgroundColor: Colors.white12,
              backgroundImage: profile.avatar.isNotEmpty ? NetworkImage(profile.avatar) : null,
              child: profile.avatar.isEmpty
                  ? const Icon(Icons.person, color: Colors.white54)
                  : null,
            ),
            const SizedBox(width: 14),
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          profile.uname,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (profile.level > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.blueAccent,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'Lv.${profile.level}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (profile.isVip)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFD700).withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFFFD700), width: 0.8),
                      ),
                      child: Text(
                        profile.vipLabel.isNotEmpty ? profile.vipLabel : 'VIP Bilibili',
                        style: const TextStyle(
                          color: Color(0xFFFFD700),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  else
                    const Text(
                      'Tài khoản chuẩn (Đã đăng nhập)',
                      style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                    ),
                ],
              ),
            ),
            // Logout button
            IconButton(
              icon: const Icon(Icons.logout_rounded, color: Colors.redAccent, size: 20),
              tooltip: 'Đăng xuất',
              onPressed: _logout,
            ),
          ],
        ),
      );
    }

    // Not logged in view
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.darkSurfaceVariant,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.lock_outline_rounded, color: Colors.orangeAccent, size: 20),
              SizedBox(width: 8),
              Text(
                'Chưa đăng nhập Bilibili',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Đăng nhập giúp mở khóa chất lượng video 1080p, 4K và xem phim Hội Viên.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _openLogin,
              icon: const Icon(Icons.login_rounded, size: 18),
              label: const Text('Đăng nhập ngay'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00AEEC),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _getQualityLabel(String quality) {
    switch (quality) {
      case '1080':
        return 'Full HD (1080p) - Yêu cầu đăng nhập';
      case '720':
        return 'HD (720p)';
      case '480':
        return 'Tiêu chuẩn (480p)';
      case '360':
        return 'Tiết kiệm pin/dữ liệu (360p)';
      default:
        return 'Mặc định (1080p)';
    }
  }
}
