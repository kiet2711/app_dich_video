import 'package:flutter/material.dart';

import '../../data/model/subtitle_document.dart';
import '../../data/repository/settings_repository.dart';

class SubtitleOverlay extends StatelessWidget {
  final SubtitleDocument document;
  final int currentPositionMs;
  final SettingsRepository settings;
  final void Function(double newOffsetY)? onDragOffset;

  const SubtitleOverlay({
    super.key,
    required this.document,
    required this.currentPositionMs,
    required this.settings,
    this.onDragOffset,
  });

  @override
  Widget build(BuildContext context) {
    final activeItem = document.getActiveItem(currentPositionMs);
    final text = activeItem?.getDisplayText(settings.subtitleMode) ?? '';

    if (text.isEmpty && !settings.isBlackBoxEnabled) {
      return const SizedBox.shrink();
    }

    final boxHeight = settings.blackBoxHeight;
    final opacity = settings.blackBoxOpacity.clamp(0.0, 1.0);
    final fontSize = settings.subtitleFontSize;
    final offsetY = settings.subtitleOffsetY;

    return Positioned(
      left: 16,
      right: 16,
      bottom: 24 + offsetY,
      child: GestureDetector(
        onVerticalDragUpdate: (details) {
          onDragOffset?.call(offsetY - details.delta.dy);
        },
        child: Container(
          constraints: BoxConstraints(minHeight: boxHeight),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: settings.isBlackBoxEnabled
              ? BoxDecoration(
                  color: Colors.black.withValues(alpha: opacity),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                )
              : null,
          child: Center(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: fontSize,
                fontWeight: FontWeight.bold,
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
    );
  }
}
