import 'package:flutter/material.dart';

import '../../data/model/subtitle_document.dart';
import '../home/home_screen.dart';
import '../theme/app_theme.dart';
import '../tts/tts_studio_screen.dart';

class StudioScreen extends StatefulWidget {
  final VoidCallback? onNavigateToSettings;

  const StudioScreen({
    super.key,
    this.onNavigateToSettings,
  });

  @override
  State<StudioScreen> createState() => StudioScreenState();
}

class StudioScreenState extends State<StudioScreen> {
  final GlobalKey<HomeScreenState> _homeKey = GlobalKey<HomeScreenState>();
  int _subTabIndex = 0; // 0: Tạo Phụ Đề, 1: Lồng Tiếng AI

  SubtitleDocument? _currentDoc;
  String? _currentVideoPath;
  String? _currentTitle;

  /// Nạp video từ nguồn bên ngoài (ví dụ từ Hồng Quả sang)
  void loadOnlineVideo(String url, {String? title}) {
    setState(() {
      _subTabIndex = 0;
    });
    _homeKey.currentState?.loadOnlineVideo(url, title: title);
  }

  /// Mở phụ đề trong tab Lồng Tiếng AI (ví dụ từ Lịch Sử sang)
  void openInTts(String videoPath, SubtitleDocument doc, {String? title}) {
    setState(() {
      _currentDoc = doc;
      _currentVideoPath = videoPath;
      _currentTitle = title;
      _subTabIndex = 1;
    });
  }

  /// Chuyển đổi sang tab Tạo Phụ Đề
  void switchToSubtitles() {
    setState(() {
      _subTabIndex = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        backgroundColor: AppColors.darkBackground,
        elevation: 0,
        titleSpacing: 16,
        title: const Row(
          children: [
            Icon(Icons.movie_rounded, color: AppColors.primaryEmerald, size: 24),
            SizedBox(width: 8),
            Text(
              'CapSub AI Studio',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: Colors.white,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Colors.white70),
            tooltip: 'Cài đặt',
            onPressed: () {
              if (widget.onNavigateToSettings != null) {
                widget.onNavigateToSettings!();
              } else {
                Navigator.pushNamed(context, '/settings');
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Sub-Tabs Switcher: [ Tạo Phụ Đề ] vs [ Lồng Tiếng AI ]
          Container(
            margin: const EdgeInsets.fromLTRB(16, 2, 16, 10),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: AppColors.darkSurfaceVariant,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.08),
                width: 0.8,
              ),
            ),
            child: Row(
              children: [
                // Sub-Tab 0: Tạo Phụ Đề
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      if (_subTabIndex != 0) {
                        setState(() => _subTabIndex = 0);
                      }
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: _subTabIndex == 0
                            ? AppColors.primaryEmerald
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: _subTabIndex == 0
                            ? [
                                BoxShadow(
                                  color: AppColors.primaryEmerald.withValues(alpha: 0.25),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ]
                            : null,
                      ),
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.subtitles_rounded,
                            size: 16,
                            color: _subTabIndex == 0 ? Colors.black : Colors.white60,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Tạo Phụ Đề',
                            style: TextStyle(
                              color: _subTabIndex == 0 ? Colors.black : Colors.white70,
                              fontSize: 13,
                              fontWeight: _subTabIndex == 0
                                  ? FontWeight.bold
                                  : FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // Sub-Tab 1: Lồng Tiếng AI
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      if (_subTabIndex != 1) {
                        setState(() => _subTabIndex = 1);
                      }
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: _subTabIndex == 1
                            ? AppColors.primaryEmerald
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: _subTabIndex == 1
                            ? [
                                BoxShadow(
                                  color: AppColors.primaryEmerald.withValues(alpha: 0.25),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ]
                            : null,
                      ),
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.record_voice_over_rounded,
                            size: 16,
                            color: _subTabIndex == 1 ? Colors.black : Colors.white60,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Lồng Tiếng AI',
                            style: TextStyle(
                              color: _subTabIndex == 1 ? Colors.black : Colors.white70,
                              fontSize: 13,
                              fontWeight: _subTabIndex == 1
                                  ? FontWeight.bold
                                  : FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // IndexedStack preserves the scroll position and filled inputs of both screens
          Expanded(
            child: IndexedStack(
              index: _subTabIndex,
              children: [
                HomeScreen(
                  key: _homeKey,
                  hideAppBar: true,
                  onNavigateToSettings: widget.onNavigateToSettings,
                  onProcessCompleted: (doc, videoPath, [title]) {
                    setState(() {
                      _currentDoc = doc;
                      _currentVideoPath = videoPath;
                      _currentTitle = title;
                      _subTabIndex = 1; // Tự động trượt sang Tab Lồng Tiếng AI
                    });
                  },
                ),
                TtsStudioScreen(
                  key: ValueKey(
                    'tts_${_currentVideoPath ?? ""}_${_currentDoc?.hashCode ?? 0}',
                  ),
                  hideAppBar: true,
                  initialDoc: _currentDoc,
                  initialVideoPath: _currentVideoPath,
                  initialTitle: _currentTitle,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
