import 'package:flutter/material.dart';

import '../../player/global_player_manager.dart';
import '../../player/pip_manager.dart';
import '../theme/app_theme.dart';
import 'video_player_screen.dart';

class GlobalPlayerOverlay extends StatelessWidget {
  const GlobalPlayerOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        GlobalPlayerManager.instance,
        PipManager.isInPipMode,
        AppThemeController.instance,
      ]),
      builder: (context, _) {
        final manager = GlobalPlayerManager.instance;
        final request = manager.currentRequest;

        if (manager.mode == PlayerDisplayMode.hidden || request == null) {
          return const SizedBox.shrink();
        }

        final isMini = manager.isMiniPlayer;
        final isPip = PipManager.isInPipMode.value;
        final palette = AppThemePalette.of(context);
        // Khi bật thanh điều hướng nổi (extendBody: true), Scaffold truyền chiều cao
        // bottomNav vào MediaQuery.paddingOf(context).bottom nên + 8px là nằm ngay trên viên thuốc.
        final miniBottomOffset = palette.isFloatingNav
            ? MediaQuery.paddingOf(context).bottom + 8.0
            : 6.0;

        return AnimatedPositioned(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          left: isMini ? 10 : 0,
          right: isMini ? 10 : 0,
          bottom: isMini ? miniBottomOffset : 0,
          top: isMini ? null : 0,
          height: isMini ? 68 : null,
          child: PopScope(
            canPop: !manager.isFullScreen || isPip,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              if (manager.isFullScreen && !isPip) {
                manager.minimize();
              }
            },
            child: Theme(
              data: buildDarkCinemaTheme(),
              child: Material(
                color: Colors.transparent,
                child: VideoPlayerScreen(
                  key: ValueKey('global_player_${request.requestId}'),
                  videoPath: request.videoPath,
                  document: request.document,
                  title: request.title,
                  initialPositionMs: request.initialPositionMs,
                  onPlaybackPositionChanged: request.onPlaybackPositionChanged,
                  dramaDetail: request.dramaDetail,
                  currentEpisodeIndex: request.currentEpisodeIndex,
                  initialTtsEnabled: request.initialTtsEnabled,
                  coverUrl: request.coverUrl,
                  author: request.author,
                  bilibiliItem: request.bilibiliItem,
                  isGlobalPlayer: true,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
