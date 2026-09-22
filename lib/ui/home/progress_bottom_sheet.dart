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
    final pct = progress.progress.clamp(0.0, 1.0);
    final pctInt = (pct * 100).toInt();

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF181920),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Header
          const Text(
            'TIẾN TRÌNH TỰ ĐỘNG',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: AppColors.primaryEmerald,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Đang tạo & dịch phụ đề',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 18),

          // Linear Progress
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct > 0 ? pct : null,
              color: AppColors.primaryEmerald,
              backgroundColor: const Color(0xFF2A2B36),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 8),

          // Message & Percentage
          Row(
            children: [
              Expanded(
                child: Text(
                  progress.message.isNotEmpty
                      ? progress.message
                      : 'Đang xử lý...',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Colors.white70,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$pctInt%',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryEmerald,
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),

          // 4 Step Items
          _buildStepItem(
            stepNumber: 1,
            title: 'Tách âm thanh M4A (hoặc Nạp phụ đề Bilibili)',
            isCompleted: pct >= 0.20,
            isCurrent: progress.stage == ProcessStage.extractingAudio,
          ),
          const SizedBox(height: 12),
          _buildStepItem(
            stepNumber: 2,
            title: 'Tải lên CapCut VOD Cloud (5MB Chunks)',
            isCompleted: pct >= 0.40,
            isCurrent: progress.stage == ProcessStage.uploadingVod,
          ),
          const SizedBox(height: 12),
          _buildStepItem(
            stepNumber: 3,
            title: 'AI CapCut nhận diện giọng nói (STT)',
            isCompleted: pct >= 0.70,
            isCurrent: progress.stage == ProcessStage.sttTranscribing,
          ),
          const SizedBox(height: 12),
          _buildStepItem(
            stepNumber: 4,
            title: 'Gemini AI dịch theo ngữ cảnh nhân vật',
            isCompleted: progress.stage == ProcessStage.completed,
            isCurrent: progress.stage == ProcessStage.aiTranslating,
          ),
          const SizedBox(height: 24),

          // Cancel button
          if (progress.isRunning)
            SizedBox(
              width: double.infinity,
              height: 46,
              child: OutlinedButton(
                onPressed: onCancel,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFFFF5252)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
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
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildStepItem({
    required int stepNumber,
    required String title,
    required bool isCompleted,
    required bool isCurrent,
  }) {
    return Row(
      children: [
        if (isCompleted)
          const Icon(
            Icons.check_circle,
            color: AppColors.primaryEmerald,
            size: 20,
          )
        else if (isCurrent)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              color: AppColors.primaryEmerald,
              strokeWidth: 2,
            ),
          )
        else
          const Icon(
            Icons.radio_button_unchecked,
            color: Color(0xFF555768),
            size: 20,
          ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            '$stepNumber. $title',
            style: TextStyle(
              fontSize: 13,
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              color: isCompleted || isCurrent ? Colors.white : const Color(0xFF7A7D91),
            ),
          ),
        ),
      ],
    );
  }
}
