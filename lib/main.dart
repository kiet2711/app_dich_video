import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'data/repository/settings_repository.dart';
import 'domain/font/custom_font_manager.dart';
import 'domain/media/hongguo/hongguo_feed_warmup_service.dart';
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
  runApp(const KsubApp());
}

void dismissAppKeyboard() {
  FocusManager.instance.primaryFocus?.unfocus();
  unawaited(
    SystemChannels.textInput
        .invokeMethod<void>('TextInput.hide')
        .catchError((_) {}),
  );
}

class _KeyboardDismissNavigatorObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    // Clear focus khỏi màn hình cũ trước khi mở sheet/dialog/route mới để khi đóng lại không tự bật bàn phím cũ.
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    dismissAppKeyboard();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      dismissAppKeyboard();
    });
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    dismissAppKeyboard();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    dismissAppKeyboard();
  }
}

class _GlobalKeyboardCoordinator extends StatefulWidget {
  final Widget child;

  const _GlobalKeyboardCoordinator({required this.child});

  @override
  State<_GlobalKeyboardCoordinator> createState() =>
      _GlobalKeyboardCoordinatorState();
}

class _GlobalKeyboardCoordinatorState extends State<_GlobalKeyboardCoordinator>
    with WidgetsBindingObserver {
  double _lastBottomViewInset = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastBottomViewInset = _currentBottomInset();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  double _currentBottomInset() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return 0;
    return views.first.viewInsets.bottom;
  }

  @override
  void didChangeMetrics() {
    final nextBottom = _currentBottomInset();
    if (_lastBottomViewInset > 0 && nextBottom == 0) {
      // Đồng bộ unfocus khi người dùng đóng bàn phím từ thanh điều hướng/nút Back Android.
      FocusManager.instance.primaryFocus?.unfocus();
    }
    _lastBottomViewInset = nextBottom;
  }

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        EditableTextTapOutsideIntent:
            CallbackAction<EditableTextTapOutsideIntent>(
              onInvoke: (intent) {
                intent.focusNode.unfocus();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (FocusManager.instance.primaryFocus == null) {
                    unawaited(
                      SystemChannels.textInput
                          .invokeMethod<void>('TextInput.hide')
                          .catchError((_) {}),
                    );
                  }
                });
                return null;
              },
            ),
      },
      child: widget.child,
    );
  }
}

class KsubApp extends StatefulWidget {
  final bool skipSplash;
  final Future<void> Function()? onInitialize;

  const KsubApp({
    super.key,
    this.skipSplash = false,
    this.onInitialize,
  });

  @override
  State<KsubApp> createState() => _KsubAppState();
}

class _KsubAppState extends State<KsubApp> {
  final NavigatorObserver _keyboardNavigatorObserver =
      _KeyboardDismissNavigatorObserver();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppThemeController.instance,
      builder: (context, _) {
        final palette = AppThemeController.instance.palette;
        return MaterialApp(
          title: 'Ksub',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(palette),
          navigatorObservers: [_keyboardNavigatorObserver],
          builder: (context, child) => _GlobalKeyboardCoordinator(
            child: child ?? const SizedBox.shrink(),
          ),
          routes: {
            '/': (context) => widget.skipSplash
                ? const MainNavigation()
                : AppStartupSplash(
                    onInitialize: widget.onInitialize ?? _initializeAppServices,
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
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(HongguoFeedSessionCache.instance.warmupOnAppStart());
    });
  }

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
            final hasKeyboardOrFocus =
                MediaQuery.viewInsetsOf(context).bottom > 0 ||
                FocusManager.instance.primaryFocus != null;
            if (hasKeyboardOrFocus) {
              dismissAppKeyboard();
              return;
            }
            if (Platform.isAndroid && !MediaStorage.shouldSuppressBackMinimize) {
              dismissAppKeyboard();
              const MethodChannel('com.ksub.app/media')
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
                  IndexedStack(
                    index: _currentIndex,
                    children: [
                      for (var i = 0; i < screens.length; i++)
                        ExcludeFocus(
                          excluding: _currentIndex != i,
                          child: screens[i],
                        ),
                    ],
                  ),
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
    final isDark = palette.isDark;
    final topGlassColor = Color.lerp(
      palette.navBg,
      Colors.white,
      isDark ? 0.14 : 0.48,
    )!.withValues(alpha: isDark ? 0.72 : 0.80);
    final midGlassColor = palette.navBg.withValues(alpha: isDark ? 0.56 : 0.62);
    final bottomGlassColor = palette.navBg.withValues(
      alpha: isDark ? 0.68 : 0.74,
    );

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
                color: Colors.black.withValues(alpha: isDark ? 0.52 : 0.11),
                blurRadius: 28,
                offset: const Offset(0, 12),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.24 : 0.05),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(32),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
              child: CustomPaint(
                foregroundPainter: _LiquidGlassRimPainter(
                  isDark: isDark,
                  radius: 32,
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        topGlassColor,
                        midGlassColor,
                        bottomGlassColor,
                      ],
                      stops: const [0.0, 0.48, 1.0],
                    ),
                    borderRadius: BorderRadius.circular(32),
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        top: 1,
                        left: 22,
                        right: 22,
                        height: 18,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(24),
                              ),
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.white.withValues(
                                    alpha: isDark ? 0.10 : 0.42,
                                  ),
                                  Colors.white.withValues(alpha: 0.0),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 6,
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
                                    dismissAppKeyboard();
                                    if (_currentIndex != idx) {
                                      HapticFeedback.selectionClick();
                                      setState(() => _currentIndex = idx);
                                    }
                                  },
                                  borderRadius: BorderRadius.circular(26),
                                  splashColor: accent.withValues(alpha: 0.14),
                                  highlightColor: Colors.transparent,
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 240),
                                    curve: Curves.easeOutCubic,
                                    height: double.infinity,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      gradient: isSelected
                                          ? LinearGradient(
                                              begin: Alignment.topLeft,
                                              end: Alignment.bottomRight,
                                              colors: [
                                                Color.lerp(
                                                  Colors.white,
                                                  accent,
                                                  isDark ? 0.55 : 0.25,
                                                )!.withValues(
                                                  alpha: isDark ? 0.24 : 0.50,
                                                ),
                                                accent.withValues(
                                                  alpha: isDark ? 0.14 : 0.13,
                                                ),
                                              ],
                                            )
                                          : null,
                                      borderRadius: BorderRadius.circular(26),
                                      border: isSelected
                                          ? Border.all(
                                              color: isDark
                                                  ? Colors.white.withValues(
                                                      alpha: 0.18,
                                                    )
                                                  : Colors.white.withValues(
                                                      alpha: 0.84,
                                                    ),
                                              width: 1,
                                            )
                                          : null,
                                      boxShadow: isSelected
                                          ? [
                                              BoxShadow(
                                                color: accent.withValues(
                                                  alpha: isDark ? 0.20 : 0.14,
                                                ),
                                                blurRadius: 10,
                                                offset: const Offset(0, 2),
                                              ),
                                            ]
                                          : null,
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          it.icon,
                                          size: 20,
                                          color: isSelected
                                              ? accent
                                              : palette.textMuted,
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
                    ],
                  ),
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
                        dismissAppKeyboard();
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

/// Vẽ viền sáng phản chiếu đa hướng (specular rim) cho thanh điều hướng kính lỏng.
class _LiquidGlassRimPainter extends CustomPainter {
  final bool isDark;
  final double radius;

  const _LiquidGlassRimPainter({required this.isDark, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    const strokeWidth = 1.15;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(strokeWidth / 2),
      Radius.circular(radius - strokeWidth / 2),
    );

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [
                Colors.white.withValues(alpha: 0.34),
                Colors.white.withValues(alpha: 0.09),
                Colors.white.withValues(alpha: 0.04),
                Colors.white.withValues(alpha: 0.16),
              ]
            : [
                Colors.white.withValues(alpha: 0.94),
                Colors.white.withValues(alpha: 0.45),
                Colors.black.withValues(alpha: 0.07),
                Colors.white.withValues(alpha: 0.72),
              ],
        stops: const [0.0, 0.36, 0.68, 1.0],
      ).createShader(rect);

    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant _LiquidGlassRimPainter oldDelegate) {
    return oldDelegate.isDark != isDark || oldDelegate.radius != radius;
  }
}
