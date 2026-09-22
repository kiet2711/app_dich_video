import 'package:flutter/material.dart';

import '../../data/model/process_progress.dart';

class ProgressBottomSheet extends StatelessWidget {
  final ProcessProgress progress;
  final VoidCallback onCancel;

  const ProgressBottomSheet({
    super.key,
    required this.progress,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final stageName = switch (progress.stage) {
      ProcessStage.extractingAudio => 'Giai đoạn 1: Tách âm thanh M4A',
      ProcessStage.uploadingVod => 'Giai đoạn 2: Tải lên CapCut VOD',
      ProcessStage.sttTranscribing =>
        'Giai đoạn 3: CapCut AI nhận diện giọng nói',
      ProcessStage.aiTranslating => 'Giai đoạn 4: Gemini AI dịch phụ đề',
      ProcessStage.completed => 'Hoàn tất xử lý!',
      ProcessStage.error => 'Xảy ra lỗi',
      ProcessStage.cancelled => 'Đã huỷ',
      _ => 'Đang chuẩn bị...',
    };

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                stageName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (progress.isRunning)
                TextButton(
                  onPressed: onCancel,
                  child: const Text(
                    'Huỷ',
                    style: TextStyle(color: Colors.redAccent),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          LinearProgressIndicator(
            value: progress.progress > 0 ? progress.progress : null,
            backgroundColor: Colors.white12,
            color: Colors.blueAccent,
            minHeight: 8,
            borderRadius: BorderRadius.circular(4),
          ),
          const SizedBox(height: 12),
          Text(
            progress.message,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
