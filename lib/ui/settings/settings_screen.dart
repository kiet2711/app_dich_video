import 'package:flutter/material.dart';

import '../../data/repository/settings_repository.dart';
import '../theme/app_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingsRepository? _settings;
  final _apiKeysController = TextEditingController();
  final _customPromptController = TextEditingController();
  final _bilibiliSessDataController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await SettingsRepository.getInstance();
    setState(() {
      _settings = s;
      _apiKeysController.text = s.geminiApiKeys.join('\n');
      _customPromptController.text = s.geminiCustomPrompt;
      _bilibiliSessDataController.text = s.bilibiliSessData;
    });
  }

  void _save() {
    if (_settings == null) return;
    _settings!.geminiApiKeys = _apiKeysController.text
        .split(RegExp(r'[,;\n]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    _settings!.geminiCustomPrompt = _customPromptController.text.trim();
    _settings!.bilibiliSessData = _bilibiliSessDataController.text.trim();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Đã lưu cài đặt thành công!'),
        backgroundColor: AppColors.primaryEmerald,
      ),
    );
  }

  @override
  void dispose() {
    _apiKeysController.dispose();
    _customPromptController.dispose();
    _bilibiliSessDataController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_settings == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        backgroundColor: AppColors.darkBackground,
        title: const Text(
          'Cài đặt hệ thống',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.check, color: AppColors.primaryEmerald),
            onPressed: _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Section 1: Gemini AI
          _buildSectionHeader('Google Gemini AI (Dịch thuật đa luồng)'),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.darkSurface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Danh sách Gemini API Key (mỗi dòng 1 key để xoay vòng):',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _apiKeysController,
                  maxLines: 4,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: const Color(0xFF1E202A),
                    hintText: 'Dán các API Key tại đây...',
                    hintStyle: const TextStyle(color: Colors.white38),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Số luồng dịch song song: ${_settings!.geminiThreadCount}',
                      style: const TextStyle(color: Colors.white),
                    ),
                    Slider(
                      value: _settings!.geminiThreadCount.toDouble(),
                      min: 1,
                      max: 8,
                      divisions: 7,
                      activeColor: AppColors.primaryEmerald,
                      onChanged: (val) {
                        setState(() {
                          _settings!.geminiThreadCount = val.toInt();
                        });
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Section 2: Hộp Đen (BlackBox) & Subtitle Player
          _buildSectionHeader('Cấu hình Hộp Đen (BlackBox) & Trình Phát'),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.darkSurface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Bật Hộp Đen che phụ đề cứng',
                    style: TextStyle(color: Colors.white),
                  ),
                  value: _settings!.isBlackBoxEnabled,
                  activeThumbColor: AppColors.primaryEmerald,
                  onChanged: (val) {
                    setState(() {
                      _settings!.isBlackBoxEnabled = val;
                    });
                  },
                ),
                const Divider(color: AppColors.cardBorder),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Độ mờ: ${(_settings!.blackBoxOpacity * 100).toInt()}%',
                      style: const TextStyle(color: Colors.white),
                    ),
                    Slider(
                      value: _settings!.blackBoxOpacity,
                      min: 0.3,
                      max: 1.0,
                      activeColor: AppColors.primaryEmerald,
                      onChanged: (val) {
                        setState(() {
                          _settings!.blackBoxOpacity = val;
                        });
                      },
                    ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Cỡ chữ: ${_settings!.subtitleFontSize.toInt()} pt',
                      style: const TextStyle(color: Colors.white),
                    ),
                    Slider(
                      value: _settings!.subtitleFontSize,
                      min: 14.0,
                      max: 36.0,
                      activeColor: AppColors.primaryEmerald,
                      onChanged: (val) {
                        setState(() {
                          _settings!.subtitleFontSize = val;
                        });
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Section 3: Tải video & Bilibili VIP
          _buildSectionHeader('TẢI VIDEO ONLINE & BILIBILI VIP'),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.darkSurface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'SỐ LUỒNG TẢI SONG SONG:',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      '${_settings!.downloadThreadCount} LUỒNG',
                      style: const TextStyle(
                        color: AppColors.primaryEmerald,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Tải đa luồng song song luân phiên qua các cụm máy chủ CDN (Tencent, Alibaba, Huawei, Bilibili) giúp tăng tốc độ tải lên gấp 5-10 lần (Khuyên dùng: 12 - 24 luồng).',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Slider(
                  value: _settings!.downloadThreadCount.toDouble(),
                  min: 8.0,
                  max: 32.0,
                  divisions: 24,
                  activeColor: AppColors.primaryEmerald,
                  inactiveColor: const Color(0xFF323444),
                  onChanged: (val) {
                    setState(() {
                      _settings!.downloadThreadCount = val.toInt();
                    });
                  },
                ),
                const Divider(color: AppColors.cardBorder),
                const SizedBox(height: 4),
                const Text(
                  'BILIBILI COOKIE (SESSDATA):',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Nhập mã SESSDATA tài khoản Bilibili để mở khóa xem và tải chất lượng cao 1080P+, 4K và các video giới hạn VIP.',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _bilibiliSessDataController,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: const Color(0xFF1E202A),
                    hintText: 'Nhập mã SESSDATA...',
                    hintStyle: const TextStyle(color: Colors.white38),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryEmerald,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: const Icon(Icons.save),
            onPressed: _save,
            label: const Text(
              'Lưu Cài Đặt',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          color: AppColors.primaryEmerald,
          fontWeight: FontWeight.bold,
          fontSize: 14,
        ),
      ),
    );
  }
}
