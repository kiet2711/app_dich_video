import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.studio);
    final secondary = palette.secondaryFor(AppTabId.studio);

    return AppTabBackdrop(
      tab: AppTabId.studio,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // Header kiểu CapCut / Creative Studio
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [accent, secondary],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: accent.withValues(alpha: 0.28),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.auto_awesome_rounded,
                      color: Colors.white,
                      size: 21,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'CapSub Studio',
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: 16.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          'Phụ đề & Lồng tiếng AI',
                          style: TextStyle(
                            color: palette.textMuted,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Material(
                    color: palette.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(color: palette.border),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        if (widget.onNavigateToSettings != null) {
                          widget.onNavigateToSettings!();
                        } else {
                          Navigator.pushNamed(context, '/settings');
                        }
                      },
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: Icon(
                          Icons.settings_rounded,
                          color: palette.textSecondary,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Segmented Pill Switcher: [ Tạo Phụ Đề ] vs [ Lồng Tiếng AI ]
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: palette.surfaceAlt,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: palette.border),
              ),
              child: Row(
                children: [
                  _buildSubTabButton(
                    index: 0,
                    icon: Icons.auto_awesome_rounded,
                    label: 'Tạo Phụ Đề',
                    palette: palette,
                    accent: accent,
                  ),
                  const SizedBox(width: 4),
                  _buildSubTabButton(
                    index: 1,
                    icon: Icons.record_voice_over_rounded,
                    label: 'Lồng Tiếng AI',
                    palette: palette,
                    accent: accent,
                  ),
                ],
              ),
            ),

            // IndexedStack preserves scroll position & filled inputs of both screens
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
                        _subTabIndex = 1;
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
      ),
      ),
    );
  }

  Widget _buildSubTabButton({
    required int index,
    required IconData icon,
    required String label,
    required AppThemePalette palette,
    required Color accent,
  }) {
    final isSelected = _subTabIndex == index;
    final onAccent = palette.onColor(accent);

    return Expanded(
      child: GestureDetector(
        onTap: () {
          if (_subTabIndex != index) {
            HapticFeedback.selectionClick();
            setState(() => _subTabIndex = index);
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
          decoration: BoxDecoration(
            color: isSelected ? accent : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.34),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 16,
                color: isSelected ? onAccent : palette.textSecondary,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isSelected ? onAccent : palette.textSecondary,
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
