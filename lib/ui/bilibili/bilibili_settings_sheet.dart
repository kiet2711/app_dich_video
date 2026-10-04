import 'package:flutter/material.dart';

import '../../data/repository/settings_repository.dart';
import '../../domain/media/bilibili_resolver.dart';
import '../theme/app_theme.dart';
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

  @override
  Widget build(BuildContext context) {
    final settings = _settings;

    return Container(
      padding: const EdgeInsets.only(bottom: 24),
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
                margin: const EdgeInsets.only(top: 12, bottom: 12),
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
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
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // Account Profile Box
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _buildAccountBox(),
            ),

            const SizedBox(height: 16),

            // Settings List
            if (settings != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
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
                          style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
                        ),
                        subtitle: Text(
                          _getQualityLabel(settings.bilibiliPreferredQuality),
                          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                        ),
                        trailing: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: settings.bilibiliPreferredQuality,
                            dropdownColor: AppTheme.darkSurfaceVariant,
                            icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                            items: const [
                              DropdownMenuItem(value: '1080', child: Text('1080p FHD', style: TextStyle(color: Colors.white, fontSize: 13))),
                              DropdownMenuItem(value: '720', child: Text('720p HD', style: TextStyle(color: Colors.white, fontSize: 13))),
                              DropdownMenuItem(value: '480', child: Text('480p SD', style: TextStyle(color: Colors.white, fontSize: 13))),
                              DropdownMenuItem(value: '360', child: Text('360p Tiết kiệm', style: TextStyle(color: Colors.white, fontSize: 13))),
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
                    ],
                  ),
                ),
              ),
            ],
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
