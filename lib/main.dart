import 'package:flutter/material.dart';

import 'data/model/subtitle_document.dart';
import 'ui/history/history_screen.dart';
import 'ui/home/home_screen.dart';
import 'ui/hongguo/hongguo_screen.dart';
import 'ui/settings/settings_screen.dart';
import 'ui/theme/app_theme.dart';
import 'ui/tts/tts_studio_screen.dart';

import 'data/repository/settings_repository.dart';
import 'domain/font/custom_font_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
      },
    );
  }
}

class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  final GlobalKey<HomeScreenState> _homeKey = GlobalKey<HomeScreenState>();
  int _currentIndex = 0;
  SubtitleDocument? _latestDoc;
  String? _latestVideoPath;

  @override
  Widget build(BuildContext context) {
    final screens = [
      HomeScreen(
        key: _homeKey,
        onNavigateToSettings: () => Navigator.pushNamed(context, '/settings'),
        onProcessCompleted: (doc, videoPath) {
          setState(() {
            _latestDoc = doc;
            _latestVideoPath = videoPath;
            _currentIndex = 2; // Tự động chuyển sang Tab Lồng Tiếng AI
          });
        },
      ),
      HongguoScreen(
        onStartTranslation: (videoUrl, title, durationMs) {
          setState(() {
            _currentIndex = 0; // Chuyển về Tab Tạo Phụ Đề
          });
          _homeKey.currentState?.loadOnlineVideo(videoUrl, title: title);
        },
      ),
      TtsStudioScreen(
        key: ValueKey('tts_${_latestVideoPath ?? ""}_${_latestDoc?.hashCode ?? 0}'),
        initialDoc: _latestDoc,
        initialVideoPath: _latestVideoPath,
      ),
      HistoryScreen(
        onOpenInTts: (videoPath, doc) {
          setState(() {
            _latestDoc = doc;
            _latestVideoPath = videoPath;
            _currentIndex = 2;
          });
        },
      ),
    ];

    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: screens),
      bottomNavigationBar: NavigationBar(
        backgroundColor: AppColors.darkSurface,
        indicatorColor: AppColors.primaryEmerald.withValues(alpha: 0.2),
        selectedIndex: _currentIndex,
        onDestinationSelected: (idx) {
          setState(() {
            _currentIndex = idx;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.auto_awesome, color: Colors.grey),
            selectedIcon: Icon(
              Icons.auto_awesome,
              color: AppColors.primaryEmerald,
            ),
            label: 'Tạo Phụ Đề',
          ),
          NavigationDestination(
            icon: Icon(Icons.movie_filter_rounded, color: Colors.grey),
            selectedIcon: Icon(
              Icons.movie_filter_rounded,
              color: AppColors.primaryEmerald,
            ),
            label: 'Phim Hồng Quả',
          ),
          NavigationDestination(
            icon: Icon(Icons.record_voice_over, color: Colors.grey),
            selectedIcon: Icon(
              Icons.record_voice_over,
              color: AppColors.primaryEmerald,
            ),
            label: 'Lồng Tiếng AI',
          ),
          NavigationDestination(
            icon: Icon(Icons.video_library, color: Colors.grey),
            selectedIcon: Icon(
              Icons.video_library,
              color: AppColors.primaryEmerald,
            ),
            label: 'Lịch Sử & Player',
          ),
        ],
      ),
    );
  }
}
