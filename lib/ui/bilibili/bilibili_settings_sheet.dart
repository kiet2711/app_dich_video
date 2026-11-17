import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/model/voice_model.dart';
import '../../data/repository/settings_repository.dart';
import '../../domain/media/bilibili_resolver.dart';
import '../theme/app_theme.dart';
import '../tts/voice_selector_sheet.dart';

class BilibiliSettingsSheet extends StatefulWidget {
  final VoidCallback? onRecreateSubtitles;

  const BilibiliSettingsSheet({super.key, this.onRecreateSubtitles});

  static Future<void> show(
    BuildContext context, {
    VoidCallback? onRecreateSubtitles,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) =>
          BilibiliSettingsSheet(onRecreateSubtitles: onRecreateSubtitles),
    );
  }

  @override
  State<BilibiliSettingsSheet> createState() => _BilibiliSettingsSheetState();
}

class _BilibiliSettingsSheetState extends State<BilibiliSettingsSheet> {
  SettingsRepository? _settings;

  String _translationMode = 'capcut';
  String _subtitleSource = 'bilibili_first';
  String _cdnService = 'auto';
  bool _hardwareDecode = true;
  String _qualityKey = '64';
  VoiceItem _selectedVoice = VoicePresets.defaultVoice;
  bool _downloadOffline = false;
  int _bufferSizeMb = 64;

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
      _subtitleSource = settings.bilibiliSubtitleSource;
      _cdnService = BilibiliCdnService.fromCode(settings.bilibiliCdnService).code;
      _hardwareDecode = settings.bilibiliHardwareDecode;
      _qualityKey = BilibiliResolver.normalizeQualityCode(
        settings.bilibiliPreferredQuality.isNotEmpty
            ? settings.bilibiliPreferredQuality
            : settings.preferredVideoQuality,
      );
      _selectedVoice = VoicePresets.vietnameseVoices.firstWhere(
        (v) => v.voiceType == settings.bilibiliSelectedTtsVoice,
        orElse: () => VoicePresets.defaultVoice,
      );
      _downloadOffline = settings.downloadBilibiliVideo;
      _bufferSizeMb = settings.playerBufferSizeMb;
    });
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

  void _persistSettings() {
    final settings = _settings;
    if (settings == null) return;
    settings.bilibiliTranslationMode = _translationMode;
    settings.bilibiliSubtitleSource = _subtitleSource;
    settings.bilibiliStreamMode = 'dash';
    settings.bilibiliCdnService = _cdnService;
    settings.bilibiliHardwareDecode = _hardwareDecode;
    settings.bilibiliPreferredQuality = _qualityKey;
    settings.preferredVideoQuality = _qualityKey;
    settings.bilibiliSelectedTtsVoice = _selectedVoice.voiceType;
    settings.downloadBilibiliVideo = _downloadOffline;
    settings.playerBufferSizeMb = _bufferSizeMb;
  }

  Future<void> _saveAndClose() async {
    HapticFeedback.lightImpact();
    _persistSettings();
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
                  child: const Icon(Icons.settings_rounded, color: Color(0xFF00AEEC), size: 20),
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

                    // ===== 2. CÁCH LẤY FILE PHỤ ĐỀ (SRT) =====
                    const Text(
                      'CÁCH LẤY FILE PHỤ ĐỀ (SRT):',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Tùy chọn ưu tiên lấy phụ đề Bilibili có sẵn hoặc nhảy qua CapCut nhận diện trực tiếp.',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                    ),
                    const SizedBox(height: 10),

                    // Lựa chọn cách lấy file SRT: 1 hàng 2 ô
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: _buildModeOption(
                              mode: 'bilibili_first',
                              title: 'Ưu tiên Bilibili',
                              badge: 'MẶC ĐỊNH',
                              badgeColor: const Color(0xFF00AEEC),
                              icon: Icons.subtitles_rounded,
                              iconColor: const Color(0xFF00AEEC),
                              description: 'Lấy phụ đề có sẵn\nKhông có mới qua CapCut',
                              isSelected: _subtitleSource == 'bilibili_first',
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() => _subtitleSource = 'bilibili_first');
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildModeOption(
                              mode: 'capcut_always',
                              title: 'Chuyển sang CapCut',
                              badge: 'BỎ QUA GỐC',
                              badgeColor: Colors.amber,
                              icon: Icons.graphic_eq_rounded,
                              iconColor: Colors.amber,
                              description: 'Bỏ qua phụ đề Bilibili (tránh sai)\nNhận diện thẳng âm thanh qua CapCut',
                              isSelected: _subtitleSource == 'capcut_always',
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() => _subtitleSource = 'capcut_always');
                              },
                            ),
                          ),
                        ],
                      ),
                    ),

                    if (widget.onRecreateSubtitles != null) ...[
                      const SizedBox(height: 10),
                      InkWell(
                        onTap: () async {
                          HapticFeedback.mediumImpact();
                          _persistSettings();
                          Navigator.of(context).pop();
                          widget.onRecreateSubtitles!();
                        },
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.amber.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: Colors.amber.withValues(alpha: 0.4),
                            ),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.refresh_rounded, color: Colors.amber, size: 16),
                              SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  'Tạo lại phụ đề cho video này theo thiết lập mới',
                                  style: TextStyle(
                                    color: Colors.amber,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(height: 18),

                    // ===== 3. CHỌN GIỌNG LỒNG TIẾNG AI =====
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

                    // ===== 4. TỐI ƯU PHÁT VIDEO, CDN & TẢI VỀ =====
                    const Text(
                      'TỐI ƯU PHÁT VIDEO & TẢI VỀ (DASH THỐNG NHẤT):',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Gộp hình & tiếng DASH trực tiếp trong một demuxer giúp tua nhanh, không mất tiếng hoặc đứng hình.',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                    ),
                    const SizedBox(height: 8),

                    if (settings != null)
                      Material(
                        color: AppTheme.darkSurfaceVariant,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: const BorderSide(color: AppTheme.cardBorder),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          children: [
                            // Độ phân giải ưu tiên (chuẩn QN '80'/'64'/'32'/'16')
                            ListTile(
                              leading: const Icon(Icons.high_quality_rounded, color: Color(0xFF00AEEC)),
                              title: const Text(
                                'Độ phân giải ưu tiên',
                                style: TextStyle(color: AppTheme.textPrimary, fontSize: 13.5),
                              ),
                              subtitle: Text(
                                _getQualityLabel(_qualityKey),
                                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11.5),
                              ),
                              trailing: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: _qualityKey,
                                  dropdownColor: AppTheme.darkSurfaceVariant,
                                  icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                                  items: const [
                                    DropdownMenuItem(value: '80', child: Text('1080p FHD', style: TextStyle(color: Colors.white, fontSize: 12.5))),
                                    DropdownMenuItem(value: '64', child: Text('720p HD', style: TextStyle(color: Colors.white, fontSize: 12.5))),
                                    DropdownMenuItem(value: '32', child: Text('480p SD', style: TextStyle(color: Colors.white, fontSize: 12.5))),
                                    DropdownMenuItem(value: '16', child: Text('360p Nhẹ', style: TextStyle(color: Colors.white, fontSize: 12.5))),
                                  ],
                                  onChanged: (val) {
                                    if (val != null) {
                                      HapticFeedback.selectionClick();
                                      setState(() {
                                        _qualityKey = val;
                                      });
                                    }
                                  },
                                ),
                              ),
                            ),
                            const Divider(color: AppTheme.cardBorder, height: 1),
                            // Máy chủ CDN ưu tiên (kiểu PiliPlus, né MCDN chậm)
                            ListTile(
                              leading: const Icon(Icons.dns_rounded, color: Color(0xFF00AEEC)),
                              title: const Text(
                                'Máy chủ CDN phát video',
                                style: TextStyle(color: AppTheme.textPrimary, fontSize: 13.5),
                              ),
                              subtitle: Text(
                                BilibiliCdnService.fromCode(_cdnService).label,
                                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11.5),
                              ),
                              trailing: SizedBox(
                                width: 140,
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<String>(
                                    isExpanded: true,
                                    value: _cdnService,
                                    dropdownColor: AppTheme.darkSurfaceVariant,
                                    icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                                    items: BilibiliCdnService.values
                                        .map(
                                          (cdn) => DropdownMenuItem<String>(
                                            value: cdn.code,
                                            child: Text(
                                              cdn.label,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(color: Colors.white, fontSize: 12),
                                            ),
                                          ),
                                        )
                                        .toList(),
                                    onChanged: (val) {
                                      if (val != null) {
                                        HapticFeedback.selectionClick();
                                        setState(() => _cdnService = val);
                                      }
                                    },
                                  ),
                                ),
                              ),
                            ),
                            const Divider(color: AppTheme.cardBorder, height: 1),
                            // Giải mã phần cứng GPU (tắt nếu gặp lỗi đen màn hình)
                            SwitchListTile(
                              dense: true,
                              activeThumbColor: const Color(0xFF00AEEC),
                              secondary: const Icon(Icons.developer_board_rounded, color: Color(0xFF00AEEC)),
                              title: const Text(
                                'Giải mã phần cứng (Hardware)',
                                style: TextStyle(color: AppTheme.textPrimary, fontSize: 13.5),
                              ),
                              subtitle: const Text(
                                'Tăng tốc GPU giảm giật lag khi tua; tắt nếu máy bị đen hình còn tiếng',
                                style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                              ),
                              value: _hardwareDecode,
                              onChanged: (val) {
                                HapticFeedback.selectionClick();
                                setState(() => _hardwareDecode = val);
                              },
                            ),
                            const Divider(color: AppTheme.cardBorder, height: 1),
                            // Buffer RAM Slider/Dropdown
                            ListTile(
                              leading: const Icon(Icons.memory_rounded, color: Color(0xFF00AEEC)),
                              title: const Text(
                                'Bộ nhớ đệm RAM phát video',
                                style: TextStyle(color: AppTheme.textPrimary, fontSize: 13.5),
                              ),
                              subtitle: Text(
                                _getBufferLabel(_bufferSizeMb),
                                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11.5),
                              ),
                              trailing: DropdownButtonHideUnderline(
                                child: DropdownButton<int>(
                                  value: _bufferSizeMb,
                                  dropdownColor: AppTheme.darkSurfaceVariant,
                                  icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                                  items: const [
                                    DropdownMenuItem(value: 32, child: Text('32 MB (Tiết kiệm)', style: TextStyle(color: Colors.white, fontSize: 12.5))),
                                    DropdownMenuItem(value: 64, child: Text('64 MB (Cân bằng)', style: TextStyle(color: Colors.white, fontSize: 12.5))),
                                    DropdownMenuItem(value: 128, child: Text('128 MB (Khuyên dùng)', style: TextStyle(color: Colors.white, fontSize: 12.5))),
                                    DropdownMenuItem(value: 256, child: Text('256 MB (Cực đại)', style: TextStyle(color: Colors.white, fontSize: 12.5))),
                                  ],
                                  onChanged: (val) {
                                    if (val != null) {
                                      HapticFeedback.selectionClick();
                                      setState(() {
                                        _bufferSizeMb = val;
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

  String _getBufferLabel(int mb) {
    switch (mb) {
      case 32:
        return '32 MB - Tiết kiệm RAM cho máy cấu hình yếu';
      case 64:
        return '64 MB - Cân bằng, mượt mà (Mặc định)';
      case 128:
        return '128 MB - Tối ưu phát video dài 1-5 tiếng';
      case 256:
        return '256 MB - Cực đại cho video 5-10 tiếng';
      default:
        return '$mb MB';
    }
  }

  String _getQualityLabel(String quality) {
    switch (BilibiliResolver.normalizeQualityCode(quality)) {
      case '80':
        return 'Full HD (1080p) - Sắc nét nhất';
      case '64':
        return 'HD (720p) - Nhanh & ổn định';
      case '32':
        return 'Tiêu chuẩn (480p)';
      case '16':
        return 'Tiết kiệm pin/dữ liệu (360p)';
      default:
        return 'HD (720p)';
    }
  }
}
