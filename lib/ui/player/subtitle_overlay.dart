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
    final mode = settings.subtitleMode;
    final text = mode == 'off' ? '' : (activeItem?.getDisplayText(mode) ?? '');

    if (text.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    final opacity = settings.blackBoxOpacity.clamp(0.0, 1.0);
    final fontSize = settings.subtitleFontSize;
    final offsetY = settings.subtitleOffsetY;
    final fontFamily = settings.selectedFontFamily.isNotEmpty
        ? settings.selectedFontFamily
        : null;

    return Positioned(
      left: 16,
      right: 16,
      bottom: 24 + offsetY,
      child: Center(
        child: GestureDetector(
          onVerticalDragUpdate: (details) {
            onDragOffset?.call(offsetY - details.delta.dy);
          },
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width - 32,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
    );
  }
}
