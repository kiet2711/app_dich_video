import 'package:flutter/material.dart';

import 'ui/bilibili/bilibili_screen.dart';
import 'ui/history/history_screen.dart';
import 'ui/hongguo/hongguo_screen.dart';
import 'ui/settings/settings_screen.dart';
import 'ui/storage/storage_cleaner_screen.dart';
import 'ui/studio/studio_screen.dart';
import 'ui/theme/app_theme.dart';

import 'data/repository/settings_repository.dart';
import 'domain/font/custom_font_manager.dart';
import 'player/global_player_manager.dart';
import 'player/pip_manager.dart';
import 'package:media_kit/media_kit.dart';
import 'ui/player/global_player_overlay.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  PipManager.initialize();
  final settings = await SettingsRepository.getInstance();
  await CustomFontManager.loadAllSavedFonts(settings);
  runApp(const CapSubApp());
}

class CapSubApp extends StatelessWidget {
  const CapSubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CapSub AI Studio',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      routes: {
        '/': (context) => const MainNavigation(),
        '/settings': (context) => const SettingsScreen(),
        '/storage-cleaner': (context) => const StorageCleanerScreen(),
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
  final IconData icon;
  final String label;
  final Color activeColor;

  const _BottomNavItem({
    required this.icon,
    required this.label,
    required this.activeColor,
  });
}

class _MainNavigationState extends State<MainNavigation> {
  final GlobalKey<StudioScreenState> _studioKey =
      GlobalKey<StudioScreenState>();
  int _currentIndex = 0;

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
      listenable: GlobalPlayerManager.instance,
      builder: (context, _) {
        final isFullScreen = GlobalPlayerManager.instance.isFullScreen;
        return Scaffold(
          body: Stack(
            children: [
              IndexedStack(index: _currentIndex, children: screens),
              const GlobalPlayerOverlay(),
            ],
          ),
          bottomNavigationBar: isFullScreen ? null : _buildBottomBar(context),
        );
      },
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    const items = [
      _BottomNavItem(
        icon: Icons.auto_awesome_rounded,
        label: 'Studio',
        activeColor: AppColors.primaryEmerald,
      ),
      _BottomNavItem(
        icon: Icons.movie_filter_rounded,
        label: 'Hồng Quả',
        activeColor: AppColors.primaryEmerald,
      ),
      _BottomNavItem(
        icon: Icons.tv_rounded,
        label: 'Bilibili',
        activeColor: Color(0xFF00AEEC),
      ),
      _BottomNavItem(
        icon: Icons.video_library_rounded,
        label: 'Lịch Sử',
        activeColor: AppColors.primaryEmerald,
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        border: Border(
          top: BorderSide(
            color: Colors.white.withValues(alpha: 0.08),
            width: 0.8,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(
            children: List.generate(items.length, (idx) {
              final it = items[idx];
              final isSelected = _currentIndex == idx;
              return Expanded(
                child: InkWell(
                  onTap: () {
                    if (_currentIndex != idx) {
                      setState(() => _currentIndex = idx);
                    }
                  },
                  splashColor: it.activeColor.withValues(alpha: 0.12),
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
                              ? it.activeColor.withValues(alpha: 0.16)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          it.icon,
                          size: 21,
                          color: isSelected ? it.activeColor : Colors.white38,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        it.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.w500,
                          color: isSelected ? it.activeColor : Colors.white60,
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
    );
  }
}
