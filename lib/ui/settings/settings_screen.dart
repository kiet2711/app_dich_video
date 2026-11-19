import 'package:flutter/material.dart';

import '../../data/repository/settings_repository.dart';
import '../../domain/font/custom_font_manager.dart';
import '../storage/storage_cleaner_screen.dart';
import '../theme/app_theme.dart';
import 'gemini_key_test_dialog.dart';
import 'groq_key_test_dialog.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingsRepository? _settings;
  final _apiKeysController = TextEditingController();
  final _groqApiKeysController = TextEditingController();
  int _selectedAiProviderTab = 0; // 0: Gemini, 1: Groq
  bool _isAutoResilientExpanded = false;

  // Kiểu A Accordion expansion states (all collapsed by default)
  bool _expandAppearance = false;
  bool _expandAi = false;
  bool _expandCapcut = false;
  bool _expandFont = false;
  bool _expandCdn = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await SettingsRepository.getInstance();
    if (!mounted) return;
    setState(() {
      _settings = s;
      _apiKeysController.text = s.geminiApiKeys.join('\n');
      _groqApiKeysController.text = s.groqApiKeys.join('\n');
    });
  }

  List<String> _parseKeys(String raw) {
    return raw
        .split(RegExp(r'[,;\n]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  void _openKeyTestDialog() {
    final keys = _parseKeys(_apiKeysController.text);

    if (_settings != null && keys.isNotEmpty) {
      // Tự đồng bộ key đã nhập để Trợ lý AI & bộ dịch dùng được ngay
      _settings!.geminiApiKeys = keys;
    }

    if (keys.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Vui lòng nhập ít nhất 1 Gemini API Key để kiểm tra!'),
        ),
      );
      return;
    }

    final currentModel = (_settings?.selectedModel.startsWith('gemini') == true)
        ? _settings!.selectedModel
        : 'gemini-3.5-flash-lite';

    showDialog(
      context: context,
      builder: (_) => GeminiKeyTestDialog(
        apiKeys: keys,
        initialModelId: currentModel,
        onRemoveDeadKeys: (aliveKeys) {
          setState(() {
            _apiKeysController.text = aliveKeys.join('\n');
            if (_settings != null) {
              _settings!.geminiApiKeys = aliveKeys;
            }
          });
        },
      ),
    );
  }

  void _openGroqKeyTestDialog() {
    final keys = _parseKeys(_groqApiKeysController.text);

    if (_settings != null && keys.isNotEmpty) {
      _settings!.groqApiKeys = keys;
    }

    if (keys.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Vui lòng nhập ít nhất 1 Groq API Key để kiểm tra!'),
        ),
      );
      return;
    }

    final currentModel = (_settings?.selectedGroqModel.isNotEmpty == true)
        ? _settings!.selectedGroqModel
        : 'openai/gpt-oss-120b';

    showDialog(
      context: context,
      builder: (_) => GroqKeyTestDialog(
        apiKeys: keys,
        initialModelId: currentModel,
        onRemoveDeadKeys: (aliveKeys) {
          setState(() {
            _groqApiKeysController.text = aliveKeys.join('\n');
            if (_settings != null) {
              _settings!.groqApiKeys = aliveKeys;
            }
          });
        },
      ),
    );
  }

  @override
  void dispose() {
    if (_settings != null) {
      _settings!.geminiApiKeys = _parseKeys(_apiKeysController.text);
      _settings!.groqApiKeys = _parseKeys(_groqApiKeysController.text);
    }
    _apiKeysController.dispose();
    _groqApiKeysController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppThemeController.instance,
      builder: (context, _) {
        final palette = AppThemePalette.of(context);
        final accent = palette.accentFor(AppTabId.settings);

        if (_settings == null) {
          return AppTabBackdrop(
            tab: AppTabId.settings,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: Center(child: CircularProgressIndicator(color: accent)),
            ),
          );
        }

        final gemKeyCount = _parseKeys(_apiKeysController.text).length;
        final groqKeyCount = _parseKeys(_groqApiKeysController.text).length;
        final aiSummary =
            'Gemini $gemKeyCount key (${_settings!.geminiThreadCount}L) • Groq $groqKeyCount key (${_settings!.groqThreadCount}L)';
        final capcutSummary =
            'STT ${_settings!.capcutSttConcurrency}x • Cắt ${_settings!.audioSliceConcurrency}x • ${_settings!.audioChunkDurationMin}p';
        final fontSummary = _settings!.selectedFontFamily.isEmpty
            ? 'Mặc định hệ thống'
            : _settings!.selectedFontFamily;
        final cdnSummary = '${_settings!.downloadThreadCount} luồng tải';

        return AppTabBackdrop(
          tab: AppTabId.settings,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              foregroundColor: palette.textPrimary,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Cài đặt hệ thống',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      color: palette.textPrimary,
                    ),
                  ),
                  Text(
                    'Giao diện, AI dịch thuật & tối ưu xử lý',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: palette.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            body: ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                MediaQuery.paddingOf(context).bottom + 24,
              ),
              children: [
                // Card 1 (Accordion): Giao diện & Màu sắc
                _buildAccordionCard(
                  palette: palette,
                  accent: accent,
                  icon: Icons.palette_rounded,
                  iconBgColor: accent,
                  title: 'Giao diện & Màu sắc',
                  summary:
                      '${palette.mode.name} • ${palette.isFloatingNav ? "Viên thuốc nổi" : "Liền đáy gốc"}',
                  isExpanded: _expandAppearance,
                  onToggle: () =>
                      setState(() => _expandAppearance = !_expandAppearance),
                  child: _buildAppearanceSectionBody(palette, accent),
                ),
                const SizedBox(height: 12),

                // Card 2 (Accordion): AI Dịch thuật (Gemini & Groq)
                _buildAccordionCard(
                  palette: palette,
                  accent: accent,
                  icon: Icons.auto_awesome_rounded,
                  iconBgColor: accent,
                  title: 'AI Dịch thuật (Gemini & Groq)',
                  summary: aiSummary,
                  isExpanded: _expandAi,
                  onToggle: () => setState(() => _expandAi = !_expandAi),
                  child: _buildAiSectionBody(palette, accent),
                ),
                const SizedBox(height: 12),

                // Card 3 (Accordion): Đa luồng & Phân đoạn CapCut
                _buildAccordionCard(
                  palette: palette,
                  accent: accent,
                  icon: Icons.speed_rounded,
                  iconBgColor: palette.secondaryFor(AppTabId.studio),
                  title: 'Đa luồng & Phân đoạn CapCut',
                  summary: capcutSummary,
                  isExpanded: _expandCapcut,
                  onToggle: () =>
                      setState(() => _expandCapcut = !_expandCapcut),
                  child: _buildCapcutSectionBody(palette, accent),
                ),
                const SizedBox(height: 12),

                // Card 4 (Accordion): Phông chữ phụ đề
                _buildAccordionCard(
                  palette: palette,
                  accent: accent,
                  icon: Icons.font_download_rounded,
                  iconBgColor: palette.accentFor(AppTabId.bilibili),
                  title: 'Phông chữ phụ đề',
                  summary: fontSummary,
                  isExpanded: _expandFont,
                  onToggle: () => setState(() => _expandFont = !_expandFont),
                  child: _buildFontSectionBody(palette, accent),
                ),
                const SizedBox(height: 12),

                // Card 5 (Accordion): Tải video online (CDN)
                _buildAccordionCard(
                  palette: palette,
                  accent: accent,
                  icon: Icons.rocket_launch_rounded,
                  iconBgColor: palette.accentFor(AppTabId.hongguo),
                  title: 'Tải video online (CDN)',
                  summary: cdnSummary,
                  isExpanded: _expandCdn,
                  onToggle: () => setState(() => _expandCdn = !_expandCdn),
                  child: _buildCdnSectionBody(palette, accent),
                ),
                const SizedBox(height: 12),

                // Card 6: Quản lý bộ nhớ & Dọn dẹp rác
                _buildStorageCard(palette),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAppearanceSectionBody(AppThemePalette palette, Color accent) {
    final presets = appThemeModes.values.toList();
    final tabEntries = <(AppTabId tab, String label, IconData icon)>[
      (AppTabId.studio, 'Studio & TTS', Icons.auto_fix_high_rounded),
      (AppTabId.hongguo, 'Hồng Quả', Icons.local_fire_department_rounded),
      (AppTabId.bilibili, 'Bilibili', Icons.tv_rounded),
      (AppTabId.history, 'Lịch Sử', Icons.history_rounded),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Nền giao diện (5 tông màu) + nút khôi phục mặc định
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'NỀN GIAO DIỆN',
              style: TextStyle(
                color: palette.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.7,
              ),
            ),
            TextButton.icon(
              onPressed: () => AppThemeController.instance.resetToDefaults(),
              icon: Icon(
                Icons.refresh_rounded,
                size: 16,
                color: palette.textMuted,
              ),
              label: Text(
                'Mặc định',
                style: TextStyle(color: palette.textMuted, fontSize: 12),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
          SizedBox(
            height: 88,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: presets.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final preset = presets[i];
                final isSelected = palette.mode.id == preset.id;
                return InkWell(
                  onTap: () =>
                      AppThemeController.instance.setThemeMode(preset.id),
                  borderRadius: BorderRadius.circular(14),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 102,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? accent.withValues(
                              alpha: palette.isDark ? 0.16 : 0.08,
                            )
                          : palette.surfaceAlt,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isSelected ? accent : palette.border,
                        width: isSelected ? 1.8 : 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: preset.previewColors,
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: preset.isDark
                                      ? Colors.white24
                                      : Colors.black12,
                                ),
                              ),
                              alignment: Alignment.center,
                              child: Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: preset.previewDot,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                            if (isSelected)
                              Icon(
                                Icons.check_circle_rounded,
                                color: accent,
                                size: 16,
                              ),
                          ],
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              preset.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.textPrimary,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              preset.tag,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.textMuted,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),

          // 2. Màu chủ đạo từng tab
          Text(
            'MÀU CHỦ ĐẠO TỪNG TAB',
            style: TextStyle(
              color: palette.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.7,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: palette.surfaceAlt,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: palette.border),
            ),
            child: Column(
              children: [
                for (int i = 0; i < tabEntries.length; i++) ...[
                  if (i > 0) Divider(height: 16, color: palette.border),
                  _buildTabAccentRow(
                    palette: palette,
                    tab: tabEntries[i].$1,
                    label: tabEntries[i].$2,
                    icon: tabEntries[i].$3,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 3. Kiểu thanh điều hướng
          Text(
            'KIỂU THANH ĐIỀU HƯỚNG',
            style: TextStyle(
              color: palette.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.7,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _buildNavStyleOption(
                  palette: palette,
                  accent: accent,
                  styleId: 'floating',
                  title: 'Viên thuốc nổi',
                  subtitle: 'Thoáng nổi hiện đại',
                  icon: Icons.smart_button_rounded,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildNavStyleOption(
                  palette: palette,
                  accent: accent,
                  styleId: 'docked',
                  title: 'Liền đáy gốc',
                  subtitle: 'Cố định cạnh dưới',
                  icon: Icons.view_agenda_outlined,
                ),
              ),
            ],
          ),
        ],
    );
  }

  Widget _buildTabAccentRow({
    required AppThemePalette palette,
    required AppTabId tab,
    required String label,
    required IconData icon,
  }) {
    final currentAccent = palette.accentFor(tab);
    final options = appTabAccentOptions[tab] ?? const <AppAccentOption>[];

    return Row(
      children: [
        Icon(icon, size: 16, color: currentAccent),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Wrap(
          spacing: 7,
          children: options.map((opt) {
            final isSel = opt.primary.toARGB32() == currentAccent.toARGB32();
            return Tooltip(
              message: opt.name,
              child: GestureDetector(
                onTap: () =>
                    AppThemeController.instance.setTabAccent(tab, opt.primary),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [opt.primary, opt.secondary],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSel ? palette.textPrimary : Colors.transparent,
                      width: 2,
                    ),
                    boxShadow: isSel
                        ? [
                            BoxShadow(
                              color: opt.primary.withValues(alpha: 0.4),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ]
                        : null,
                  ),
                  child: isSel
                      ? Icon(
                          Icons.check_rounded,
                          size: 13,
                          color: palette.onColor(opt.primary),
                        )
                      : null,
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildNavStyleOption({
    required AppThemePalette palette,
    required Color accent,
    required String styleId,
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    final isSelected = palette.navStyle == styleId;
    return InkWell(
      onTap: () => AppThemeController.instance.setNavStyle(styleId),
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: isSelected
              ? accent.withValues(alpha: palette.isDark ? 0.16 : 0.08)
              : palette.surfaceAlt,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? accent : palette.border,
            width: isSelected ? 1.6 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 19,
              color: isSelected ? accent : palette.textSecondary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isSelected ? accent : palette.textPrimary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: palette.textMuted, fontSize: 10.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccordionCard({
    required AppThemePalette palette,
    required Color accent,
    required IconData icon,
    required Color iconBgColor,
    required String title,
    required String summary,
    required bool isExpanded,
    required VoidCallback onToggle,
    required Widget child,
  }) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isExpanded ? accent.withValues(alpha: 0.45) : palette.border,
        ),
        boxShadow: palette.cardShadows,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: iconBgColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: iconBgColor, size: 21),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: accent,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: isExpanded ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: palette.textMuted,
                      size: 24,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: isExpanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Divider(height: 1, color: palette.border),
                      Padding(padding: const EdgeInsets.all(16), child: child),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildAiSectionBody(AppThemePalette palette, Color accent) {
    final groqAmber = palette.isDark ? Colors.amber : const Color(0xFFD97706);

    int resilientActiveCount = 0;
    if (_settings!.enableSmartModelFallback) resilientActiveCount++;
    if (_settings!.enableCrossProviderFallback) resilientActiveCount++;
    if (_settings!.enableDualModelBalancing) resilientActiveCount++;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Tab Pill Selector giữa Gemini và Groq
        Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: palette.surfaceAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _selectedAiProviderTab = 0),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: _selectedAiProviderTab == 0
                          ? accent.withValues(
                              alpha: palette.isDark ? 0.2 : 0.12,
                            )
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _selectedAiProviderTab == 0
                            ? accent
                            : Colors.transparent,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.auto_awesome,
                          size: 15,
                          color: _selectedAiProviderTab == 0
                              ? accent
                              : palette.textMuted,
                        ),
                        const SizedBox(width: 6),
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _apiKeysController,
                          builder: (context, val, _) {
                            final count = _parseKeys(val.text).length;
                            return Text(
                              'Gemini ($count)',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: _selectedAiProviderTab == 0
                                    ? accent
                                    : palette.textSecondary,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _selectedAiProviderTab = 1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: _selectedAiProviderTab == 1
                          ? groqAmber.withValues(
                              alpha: palette.isDark ? 0.2 : 0.12,
                            )
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _selectedAiProviderTab == 1
                            ? groqAmber
                            : Colors.transparent,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.electric_bolt_rounded,
                          size: 15,
                          color: _selectedAiProviderTab == 1
                              ? groqAmber
                              : palette.textMuted,
                        ),
                        const SizedBox(width: 6),
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _groqApiKeysController,
                          builder: (context, val, _) {
                            final count = _parseKeys(val.text).length;
                            return Text(
                              'Groq AI ($count)',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: _selectedAiProviderTab == 1
                                    ? groqAmber
                                    : palette.textSecondary,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        if (_selectedAiProviderTab == 0)
          _buildProviderConfigPanel(
            palette: palette,
            tabColor: accent,
            keyListLabel:
                'Danh sách Gemini API Key (mỗi dòng 1 key để xoay vòng):',
            controller: _apiKeysController,
            hintText: 'Dán các API Key tại đây...',
            testButtonLabel: 'Kiểm tra Key Gemini (Sống / Chết)',
            testButtonIcon: Icons.bolt_rounded,
            onTestPressed: _openKeyTestDialog,
            onKeysChanged: (val) {
              if (_settings != null) {
                _settings!.geminiApiKeys = _parseKeys(val);
              }
            },
            threadTitle: 'SỐ LUỒNG DỊCH SONG SONG (GEMINI):',
            threadCount: _settings!.geminiThreadCount,
            onThreadChanged: (v) =>
                setState(() => _settings!.geminiThreadCount = v),
            batchHint: 'Số câu phụ đề gửi lên Gemini trong mỗi lượt dịch (Khuyên dùng: 45 câu).',
            batchValue: _settings!.geminiBatchSize,
            onBatchChanged: (v) =>
                setState(() => _settings!.geminiBatchSize = v),
            batch100Label: '100 câu / request (Cực nhanh, ít gọi API)',
          )
        else
          _buildProviderConfigPanel(
            palette: palette,
            tabColor: groqAmber,
            keyListLabel: 'Danh sách Groq API Key (bắt đầu bằng "gsk_...", mỗi dòng 1 key):',
            controller: _groqApiKeysController,
            hintText: 'Dán các Groq API Key (gsk_...) tại đây...',
            testButtonLabel: 'Kiểm tra Key Groq (Sống / Chết)',
            testButtonIcon: Icons.electric_bolt_rounded,
            onTestPressed: _openGroqKeyTestDialog,
            onKeysChanged: (val) {
              if (_settings != null) {
                _settings!.groqApiKeys = _parseKeys(val);
              }
            },
            threadTitle: 'SỐ LUỒNG DỊCH SONG SONG (GROQ):',
            threadCount: _settings!.groqThreadCount,
            onThreadChanged: (v) =>
                setState(() => _settings!.groqThreadCount = v),
            batchHint: 'Số câu phụ đề gửi lên Groq trong mỗi lượt dịch (Groq xử lý siêu nhanh trên LPU).',
            batchValue: _settings!.groqBatchSize,
            onBatchChanged: (v) => setState(() => _settings!.groqBatchSize = v),
            batch100Label: '100 câu / request (Cực nhanh trên LPU Groq)',
          ),

        const SizedBox(height: 14),
        // Auto Resilient nested card
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: palette.surfaceAlt,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: () {
                  setState(() {
                    _isAutoResilientExpanded = !_isAutoResilientExpanded;
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 11,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.auto_mode_rounded,
                            color: accent,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'CƠ CHẾ XOAY THÔNG MINH & CÂN BẰNG TẢI',
                              style: TextStyle(
                                color: palette.textPrimary,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              'AUTO RESILIENT',
                              style: TextStyle(
                                color: accent,
                                fontSize: 9.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          AnimatedRotation(
                            turns: _isAutoResilientExpanded ? 0.5 : 0.0,
                            duration: const Duration(milliseconds: 200),
                            child: Icon(
                              Icons.keyboard_arrow_down_rounded,
                              color: palette.textSecondary,
                              size: 20,
                            ),
                          ),
                        ],
                      ),
                      if (!_isAutoResilientExpanded) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: resilientActiveCount > 0
                                    ? accent
                                    : palette.textMuted,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                resilientActiveCount > 0
                                    ? '$resilientActiveCount/3 cơ chế bảo vệ đang bật • Chạm để mở'
                                    : 'Đang tắt • Chạm để mở',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.textMuted,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeInOut,
                alignment: Alignment.topCenter,
                child: _isAutoResilientExpanded
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Divider(color: palette.border, height: 1),
                            const SizedBox(height: 4),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              activeThumbColor: accent,
                              title: Text(
                                'Đổi Model phụ trên cùng Key khi chạm Quota (429)',
                                style: TextStyle(
                                  color: palette.textPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                'Khi model 3.1 chạm limit, tự đổi sang 3.5 trên cùng Key trước khi đổi sang Key khác.',
                                style: TextStyle(
                                  color: palette.textSecondary,
                                  fontSize: 11,
                                ),
                              ),
                              value: _settings!.enableSmartModelFallback,
                              onChanged: (val) {
                                setState(() {
                                  _settings!.enableSmartModelFallback = val;
                                });
                              },
                            ),
                            Divider(color: palette.border),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              activeThumbColor: accent,
                              title: Text(
                                'Chuyển sang Groq AI khi toàn bộ Key Gemini cạn',
                                style: TextStyle(
                                  color: palette.textPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                'Tự động nhảy sang Groq Cloud (hoặc ngược lại) để đảm bảo không đứt gánh giữa chừng.',
                                style: TextStyle(
                                  color: palette.textSecondary,
                                  fontSize: 11,
                                ),
                              ),
                              value: _settings!.enableCrossProviderFallback,
                              onChanged: (val) {
                                setState(() {
                                  _settings!.enableCrossProviderFallback = val;
                                });
                              },
                            ),
                            Divider(color: palette.border),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              activeThumbColor: accent,
                              title: Text(
                                'Cân bằng tải song song đa Model (Dual-Model)',
                                style: TextStyle(
                                  color: palette.textPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                'Chạy đồng thời các luồng giữa Model 3.1 & 3.5 trên các Key để nhân đôi tốc độ dịch.',
                                style: TextStyle(
                                  color: palette.textSecondary,
                                  fontSize: 11,
                                ),
                              ),
                              value: _settings!.enableDualModelBalancing,
                              onChanged: (val) {
                                setState(() {
                                  _settings!.enableDualModelBalancing = val;
                                });
                              },
                            ),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildProviderConfigPanel({
    required AppThemePalette palette,
    required Color tabColor,
    required String keyListLabel,
    required TextEditingController controller,
    required String hintText,
    required String testButtonLabel,
    required IconData testButtonIcon,
    required VoidCallback onTestPressed,
    ValueChanged<String>? onKeysChanged,
    required String threadTitle,
    required int threadCount,
    required ValueChanged<int> onThreadChanged,
    required String batchHint,
    required int batchValue,
    required ValueChanged<int> onBatchChanged,
    required String batch100Label,
  }) {
    final safeBatch = [30, 45, 60, 80, 100].contains(batchValue)
        ? batchValue
        : 45;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          keyListLabel,
          style: TextStyle(color: palette.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLines: 4,
          style: TextStyle(color: palette.textPrimary, fontSize: 13),
          onChanged: onKeysChanged,
          decoration: InputDecoration(
            filled: true,
            fillColor: palette.surfaceAlt,
            hintText: hintText,
            hintStyle: TextStyle(color: palette.textMuted),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: palette.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: palette.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: tabColor, width: 1.5),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, val, _) {
                final count = _parseKeys(val.text).length;
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: palette.surfaceAlt,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: palette.border),
                  ),
                  child: Text(
                    '$count key',
                    style: TextStyle(
                      color: palette.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                );
              },
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: tabColor,
                  side: BorderSide(color: tabColor),
                  padding: const EdgeInsets.symmetric(
                    vertical: 10,
                    horizontal: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: Icon(testButtonIcon, size: 18),
                label: Text(
                  testButtonLabel,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onPressed: onTestPressed,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                threadTitle,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
            Text(
              '$threadCount LUỒNG',
              style: TextStyle(
                color: tabColor,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ],
        ),
        Slider(
          value: threadCount.toDouble(),
          min: 1,
          max: 20,
          divisions: 19,
          activeColor: tabColor,
          onChanged: (val) => onThreadChanged(val.toInt()),
        ),
        const SizedBox(height: 8),
        Text(
          'SỐ CÂU PHỤ ĐỀ / REQUEST (BATCH SIZE):',
          style: TextStyle(
            color: palette.textPrimary,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          batchHint,
          style: TextStyle(color: palette.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          decoration: BoxDecoration(
            color: palette.surfaceAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: palette.border),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: safeBatch,
              isExpanded: true,
              dropdownColor: palette.surface,
              icon: Icon(Icons.keyboard_arrow_down, color: tabColor),
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              items: [
                const DropdownMenuItem<int>(
                  value: 30,
                  child: Text(
                    '30 câu / request (Chia nhỏ, dịch rất kỹ)',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const DropdownMenuItem<int>(
                  value: 45,
                  child: Text(
                    '45 câu / request (Mặc định - Khuyên dùng)',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const DropdownMenuItem<int>(
                  value: 60,
                  child: Text(
                    '60 câu / request (Nhanh hơn, tiết kiệm request)',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const DropdownMenuItem<int>(
                  value: 80,
                  child: Text(
                    '80 câu / request (Tối ưu cho video dài)',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem<int>(
                  value: 100,
                  child: Text(batch100Label, overflow: TextOverflow.ellipsis),
                ),
              ],
              onChanged: (val) {
                if (val != null) onBatchChanged(val);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCapcutSectionBody(AppThemePalette palette, Color accent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                'SỐ LUỒNG NHẬN DIỆN CAPCUT (STT):',
                style: TextStyle(
                  color: palette.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${_settings!.capcutSttConcurrency} LUỒNG',
              style: TextStyle(
                color: accent,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Xử lý song song nhiều phân đoạn âm thanh qua CapCut Cloud, giúp tạo sub cho video dài (1-3 tiếng) nhanh gấp nhiều lần (Tối đa 20 luồng).',
          style: TextStyle(color: palette.textSecondary, fontSize: 12),
        ),
        Slider(
          value: _settings!.capcutSttConcurrency.toDouble(),
          min: 1,
          max: 20,
          divisions: 19,
          activeColor: accent,
          onChanged: (val) {
            setState(() {
              _settings!.capcutSttConcurrency = val.toInt();
            });
          },
        ),
        const SizedBox(height: 6),
        Divider(color: palette.border),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                'SỐ LUỒNG CẮT ÂM THANH ĐỒNG THỜI:',
                style: TextStyle(
                  color: palette.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${_settings!.audioSliceConcurrency} LUỒNG',
              style: TextStyle(
                color: accent,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Số luồng trích xuất các phân đoạn âm thanh song song từ file âm thanh tổng (Tối đa 20 luồng).',
          style: TextStyle(color: palette.textSecondary, fontSize: 12),
        ),
        Slider(
          value: _settings!.audioSliceConcurrency.toDouble(),
          min: 1,
          max: 20,
          divisions: 19,
          activeColor: accent,
          onChanged: (val) {
            setState(() {
              _settings!.audioSliceConcurrency = val.toInt();
            });
          },
        ),
        const SizedBox(height: 6),
        Divider(color: palette.border),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                'THỜI LƯỢNG MỖI PHÂN ĐOẠN (GỬI CAPCUT):',
                style: TextStyle(
                  color: palette.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color: palette.surfaceAlt,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: palette.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.remove_circle_outline_rounded,
                      size: 20,
                      color: accent,
                    ),
                    tooltip: 'Giảm 1 phút',
                    onPressed: _settings!.audioChunkDurationMin > 1
                        ? () {
                            setState(() {
                              _settings!.audioChunkDurationMin--;
                            });
                          }
                        : null,
                  ),
                  Container(
                    constraints: const BoxConstraints(minWidth: 64),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      '${_settings!.audioChunkDurationMin} PHÚT',
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.add_circle_outline_rounded,
                      size: 20,
                      color: accent,
                    ),
                    tooltip: 'Tăng 1 phút',
                    onPressed: _settings!.audioChunkDurationMin < 15
                        ? () {
                            setState(() {
                              _settings!.audioChunkDurationMin++;
                            });
                          }
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Thời lượng tối đa của mỗi đoạn âm thanh khi gửi nhận diện CapCut Cloud (từ 1 đến 15 phút, mặc định: 10 phút). Video ngắn hơn mốc này sẽ gửi nguyên file.',
          style: TextStyle(color: palette.textSecondary, fontSize: 12),
        ),
        Slider(
          value: _settings!.audioChunkDurationMin.toDouble(),
          min: 1,
          max: 15,
          divisions: 14,
          activeColor: accent,
          onChanged: (val) {
            setState(() {
              _settings!.audioChunkDurationMin = val.toInt();
            });
          },
        ),
      ],
    );
  }

  Widget _buildFontSectionBody(AppThemePalette palette, Color accent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Khung xem trước font giữ nền tối điện ảnh giống màn hình phát video thực tế
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF0E1018),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'XEM TRƯỚC PHÔNG CHỮ:',
                    style: TextStyle(
                      color: Colors.white60,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    _settings!.selectedFontFamily.isEmpty
                        ? 'Mặc định hệ thống'
                        : _settings!.selectedFontFamily,
                    style: TextStyle(
                      color: accent,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Xin chào thế giới! Phụ đề tiếng Việt 123',
                style: TextStyle(
                  fontFamily: _settings!.selectedFontFamily.isEmpty
                      ? null
                      : _settings!.selectedFontFamily,
                  color: Colors.white,
                  fontSize: _settings!.subtitleFontSize.clamp(12.0, 22.0),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: accent,
              side: BorderSide(color: accent),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            icon: const Icon(Icons.file_upload_outlined, size: 20),
            label: const Text(
              'Nhập Phông Chữ Từ File (.ttf, .otf)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            onPressed: () async {
              try {
                final family = await CustomFontManager.pickAndImportFont(
                  _settings!,
                );
                if (family != null && mounted) {
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Đã nạp thành công phông chữ "$family"!',
                        style: TextStyle(color: palette.onColor(accent)),
                      ),
                      backgroundColor: accent,
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Lỗi nhập phông chữ: $e'),
                      backgroundColor: Colors.redAccent,
                    ),
                  );
                }
              }
            },
          ),
        ),
        const SizedBox(height: 14),

        Text(
          'DANH SÁCH PHÔNG CHỮ:',
          style: TextStyle(
            color: palette.textMuted,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 6),

        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: Icon(
            _settings!.selectedFontFamily.isEmpty
                ? Icons.check_circle
                : Icons.radio_button_unchecked,
            color: _settings!.selectedFontFamily.isEmpty
                ? accent
                : palette.textMuted,
            size: 20,
          ),
          title: Text(
            'Mặc định hệ thống',
            style: TextStyle(color: palette.textPrimary, fontSize: 14),
          ),
          onTap: () {
            setState(() {
              _settings!.selectedFontFamily = '';
            });
          },
        ),

        ..._settings!.customFonts.map((family) {
          final isSelected = _settings!.selectedFontFamily == family;
          return ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(
              isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
              color: isSelected ? accent : palette.textMuted,
              size: 20,
            ),
            title: Text(
              family,
              style: TextStyle(
                fontFamily: family,
                color: isSelected ? accent : palette.textPrimary,
                fontSize: 14,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            trailing: IconButton(
              icon: const Icon(
                Icons.delete_outline,
                color: Colors.redAccent,
                size: 20,
              ),
              tooltip: 'Xóa phông chữ này',
              onPressed: () async {
                await CustomFontManager.deleteFont(family, _settings!);
                if (mounted) setState(() {});
              },
            ),
            onTap: () {
              setState(() {
                _settings!.selectedFontFamily = family;
              });
            },
          );
        }),
      ],
    );
  }

  Widget _buildCdnSectionBody(AppThemePalette palette, Color accent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                'SỐ LUỒNG TẢI VIDEO & AUDIO:',
                style: TextStyle(
                  color: palette.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${_settings!.downloadThreadCount} LUỒNG',
              style: TextStyle(
                color: accent,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Tải đa luồng song song luân phiên qua các cụm máy chủ CDN (Tencent, Alibaba, Huawei, Bilibili) giúp tăng tốc độ tải video và âm thanh lên gấp 5-10 lần (Khuyên dùng: 12 - 24 luồng).',
          style: TextStyle(color: palette.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Slider(
          value: _settings!.downloadThreadCount.toDouble(),
          min: 8.0,
          max: 32.0,
          divisions: 24,
          activeColor: accent,
          inactiveColor: palette.border,
          onChanged: (val) {
            setState(() {
              _settings!.downloadThreadCount = val.toInt();
            });
          },
        ),
      ],
    );
  }

  Widget _buildStorageCard(AppThemePalette palette) {
    final amber = palette.isDark
        ? Colors.orangeAccent
        : const Color(0xFFEA580C);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.border),
        boxShadow: palette.cardShadows,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: amber.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.cleaning_services_rounded,
                  color: amber,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Trình dọn rác thông minh',
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Quét chi tiết video, audio TTS, phụ đề và rác tạm',
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Giúp bạn xem trực quan những gì đã tải về (video Bilibili, phim Hồng Quả, giọng đọc AI, tệp tạm) để dọn dẹp chọn lọc hoặc dọn rác an toàn chỉ với 1 chạm.',
            style: TextStyle(color: palette.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: amber,
                foregroundColor: palette.onColor(amber),
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.auto_delete_rounded, size: 20),
              label: const Text(
                'Mở Trình Dọn Dẹp Bộ Nhớ',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (ctx) => const StorageCleanerScreen(),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
