import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'data/repository/settings_repository.dart';
import 'domain/font/custom_font_manager.dart';
import 'domain/media/media_storage.dart';
import 'player/app_player_controller.dart';
import 'player/global_player_manager.dart';
import 'player/pip_manager.dart';
import 'ui/bilibili/bilibili_screen.dart';
import 'ui/history/history_screen.dart';
import 'ui/hongguo/hongguo_screen.dart';
import 'ui/player/global_player_overlay.dart';
import 'ui/settings/settings_screen.dart';
import 'ui/splash/app_startup_splash.dart';
import 'ui/storage/storage_cleaner_screen.dart';
import 'ui/studio/studio_screen.dart';
import 'ui/theme/app_theme.dart';

Future<void> _initializeAppServices() async {
  // Giới hạn bộ nhớ đệm ảnh trong RAM để tránh tràn bộ nhớ khi cuộn danh sách phim
  PaintingBinding.instance.imageCache.maximumSizeBytes = 40 * 1024 * 1024; // 40 MB max
  PaintingBinding.instance.imageCache.maximumSize = 120; // Tối đa 120 ảnh
  MediaKit.ensureInitialized();
  await AppPlayerController.ensurePlatformDetected();
  PipManager.initialize();
  final settings = await SettingsRepository.getInstance();
  await AppThemeController.instance.loadFromSettings(settings);
  await CustomFontManager.loadAllSavedFonts(settings);
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    AppThemeController.instance.systemOverlayStyle,
  );
  runApp(const CapSubApp());
}

class CapSubApp extends StatelessWidget {
  final bool skipSplash;
  final Future<void> Function()? onInitialize;

  const CapSubApp({
    super.key,
    this.skipSplash = false,
    this.onInitialize,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppThemeController.instance,
      builder: (context, _) {
        final palette = AppThemeController.instance.palette;
        return MaterialApp(
          title: 'CapSub AI Studio',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(palette),
          routes: {
            '/': (context) => skipSplash
                ? const MainNavigation()
                : AppStartupSplash(
                    onInitialize: onInitialize ?? _initializeAppServices,
                    homeBuilder: (_) => const MainNavigation(),
                  ),
            '/settings': (context) => const SettingsScreen(),
            '/storage-cleaner': (context) => const StorageCleanerScreen(),
          },
        );
      },
    );
  }
}

class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _BottomNavItem {
  final AppTabId tabId;
  final IconData icon;
  final String label;

  const _BottomNavItem({
    required this.tabId,
    required this.icon,
    required this.label,
  });
}

class _MainNavigationState extends State<MainNavigation> {
  final GlobalKey<StudioScreenState> _studioKey =
      GlobalKey<StudioScreenState>();
  int _currentIndex = 0;

  static const _tabs = [
    AppTabId.studio,
    AppTabId.hongguo,
    AppTabId.bilibili,
    AppTabId.history,
  ];

  @override
  Widget build(BuildContext context) {
    final screens = [
      // Tab 1: Studio (Gom Tạo Phụ Đề & Lồng Tiếng AI)
      StudioScreen(
        key: _studioKey,
        onNavigateToSettings: () => Navigator.pushNamed(context, '/settings'),
      ),
      // Tab 2: Phim Hồng Quả
      HongguoScreen(
        onStartTranslation: (videoUrl, title, durationMs) {
          setState(() {
            _currentIndex = 0; // Chuyển về Tab Studio
          });
          _studioKey.currentState?.loadOnlineVideo(videoUrl, title: title);
        },
      ),
      // Tab 3: Bilibili
      const BilibiliScreen(),
      // Tab 4: Lịch Sử
      HistoryScreen(
        onOpenInTts: (videoPath, doc, [title]) {
          setState(() {
            _currentIndex = 0; // Chuyển về Tab Studio
          });
          _studioKey.currentState?.openInTts(videoPath, doc, title: title);
        },
      ),
    ];

    return ListenableBuilder(
      listenable: Listenable.merge([
        GlobalPlayerManager.instance,
        AppThemeController.instance,
      ]),
      builder: (context, _) {
        final palette = AppThemePalette.of(context);
        final isFullScreen = GlobalPlayerManager.instance.isFullScreen;
        final activeTabId = _tabs[_currentIndex.clamp(0, _tabs.length - 1)];

        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (Platform.isAndroid && !MediaStorage.shouldSuppressBackMinimize) {
              const MethodChannel('com.capcut.capsub/media')
                  .invokeMethod('moveToBack');
            }
          },
          child: AppTabBackdrop(
            tab: activeTabId,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              extendBody: palette.isFloatingNav && !isFullScreen,
              body: Stack(
                children: [
                  IndexedStack(index: _currentIndex, children: screens),
                  const GlobalPlayerOverlay(),
                ],
              ),
              bottomNavigationBar:
                  isFullScreen ? null : _buildBottomBar(context, palette),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBottomBar(BuildContext context, AppThemePalette palette) {
    const items = [
      _BottomNavItem(
        tabId: AppTabId.studio,
        icon: Icons.auto_awesome_rounded,
        label: 'Studio',
      ),
      _BottomNavItem(
        tabId: AppTabId.hongguo,
        icon: Icons.play_circle_filled_rounded,
        label: 'Hồng Quả',
      ),
      _BottomNavItem(
        tabId: AppTabId.bilibili,
        icon: Icons.tv_rounded,
        label: 'Bilibili',
      ),
      _BottomNavItem(
        tabId: AppTabId.history,
        icon: Icons.schedule_rounded,
        label: 'Lịch Sử',
      ),
    ];

    if (palette.isFloatingNav) {
      return _buildFloatingPillNav(palette, items);
    }
    return _buildDockedNav(palette, items);
  }

  Widget _buildFloatingPillNav(
    AppThemePalette palette,
    List<_BottomNavItem> items,
  ) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
        child: Container(
          height: 60,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(32),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: palette.isDark ? 0.45 : 0.14,
                ),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(32),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                decoration: BoxDecoration(
                  color: palette.navBg,
                  borderRadius: BorderRadius.circular(32),
                  border: Border.all(color: palette.border, width: 1),
                ),
                child: Row(
                  children: List.generate(items.length, (idx) {
                    final it = items[idx];
                    final isSelected = _currentIndex == idx;
                    final accent = palette.accentFor(it.tabId);
                    return Expanded(
                      flex: isSelected ? 14 : 10,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            if (_currentIndex != idx) {
                              HapticFeedback.selectionClick();
                              setState(() => _currentIndex = idx);
                            }
                          },
                          borderRadius: BorderRadius.circular(26),
                          splashColor: accent.withValues(alpha: 0.14),
                          highlightColor: Colors.transparent,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            height: double.infinity,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? accent.withValues(alpha: 0.14)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(26),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  it.icon,
                                  size: 20,
                                  color: isSelected ? accent : palette.textMuted,
                                ),
                                if (isSelected) ...[
                                  const SizedBox(width: 5),
                                  Flexible(
                                    child: Text(
                                      it.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w800,
                                        color: accent,
                                        letterSpacing: -0.2,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDockedNav(
    AppThemePalette palette,
    List<_BottomNavItem> items,
  ) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          decoration: BoxDecoration(
            color: palette.navBg,
            border: Border(
              top: BorderSide(color: palette.border, width: 0.9),
            ),
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 62,
              child: Row(
                children: List.generate(items.length, (idx) {
                  final it = items[idx];
                  final isSelected = _currentIndex == idx;
                  final accent = palette.accentFor(it.tabId);
                  return Expanded(
                    child: InkWell(
                      onTap: () {
                        if (_currentIndex != idx) {
                          HapticFeedback.selectionClick();
                          setState(() => _currentIndex = idx);
                        }
                      },
                      splashColor: accent.withValues(alpha: 0.12),
                      highlightColor: Colors.transparent,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? accent.withValues(alpha: 0.14)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Icon(
                              it.icon,
                              size: 21,
                              color: isSelected ? accent : palette.textMuted,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            it.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: isSelected
                                  ? FontWeight.w800
                                  : FontWeight.w500,
                              color:
                                  isSelected ? accent : palette.textSecondary,
                              letterSpacing: -0.1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
