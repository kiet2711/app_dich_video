import 'package:flutter/material.dart';

import '../../data/repository/settings_repository.dart';
import '../theme/app_theme.dart';

class SubtitleControlSheet extends StatefulWidget {
  final SettingsRepository settings;
  final VoidCallback onChanged;

  const SubtitleControlSheet({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  @override
  State<SubtitleControlSheet> createState() => _SubtitleControlSheetState();
}

class _SubtitleControlSheetState extends State<SubtitleControlSheet> {
  SettingsRepository get _settings => widget.settings;

  void _notify() {
    setState(() {});
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final maxHeight = MediaQuery.of(context).size.height * 0.92;

    // 1. CHẾ ĐỘ PHỤ ĐỀ
    Widget modeSection = _buildCard(
      title: 'Chế Độ Hiển Thị',
      icon: Icons.subtitles,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildModeChip(
                mode: 'bilingual',
                label: 'Song ngữ',
                icon: Icons.translate,
              ),
              _buildModeChip(
                mode: 'translated',
                label: 'Chỉ bản dịch',
                icon: Icons.check,
              ),
              _buildModeChip(
                mode: 'original',
                label: 'Chỉ tiếng gốc',
                icon: Icons.short_text,
              ),
              _buildModeChip(
                mode: 'off',
                label: 'Tắt phụ đề',
                icon: Icons.visibility_off,
              ),
            ],
          ),
        ],
      ),
    );

    // 2. CỠ CHỮ (MIN 5 - MAX 30)
    Widget fontSizeSection = _buildCard(
      title: 'Cỡ Chữ Phụ Đề: ${_settings.subtitleFontSize.toInt()} pt',
      icon: Icons.format_size,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.remove_circle_outline, color: Colors.white70),
            onPressed: () {
              _settings.subtitleFontSize =
                  (_settings.subtitleFontSize - 1).clamp(5.0, 30.0);
              _notify();
            },
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: AppTheme.primaryEmerald,
                thumbColor: AppTheme.primaryEmerald,
                inactiveTrackColor: const Color(0xFF323444),
              ),
              child: Slider(
                value: _settings.subtitleFontSize.clamp(5.0, 30.0),
                min: 5.0,
                max: 30.0,
                onChanged: (val) {
                  _settings.subtitleFontSize = val;
                  _notify();
                },
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline, color: Colors.white70),
            onPressed: () {
              _settings.subtitleFontSize =
                  (_settings.subtitleFontSize + 1).clamp(5.0, 30.0);
              _notify();
            },
          ),
        ],
      ),
    );

    // 3. VỊ TRÍ PHỤ ĐỀ (DI CHUYỂN LÊN / XUỐNG)
    Widget positionSection = _buildCard(
      title: 'Vị Trí Phụ Đề: ${_settings.subtitleOffsetY >= 0 ? '+' : ''}${_settings.subtitleOffsetY.toInt()} px',
      icon: Icons.swap_vert,
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_downward, color: Color(0xFF64B5F6)),
                tooltip: 'Hạ xuống (-10px)',
                onPressed: () {
                  _settings.subtitleOffsetY =
                      (_settings.subtitleOffsetY - 10).clamp(-80.0, 350.0);
                  _notify();
                },
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: const Color(0xFF64B5F6),
                    thumbColor: const Color(0xFF64B5F6),
                    inactiveTrackColor: const Color(0xFF323444),
                  ),
                  child: Slider(
                    value: _settings.subtitleOffsetY.clamp(-80.0, 350.0),
                    min: -80.0,
                    max: 350.0,
                    onChanged: (val) {
                      _settings.subtitleOffsetY = val;
                      _notify();
                    },
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.arrow_upward, color: Color(0xFF64B5F6)),
                tooltip: 'Nâng lên (+10px)',
                onPressed: () {
                  _settings.subtitleOffsetY =
                      (_settings.subtitleOffsetY + 10).clamp(-80.0, 350.0);
                  _notify();
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Vuốt trực tiếp trên phụ đề để kéo',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white70,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Về đáy (0px)', style: TextStyle(fontSize: 12)),
                onPressed: () {
                  _settings.subtitleOffsetY = 0.0;
                  _notify();
                },
              ),
            ],
          ),
        ],
      ),
    );

    // 4. HỘP ĐEN & PHÔNG CHỮ
    Widget styleSection = _buildCard(
      title: 'Hộp Đen Che Chữ & Phông Chữ',
      icon: Icons.palette,
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Bật Hộp Đen Che Chữ',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              Switch(
                value: _settings.isBlackBoxEnabled,
                activeThumbColor: AppTheme.primaryEmerald,
                onChanged: (val) {
                  _settings.isBlackBoxEnabled = val;
                  _notify();
                },
              ),
            ],
          ),
          if (_settings.isBlackBoxEnabled) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  'Độ mờ: ${(_settings.blackBoxOpacity * 100).toInt()}%',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Slider(
                    value: _settings.blackBoxOpacity.clamp(0.0, 1.0),
                    activeColor: AppTheme.primaryEmerald,
                    onChanged: (val) {
                      _settings.blackBoxOpacity = val;
                      _notify();
                    },
                  ),
                ),
              ],
            ),
          ],
          if (_settings.customFonts.isNotEmpty) ...[
            const Divider(color: Color(0xFF323444), height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Phông chữ:',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                DropdownButton<String>(
                  value: _settings.selectedFontFamily.isEmpty
                      ? ''
                      : _settings.selectedFontFamily,
                  dropdownColor: const Color(0xFF1F2029),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  underline: const SizedBox.shrink(),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('Mặc định hệ thống'),
                    ),
                    ..._settings.customFonts.map(
                      (f) => DropdownMenuItem(
                        value: f,
                        child: Text(
                          f.length > 20 ? '${f.substring(0, 18)}…' : f,
                          style: TextStyle(fontFamily: f),
                        ),
                      ),
                    ),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      _settings.selectedFontFamily = val;
                      _notify();
                    }
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    );

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          decoration: BoxDecoration(
            color: AppTheme.darkCard,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.tune,
                      color: AppTheme.primaryEmerald,
                      size: 24,
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'Tùy Chỉnh Phụ Đề & Vị Trí',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (isLandscape)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            modeSection,
                            const SizedBox(height: 10),
                            fontSizeSection,
                          ],
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          children: [
                            positionSection,
                            const SizedBox(height: 10),
                            styleSection,
                          ],
                        ),
                      ),
                    ],
                  )
                else ...[
                  modeSection,
                  const SizedBox(height: 10),
                  fontSizeSection,
                  const SizedBox(height: 10),
                  positionSection,
                  const SizedBox(height: 10),
                  styleSection,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCard({
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F2029),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppTheme.primaryEmerald, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  Widget _buildModeChip({
    required String mode,
    required String label,
    required IconData icon,
  }) {
    final isSelected = _settings.subtitleMode == mode;
    return ChoiceChip(
      selected: isSelected,
      showCheckmark: false,
      avatar: Icon(
        icon,
        size: 16,
        color: isSelected ? Colors.black : Colors.white70,
      ),
      label: Text(
        label,
        style: TextStyle(
          color: isSelected ? Colors.black : Colors.white,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          fontSize: 13,
        ),
      ),
      selectedColor: AppTheme.primaryEmerald,
      backgroundColor: const Color(0xFF2A2B36),
      onSelected: (selected) {
        if (selected) {
          _settings.subtitleMode = mode;
          _notify();
        }
      },
    );
  }
}
