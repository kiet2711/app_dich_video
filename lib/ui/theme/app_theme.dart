import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/repository/settings_repository.dart';

/// Các hằng màu tối điện ảnh dùng cho trình phát video & màn hình Lướt Shorts.
/// Giữ nguyên để tương thích ngược với các widget phát video nền tối.
class AppColors {
  static const darkBackground = Color(0xFF0F1015);
  static const darkSurface = Color(0xFF181920);
  static const darkCard = Color(0xFF181920);
  static const darkSurfaceVariant = Color(0xFF22232D);
  static const cardBorder = Color(0xFF2D2F3E);

  static const primaryEmerald = Color(0xFF00E676);
  static const primaryEmeraldDark = Color(0xFF00B0FF);
  static const accentGold = Color(0xFFFFD54F);

  static const textPrimary = Color(0xFFEDEDED);
  static const textSecondary = Color(0xFFA0A3B1);
  static const textMuted = Color(0xFF6B6E7D);
}

typedef AppTheme = AppColors;

enum AppTabId { studio, hongguo, bilibili, history, settings }

class AppAccentOption {
  final String name;
  final Color primary;
  final Color secondary;

  const AppAccentOption({
    required this.name,
    required this.primary,
    required this.secondary,
  });
}

class AppThemeModePreset {
  final String id;
  final String name;
  final String tag;
  final bool isDark;
  final Color surface;
  final Color surfaceAlt;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color navBg;
  final Color tabBgStudio;
  final Color tabBgHongguo;
  final Color tabBgBilibili;
  final Color tabBgHistory;
  final Color tabBgSettings;
  final List<Color> previewColors;
  final Color previewDot;

  const AppThemeModePreset({
    required this.id,
    required this.name,
    required this.tag,
    required this.isDark,
    required this.surface,
    required this.surfaceAlt,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.navBg,
    required this.tabBgStudio,
    required this.tabBgHongguo,
    required this.tabBgBilibili,
    required this.tabBgHistory,
    required this.tabBgSettings,
    required this.previewColors,
    required this.previewDot,
  });

  Color backgroundFor(AppTabId tab) {
    return switch (tab) {
      AppTabId.studio => tabBgStudio,
      AppTabId.hongguo => tabBgHongguo,
      AppTabId.bilibili => tabBgBilibili,
      AppTabId.history => tabBgHistory,
      AppTabId.settings => tabBgSettings,
    };
  }
}

const Map<String, AppThemeModePreset> appThemeModes = {
  'fresh': AppThemeModePreset(
    id: 'fresh',
    name: 'Tươi sáng',
    tag: 'Xanh · Hồng',
    isDark: false,
    surface: Color(0xFCFFFFFF),
    surfaceAlt: Color(0xFFEEF3FC),
    border: Color(0x2B4A5E96),
    textPrimary: Color(0xFF0F172A),
    textSecondary: Color(0xFF334155),
    textMuted: Color(0xFF52637A),
    navBg: Color(0xE8FFFFFF),
    tabBgStudio: Color(0xFFE5EEFF),
    tabBgHongguo: Color(0xFFFFE9E5),
    tabBgBilibili: Color(0xFFFFE9F2),
    tabBgHistory: Color(0xFFEDE6FF),
    tabBgSettings: Color(0xFFE6EFFD),
    previewColors: [Color(0xFFD6EAFF), Color(0xFFFFDFEE)],
    previewDot: Color(0xFFFB7299),
  ),
  'pure': AppThemeModePreset(
    id: 'pure',
    name: 'Trắng sứ',
    tag: 'Tối giản',
    isDark: false,
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFF4F5F7),
    border: Color(0x1F0F172A),
    textPrimary: Color(0xFF111827),
    textSecondary: Color(0xFF374151),
    textMuted: Color(0xFF64748B),
    navBg: Color(0xF7FFFFFF),
    tabBgStudio: Color(0xFFFFFFFF),
    tabBgHongguo: Color(0xFFFFFFFF),
    tabBgBilibili: Color(0xFFFFFFFF),
    tabBgHistory: Color(0xFFFFFFFF),
    tabBgSettings: Color(0xFFFFFFFF),
    previewColors: [Color(0xFFFFFFFF), Color(0xFFF8FAFC)],
    previewDot: Color(0xFF00AEEC),
  ),
  'warm': AppThemeModePreset(
    id: 'warm',
    name: 'Kem ấm',
    tag: 'Dịu mắt',
    isDark: false,
    surface: Color(0xFFFFFDF8),
    surfaceAlt: Color(0xFFF5EFE4),
    border: Color(0x1F785A32),
    textPrimary: Color(0xFF292018),
    textSecondary: Color(0xFF534334),
    textMuted: Color(0xFF746250),
    navBg: Color(0xF2FFFCF5),
    tabBgStudio: Color(0xFFFAF5EC),
    tabBgHongguo: Color(0xFFFDF3EC),
    tabBgBilibili: Color(0xFFF9F4EE),
    tabBgHistory: Color(0xFFF8F3FA),
    tabBgSettings: Color(0xFFFAF6EE),
    previewColors: [Color(0xFFFFFBF2), Color(0xFFF5E9D6)],
    previewDot: Color(0xFFD97706),
  ),
  'midnight': AppThemeModePreset(
    id: 'midnight',
    name: 'Tối hiện đại',
    tag: 'Midnight',
    isDark: true,
    surface: Color(0xFF1A1E2B),
    surfaceAlt: Color(0xFF242A3B),
    border: Color(0x17FFFFFF),
    textPrimary: Color(0xFFF1F5F9),
    textSecondary: Color(0xFFA7B3C9),
    textMuted: Color(0xFF6D7A94),
    navBg: Color(0xF0161A26),
    tabBgStudio: Color(0xFF111420),
    tabBgHongguo: Color(0xFF171216),
    tabBgBilibili: Color(0xFF101620),
    tabBgHistory: Color(0xFF141221),
    tabBgSettings: Color(0xFF121520),
    previewColors: [Color(0xFF1E2436), Color(0xFF111420)],
    previewDot: Color(0xFF6366F1),
  ),
  'amoled': AppThemeModePreset(
    id: 'amoled',
    name: 'AMOLED',
    tag: 'Đen sâu',
    isDark: true,
    surface: Color(0xFF111217),
    surfaceAlt: Color(0xFF1B1D25),
    border: Color(0x14FFFFFF),
    textPrimary: Color(0xFFF8FAFC),
    textSecondary: Color(0xFF9CA3AF),
    textMuted: Color(0xFF64748B),
    navBg: Color(0xF50A0A0E),
    tabBgStudio: Color(0xFF000000),
    tabBgHongguo: Color(0xFF000000),
    tabBgBilibili: Color(0xFF000000),
    tabBgHistory: Color(0xFF000000),
    tabBgSettings: Color(0xFF000000),
    previewColors: [Color(0xFF050507), Color(0xFF111217)],
    previewDot: Color(0xFF10B981),
  ),
};

const Map<AppTabId, List<AppAccentOption>> appTabAccentOptions = {
  AppTabId.studio: [
    AppAccentOption(
      name: 'Indigo Studio',
      primary: Color(0xFF5B5CF6),
      secondary: Color(0xFF10B981),
    ),
    AppAccentOption(
      name: 'Ngọc Lục Bảo',
      primary: Color(0xFF059669),
      secondary: Color(0xFF0EA5E9),
    ),
    AppAccentOption(
      name: 'Xanh Đại Dương',
      primary: Color(0xFF2563EB),
      secondary: Color(0xFF06B6D4),
    ),
    AppAccentOption(
      name: 'Hồng Sáng Tạo',
      primary: Color(0xFFE11D48),
      secondary: Color(0xFFF97316),
    ),
    AppAccentOption(
      name: 'Hổ Phách',
      primary: Color(0xFFD97706),
      secondary: Color(0xFFEF4444),
    ),
  ],
  AppTabId.hongguo: [
    AppAccentOption(
      name: 'Đỏ Hồng Quả',
      primary: Color(0xFFFF4D2D),
      secondary: Color(0xFFFF8A00),
    ),
    AppAccentOption(
      name: 'Cam Đốt Cháy',
      primary: Color(0xFFF97316),
      secondary: Color(0xFFEF4444),
    ),
    AppAccentOption(
      name: 'Đỏ Điện Ảnh',
      primary: Color(0xFFDC2626),
      secondary: Color(0xFFF59E0B),
    ),
    AppAccentOption(
      name: 'San Hô Đào',
      primary: Color(0xFFFB7185),
      secondary: Color(0xFFF97316),
    ),
    AppAccentOption(
      name: 'Vàng Hoàng Kim',
      primary: Color(0xFFEA580C),
      secondary: Color(0xFFEAB308),
    ),
  ],
  AppTabId.bilibili: [
    AppAccentOption(
      name: 'Hồng Bili Gốc',
      primary: Color(0xFFFB7299),
      secondary: Color(0xFF00AEEC),
    ),
    AppAccentOption(
      name: 'Xanh Bili Sky',
      primary: Color(0xFF00AEEC),
      secondary: Color(0xFFFB7299),
    ),
    AppAccentOption(
      name: 'Tím Anime',
      primary: Color(0xFF8B5CF6),
      secondary: Color(0xFFEC4899),
    ),
    AppAccentOption(
      name: 'Xanh Bạc Hà',
      primary: Color(0xFF0D9488),
      secondary: Color(0xFF00AEEC),
    ),
    AppAccentOption(
      name: 'Xanh Cobalt',
      primary: Color(0xFF0284C7),
      secondary: Color(0xFF38BDF8),
    ),
  ],
  AppTabId.history: [
    AppAccentOption(
      name: 'Tím Thư Viện',
      primary: Color(0xFF7C3AED),
      secondary: Color(0xFFF59E0B),
    ),
    AppAccentOption(
      name: 'Xanh Cổ Vịt',
      primary: Color(0xFF0F766E),
      secondary: Color(0xFF10B981),
    ),
    AppAccentOption(
      name: 'Xanh Hoàng Gia',
      primary: Color(0xFF3B82F6),
      secondary: Color(0xFF8B5CF6),
    ),
    AppAccentOption(
      name: 'Mận Hiện Đại',
      primary: Color(0xFFBE185D),
      secondary: Color(0xFFF43F5E),
    ),
    AppAccentOption(
      name: 'Vàng Nghệ',
      primary: Color(0xFFCA8A04),
      secondary: Color(0xFFEA580C),
    ),
  ],
};

class AppThemePalette extends ThemeExtension<AppThemePalette> {
  final AppThemeModePreset mode;
  final String navStyle; // 'floating' | 'docked'
  final Color studioAccent;
  final Color hongguoAccent;
  final Color bilibiliAccent;
  final Color historyAccent;

  const AppThemePalette({
    required this.mode,
    required this.navStyle,
    required this.studioAccent,
    required this.hongguoAccent,
    required this.bilibiliAccent,
    required this.historyAccent,
  });

  factory AppThemePalette.defaults() => AppThemePalette(
    mode: appThemeModes['fresh']!,
    navStyle: 'floating',
    studioAccent: const Color(0xFF5B5CF6),
    hongguoAccent: const Color(0xFFFF4D2D),
    bilibiliAccent: const Color(0xFFFB7299),
    historyAccent: const Color(0xFF7C3AED),
  );

  bool get isFloatingNav => navStyle != 'docked';
  bool get isDark => mode.isDark;
  Color get surface => mode.surface;
  Color get surfaceAlt => mode.surfaceAlt;
  Color get border => mode.border;
  Color get textPrimary => mode.textPrimary;
  Color get textSecondary => mode.textSecondary;
  Color get textMuted => mode.textMuted;
  Color get navBg => mode.navBg;

  Color backgroundFor(AppTabId tab) => mode.backgroundFor(tab);

  LinearGradient? backgroundGradientFor(AppTabId tab) {
    if (mode.id == 'fresh') {
      final colors = switch (tab) {
        AppTabId.studio => const [
            Color(0xFFDCEEFF),
            Color(0xFFEDF0FF),
            Color(0xFFFFE6F4),
          ],
        AppTabId.hongguo => const [
            Color(0xFFFFE2DA),
            Color(0xFFFFEDF2),
            Color(0xFFE7F2FF),
          ],
        AppTabId.bilibili => const [
            Color(0xFFFFE2EF),
            Color(0xFFF2EEFF),
            Color(0xFFD9F2FF),
          ],
        AppTabId.history => const [
            Color(0xFFE9E2FF),
            Color(0xFFFFE8F5),
            Color(0xFFDDF1FF),
          ],
        AppTabId.settings => const [
            Color(0xFFDCEEFF),
            Color(0xFFF3EBFF),
            Color(0xFFFFE5F2),
          ],
      };
      return LinearGradient(
        colors: colors,
        stops: const [0.0, 0.52, 1.0],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
    }
    if (mode.id == 'warm') {
      return const LinearGradient(
        colors: [
          Color(0xFFFDF2E2),
          Color(0xFFFAF0E6),
          Color(0xFFFFECE5),
        ],
        stops: [0.0, 0.55, 1.0],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
    }
    return null;
  }

  AppAccentOption accentOptionFor(AppTabId tab) {
    final key = tab == AppTabId.settings ? AppTabId.studio : tab;
    final storedPrimary = switch (key) {
      AppTabId.studio => studioAccent,
      AppTabId.hongguo => hongguoAccent,
      AppTabId.bilibili => bilibiliAccent,
      AppTabId.history => historyAccent,
      AppTabId.settings => studioAccent,
    };
    final options = appTabAccentOptions[key]!;
    for (final opt in options) {
      if (opt.primary.toARGB32() == storedPrimary.toARGB32()) {
        return opt;
      }
    }
    return AppAccentOption(
      name: 'Tùy chỉnh',
      primary: storedPrimary,
      secondary: options.first.secondary,
    );
  }

  Color accentFor(AppTabId tab) => accentOptionFor(tab).primary;
  Color secondaryFor(AppTabId tab) => accentOptionFor(tab).secondary;

  Color onColor(Color bg) =>
      bg.computeLuminance() > 0.56 ? Colors.black : Colors.white;

  /// Đảm bảo chữ màu nhấn trên nền sáng đủ độ tương phản, không bị chói mờ.
  Color readableAccent(Color color) {
    if (isDark) return color;
    final hsl = HSLColor.fromColor(color);
    if (hsl.lightness <= 0.42) return color;
    return hsl
        .withLightness((hsl.lightness - 0.14).clamp(0.32, 0.42))
        .withSaturation((hsl.saturation + 0.06).clamp(0.0, 1.0))
        .toColor();
  }

  /// Decoration dùng chung cho modal bottom sheet theo nền hiện tại của tab.
  BoxDecoration sheetDecorationFor(AppTabId tab, {double radius = 24}) {
    final gradient = backgroundGradientFor(tab);
    return BoxDecoration(
      color: gradient == null ? surface : null,
      gradient: gradient,
      borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
    );
  }

  List<BoxShadow> get cardShadows {
    if (mode.id == 'amoled') {
      return const <BoxShadow>[];
    }
    if (isDark) {
      return [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.36),
          blurRadius: 16,
          offset: const Offset(0, 6),
        ),
      ];
    }
    return [
      BoxShadow(
        color: const Color(0xFF3B5998).withValues(alpha: 0.08),
        blurRadius: 18,
        offset: const Offset(0, 6),
      ),
    ];
  }

  double bottomContentPadding({double extra = 16}) =>
      (isFloatingNav ? 88.0 : 20.0) + extra;

  static AppThemePalette of(BuildContext context) {
    return Theme.of(context).extension<AppThemePalette>() ??
        AppThemeController.instance.palette;
  }

  @override
  AppThemePalette copyWith({
    AppThemeModePreset? mode,
    String? navStyle,
    Color? studioAccent,
    Color? hongguoAccent,
    Color? bilibiliAccent,
    Color? historyAccent,
  }) {
    return AppThemePalette(
      mode: mode ?? this.mode,
      navStyle: navStyle ?? this.navStyle,
      studioAccent: studioAccent ?? this.studioAccent,
      hongguoAccent: hongguoAccent ?? this.hongguoAccent,
      bilibiliAccent: bilibiliAccent ?? this.bilibiliAccent,
      historyAccent: historyAccent ?? this.historyAccent,
    );
  }

  @override
  AppThemePalette lerp(ThemeExtension<AppThemePalette>? other, double t) {
    if (other is! AppThemePalette) return this;
    return AppThemePalette(
      mode: t < 0.5 ? mode : other.mode,
      navStyle: t < 0.5 ? navStyle : other.navStyle,
      studioAccent: Color.lerp(studioAccent, other.studioAccent, t)!,
      hongguoAccent: Color.lerp(hongguoAccent, other.hongguoAccent, t)!,
      bilibiliAccent: Color.lerp(bilibiliAccent, other.bilibiliAccent, t)!,
      historyAccent: Color.lerp(historyAccent, other.historyAccent, t)!,
    );
  }
}

class AppThemeController extends ChangeNotifier {
  AppThemeController._();

  static final AppThemeController instance = AppThemeController._();

  AppThemePalette _palette = AppThemePalette.defaults();

  AppThemePalette get palette => _palette;

  SystemUiOverlayStyle get systemOverlayStyle {
    final dark = _palette.isDark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      statusBarBrightness: dark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: _palette.backgroundFor(AppTabId.studio),
      systemNavigationBarIconBrightness:
          dark ? Brightness.light : Brightness.dark,
    );
  }

  void _applySystemOverlay() {
    try {
      SystemChrome.setSystemUIOverlayStyle(systemOverlayStyle);
    } catch (_) {}
  }

  Future<void> loadFromSettings([SettingsRepository? settings]) async {
    final s = settings ?? await SettingsRepository.getInstance();
    final mode = appThemeModes[s.uiThemeMode] ?? appThemeModes['fresh']!;
    final navStyle = s.uiNavStyle == 'docked' ? 'docked' : 'floating';
    _palette = AppThemePalette(
      mode: mode,
      navStyle: navStyle,
      studioAccent: Color(s.uiAccentStudio),
      hongguoAccent: Color(s.uiAccentHongguo),
      bilibiliAccent: Color(s.uiAccentBilibili),
      historyAccent: Color(s.uiAccentHistory),
    );
    _applySystemOverlay();
    notifyListeners();
  }

  Future<void> setThemeMode(String modeId) async {
    final mode = appThemeModes[modeId];
    if (mode == null || _palette.mode.id == mode.id) return;
    _palette = _palette.copyWith(mode: mode);
    _applySystemOverlay();
    notifyListeners();
    try {
      final s = await SettingsRepository.getInstance();
      s.uiThemeMode = mode.id;
    } catch (_) {}
  }

  Future<void> setNavStyle(String style) async {
    final normalized = style == 'docked' ? 'docked' : 'floating';
    if (_palette.navStyle == normalized) return;
    _palette = _palette.copyWith(navStyle: normalized);
    notifyListeners();
    try {
      final s = await SettingsRepository.getInstance();
      s.uiNavStyle = normalized;
    } catch (_) {}
  }

  Future<void> setTabAccent(AppTabId tab, Color primary) async {
    final key = tab == AppTabId.settings ? AppTabId.studio : tab;
    switch (key) {
      case AppTabId.studio:
        _palette = _palette.copyWith(studioAccent: primary);
      case AppTabId.hongguo:
        _palette = _palette.copyWith(hongguoAccent: primary);
      case AppTabId.bilibili:
        _palette = _palette.copyWith(bilibiliAccent: primary);
      case AppTabId.history:
        _palette = _palette.copyWith(historyAccent: primary);
      case AppTabId.settings:
        break;
    }
    notifyListeners();
    try {
      final s = await SettingsRepository.getInstance();
      final val = primary.toARGB32();
      switch (key) {
        case AppTabId.studio:
          s.uiAccentStudio = val;
        case AppTabId.hongguo:
          s.uiAccentHongguo = val;
        case AppTabId.bilibili:
          s.uiAccentBilibili = val;
        case AppTabId.history:
          s.uiAccentHistory = val;
        case AppTabId.settings:
          break;
      }
    } catch (_) {}
  }

  Future<void> resetToDefaults() async {
    _palette = AppThemePalette.defaults();
    _applySystemOverlay();
    notifyListeners();
    try {
      final s = await SettingsRepository.getInstance();
      s.uiThemeMode = 'fresh';
      s.uiNavStyle = 'floating';
      s.uiAccentStudio = 0xFF5B5CF6;
      s.uiAccentHongguo = 0xFFFF4D2D;
      s.uiAccentBilibili = 0xFFFB7299;
      s.uiAccentHistory = 0xFF7C3AED;
    } catch (_) {}
  }

  void resetForTesting() {
    _palette = AppThemePalette.defaults();
  }
}

ThemeData buildAppTheme([AppThemePalette? palette]) {
  final p = palette ?? AppThemeController.instance.palette;
  final studioAccent = p.accentFor(AppTabId.studio);
  final studioSecondary = p.secondaryFor(AppTabId.studio);
  final brightness = p.isDark ? Brightness.dark : Brightness.light;
  final bg = p.backgroundFor(AppTabId.studio);

  final colorScheme = p.isDark
      ? ColorScheme.dark(
          primary: studioAccent,
          onPrimary: p.onColor(studioAccent),
          secondary: studioSecondary,
          onSecondary: p.onColor(studioSecondary),
          surface: p.surface,
          onSurface: p.textPrimary,
          outline: p.border,
        )
      : ColorScheme.light(
          primary: studioAccent,
          onPrimary: p.onColor(studioAccent),
          secondary: studioSecondary,
          onSecondary: p.onColor(studioSecondary),
          surface: p.surface,
          onSurface: p.textPrimary,
          outline: p.border,
        );

  return ThemeData(
    brightness: brightness,
    scaffoldBackgroundColor: bg,
    primaryColor: studioAccent,
    colorScheme: colorScheme,
    dividerColor: p.border,
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      foregroundColor: p.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: p.isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: p.isDark ? Brightness.dark : Brightness.light,
      ),
      iconTheme: IconThemeData(color: p.textPrimary),
      titleTextStyle: TextStyle(
        color: p.textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.bold,
      ),
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: p.border, width: 1),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        color: p.textPrimary,
        fontSize: 17,
        fontWeight: FontWeight.bold,
      ),
      contentTextStyle: TextStyle(
        color: p.textSecondary,
        fontSize: 13.5,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return Colors.white;
        return p.isDark ? const Color(0xFFCBD5E1) : Colors.white;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return studioAccent;
        return p.isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1);
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return Colors.transparent;
        return p.isDark ? const Color(0xFF475569) : const Color(0xFF94A3B8);
      }),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.isDark ? p.surfaceAlt : const Color(0xFF1E293B),
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
      },
    ),
    useMaterial3: true,
    extensions: <ThemeExtension<dynamic>>[p],
  );
}

/// Theme tối điện ảnh riêng cho VideoPlayerScreen & HongguoFeedScreen
/// giúp xem video luôn rõ nét, không bị đổi sang nền sáng.
ThemeData buildDarkCinemaTheme() {
  final midnight = AppThemePalette(
    mode: appThemeModes['midnight']!,
    navStyle: 'docked',
    studioAccent: AppColors.primaryEmerald,
    hongguoAccent: const Color(0xFFFF5A36),
    bilibiliAccent: const Color(0xFFFB7299),
    historyAccent: AppColors.primaryEmerald,
  );
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: Colors.black,
    primaryColor: AppColors.primaryEmerald,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.primaryEmerald,
      secondary: AppColors.primaryEmeraldDark,
      surface: AppColors.darkSurface,
    ),
    cardTheme: CardThemeData(
      color: AppColors.darkSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.cardBorder, width: 1),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
      },
    ),
    useMaterial3: true,
    extensions: <ThemeExtension<dynamic>>[midnight],
  );
}

class AppTabBackdrop extends StatelessWidget {
  final AppTabId tab;
  final Widget child;

  const AppTabBackdrop({
    super.key,
    required this.tab,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppThemePalette.of(context);
    final gradient = palette.backgroundGradientFor(tab);
    final overlay = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness:
          palette.isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness:
          palette.isDark ? Brightness.dark : Brightness.light,
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlay,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: gradient == null ? palette.backgroundFor(tab) : null,
          gradient: gradient,
        ),
        child: child,
      ),
    );
  }
}
