import 'package:flutter/material.dart';

class AppColors {
  static const darkBackground = Color(0xFF0F1015);
  static const darkSurface = Color(0xFF181920);
  static const darkSurfaceVariant = Color(0xFF22232D);
  static const cardBorder = Color(0xFF2D2F3E);

  static const primaryEmerald = Color(0xFF00E676);
  static const primaryEmeraldDark = Color(0xFF00B0FF);
  static const accentGold = Color(0xFFFFD54F);

  static const textPrimary = Color(0xFFEDEDED);
  static const textSecondary = Color(0xFFA0A3B1);
  static const textMuted = Color(0xFF6B6E7D);
}

ThemeData buildAppTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.darkBackground,
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
    useMaterial3: true,
  );
}
