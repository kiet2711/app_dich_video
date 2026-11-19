import 'package:flutter/material.dart';

import '../../data/model/process_progress.dart';
import '../theme/app_theme.dart';

class ProgressBottomSheet extends StatelessWidget {
  final ProcessProgress progress;
  final VoidCallback onCancel;
  final VoidCallback? onDismiss;

  const ProgressBottomSheet({
    super.key,
    required this.progress,
    required this.onCancel,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.studio);
    final pct = progress.progress.clamp(0.0, 1.0);
    final pctInt = (pct * 100).toInt();

    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        MediaQuery.of(context).padding.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Text(
            'TIẾN TRÌNH TỰ ĐỘNG',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: accent,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Đang tạo & dịch phụ đề',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: palette.textPrimary,
            ),
          ),
          const SizedBox(height: 20),

          // Linear Progress
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct,
              color: accent,
              backgroundColor: palette.surfaceAlt,
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 8),

          // Message & Percentage
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  progress.message.isNotEmpty
                      ? progress.message
                      : 'Đang xử lý...',
                  style: TextStyle(
                    fontSize: 13,
                    color: palette.textSecondary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$pctInt%',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // 4 BƯỚC TIẾN TRÌNH
          _buildStepItem(
            palette: palette,
            accent: accent,
            stepNumber: 1,
            title: 'Tách âm thanh M4A (Không re-encode)',
            isCompleted: pct >= 0.20,
            isCurrent: progress.stage == ProcessStage.extractingAudio,
          ),
          const SizedBox(height: 12),
          _buildStepItem(
            palette: palette,
            accent: accent,
            stepNumber: 2,
            title: 'Tải lên CapCut VOD Cloud (5MB Chunks)',
            isCompleted: pct >= 0.40,
            isCurrent: progress.stage == ProcessStage.uploadingVod,
          ),
          const SizedBox(height: 12),
          _buildStepItem(
            palette: palette,
            accent: accent,
            stepNumber: 3,
            title: 'AI CapCut nhận diện giọng nói (STT)',
            isCompleted: pct >= 0.70,
            isCurrent: progress.stage == ProcessStage.sttTranscribing,
          ),
          const SizedBox(height: 12),
          _buildStepItem(
            palette: palette,
            accent: accent,
            stepNumber: 4,
            title: 'Gemini AI dịch theo ngữ cảnh nhân vật',
            isCompleted: progress.stage == ProcessStage.completed,
            isCurrent: progress.stage == ProcessStage.aiTranslating,
          ),
          const SizedBox(height: 28),

          // Nút Huỷ Tác Vụ
          if (progress.isRunning)
            SizedBox(
              width: double.infinity,
              height: 48,
              child: OutlinedButton(
                onPressed: onCancel,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFFFF5252)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Huỷ Tác Vụ',
                  style: TextStyle(
                    color: Color(0xFFFF5252),
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStepItem({
    required AppThemePalette palette,
    required Color accent,
    required int stepNumber,
    required String title,
    required bool isCompleted,
    required bool isCurrent,
  }) {
    return Row(
      children: [
        if (isCompleted)
          Icon(
            Icons.check_circle,
            color: accent,
            size: 20,
          )
        else if (isCurrent)
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              color: accent,
              strokeWidth: 2,
            ),
          )
        else
          Icon(
            Icons.radio_button_unchecked,
            color: palette.textMuted.withValues(alpha: 0.45),
            size: 20,
          ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            '$stepNumber. $title',
            style: TextStyle(
              fontSize: 14,
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              color: (isCompleted || isCurrent)
                  ? palette.textPrimary
                  : palette.textMuted,
            ),
          ),
        ),
      ],
    );
  }
}
