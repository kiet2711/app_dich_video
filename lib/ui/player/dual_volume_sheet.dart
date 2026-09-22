import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class DualVolumeSheet extends StatelessWidget {
  final double originalVolume;
  final double aiVolume;
  final ValueChanged<double> onOriginalVolumeChanged;
  final ValueChanged<double> onAiVolumeChanged;

  const DualVolumeSheet({
    super.key,
    required this.originalVolume,
    required this.aiVolume,
    required this.onOriginalVolumeChanged,
    required this.onAiVolumeChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      decoration: BoxDecoration(
        color: AppTheme.darkCard,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.graphic_eq, color: AppTheme.primaryEmerald, size: 24),
              const SizedBox(width: 10),
              const Text(
                'Điều Khiển Âm Thanh Độc Lập',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white70),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // 1. ÂM LƯỢNG VIDEO GỐC
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1F2029),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.cardBorder),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.volume_up, color: Color(0xFF64B5F6), size: 20),
                        SizedBox(width: 8),
                        Text(
                          'Âm lượng Video Gốc',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      '${(originalVolume * 100).toInt()}%',
                      style: const TextStyle(
                        color: Color(0xFF64B5F6),
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        originalVolume > 0 ? Icons.volume_down : Icons.volume_mute,
                        color: Colors.white70,
                      ),
                      onPressed: () {
                        onOriginalVolumeChanged(originalVolume > 0 ? 0.0 : 1.0);
                      },
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: const Color(0xFF64B5F6),
                          thumbColor: const Color(0xFF64B5F6),
                          inactiveTrackColor: const Color(0xFF323444),
                        ),
                        child: Slider(
                          value: originalVolume.clamp(0.0, 1.0),
                          onChanged: onOriginalVolumeChanged,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // 2. ÂM LƯỢNG GIỌNG ĐỌC AI
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1F2029),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.cardBorder),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.record_voice_over, color: AppTheme.primaryEmerald, size: 20),
                        SizedBox(width: 8),
                        Text(
                          'Âm lượng Giọng Đọc AI',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      '${(aiVolume * 100).toInt()}%',
                      style: const TextStyle(
                        color: AppTheme.primaryEmerald,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        aiVolume > 0 ? Icons.volume_down : Icons.volume_off,
                        color: Colors.white70,
                      ),
                      onPressed: () {
                        onAiVolumeChanged(aiVolume > 0 ? 0.0 : 1.0);
                      },
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: AppTheme.primaryEmerald,
                          thumbColor: AppTheme.primaryEmerald,
                          inactiveTrackColor: const Color(0xFF323444),
                        ),
                        child: Slider(
                          value: aiVolume.clamp(0.0, 1.0),
                          onChanged: onAiVolumeChanged,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
