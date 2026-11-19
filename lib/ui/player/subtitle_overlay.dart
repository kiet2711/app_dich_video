import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/model/subtitle_document.dart';
import '../../data/repository/settings_repository.dart';

class SubtitleOverlay extends StatelessWidget {
  final SubtitleDocument document;
  final int currentPositionMs;
  final SettingsRepository settings;
  final void Function(double newNormalizedPos, bool isLandscape)? onDragPosition;

  const SubtitleOverlay({
    super.key,
    required this.document,
    required this.currentPositionMs,
    required this.settings,
    this.onDragPosition,
  });

  @override
  Widget build(BuildContext context) {
    final activeItem = document.getActiveItem(currentPositionMs);
    final mode = settings.subtitleMode;
    final text = mode == 'off' ? '' : (activeItem?.getDisplayText(mode) ?? '');

    if (text.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    final opacity = settings.blackBoxOpacity.clamp(0.0, 1.0);
    final fontSize = settings.subtitleFontSize;
    final fontFamily = settings.selectedFontFamily.isNotEmpty
        ? settings.selectedFontFamily
        : null;
    final mediaPadding = MediaQuery.paddingOf(context);

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isLandscape = constraints.maxWidth > constraints.maxHeight;
          final safeBottom = math.max(12.0, mediaPadding.bottom + 8.0);
          final safeTop = math.max(16.0, mediaPadding.top + 8.0);
          // Chừa chiều cao ước lượng của hộp chữ để kéo lên 100% (sát nóc) không bị tràn khỏi màn.
          final estimatedSubHeight = fontSize * 1.35 * 2 + 16.0;
          final usableTravel = math.max(
            40.0,
            constraints.maxHeight - safeBottom - safeTop - estimatedSubHeight,
          );
          final normalizedPos = settings.getSubtitlePosition(
            isLandscape: isLandscape,
          );
          final bottomOffset = safeBottom + normalizedPos * usableTravel;

          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned(
                left: 16,
                right: 16,
                bottom: bottomOffset,
                child: Center(
                  child: GestureDetector(
                    onVerticalDragUpdate: (details) {
                      final nextPos = (normalizedPos -
                              (details.delta.dy / usableTravel))
                          .clamp(0.0, 1.0);
                      onDragPosition?.call(nextPos, isLandscape);
                    },
                    child: Container(
                      constraints: BoxConstraints(
                        maxWidth: math.max(120.0, constraints.maxWidth - 32),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: settings.isBlackBoxEnabled
                          ? BoxDecoration(
                              color: Colors.black.withValues(alpha: opacity),
                              borderRadius: BorderRadius.circular(5),
                            )
                          : null,
                      child: Text(
                        text,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: fontFamily,
                          color: Colors.white,
                          fontSize: fontSize,
                          fontWeight: FontWeight.bold,
                          height: 1.3,
                          shadows: const [
                            Shadow(
                              color: Colors.black,
                              offset: Offset(1, 1),
                              blurRadius: 3,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
