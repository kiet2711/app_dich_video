import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class DualVolumeSheet extends StatefulWidget {
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
  State<DualVolumeSheet> createState() => _DualVolumeSheetState();
}

class _DualVolumeSheetState extends State<DualVolumeSheet> {
  late double _originalVolume;
  late double _aiVolume;

  @override
  void initState() {
    super.initState();
    _originalVolume = widget.originalVolume.clamp(0.0, 1.0);
    _aiVolume = widget.aiVolume.clamp(0.0, 1.0);
  }

  @override
  void didUpdateWidget(covariant DualVolumeSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.originalVolume != widget.originalVolume) {
      _originalVolume = widget.originalVolume.clamp(0.0, 1.0);
    }
    if (oldWidget.aiVolume != widget.aiVolume) {
      _aiVolume = widget.aiVolume.clamp(0.0, 1.0);
    }
  }

  void _updateOriginalVolume(double val) {
    final clamped = val.clamp(0.0, 1.0);
    setState(() => _originalVolume = clamped);
    widget.onOriginalVolumeChanged(clamped);
  }

  void _updateAiVolume(double val) {
    final clamped = val.clamp(0.0, 1.0);
    setState(() => _aiVolume = clamped);
    widget.onAiVolumeChanged(clamped);
  }

  Widget _buildVolumeCard({
    required BuildContext context,
    required IconData icon,
    required Color accentColor,
    required String title,
    required double volume,
    required IconData mutedOrLowIcon,
    required ValueChanged<double> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1F2029),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Icon(icon, color: accentColor, size: 20),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(volume * 100).toInt()}%',
                style: TextStyle(
                  color: accentColor,
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
                icon: Icon(mutedOrLowIcon, color: Colors.white70),
                onPressed: () {
                  onChanged(volume > 0 ? 0.0 : 1.0);
                },
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: accentColor,
                    thumbColor: accentColor,
                    inactiveTrackColor: const Color(0xFF323444),
                  ),
                  child: Slider(
                    value: volume,
                    onChanged: onChanged,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final maxHeight = MediaQuery.of(context).size.height * 0.92;

    final originalCard = _buildVolumeCard(
      context: context,
      icon: Icons.volume_up,
      accentColor: const Color(0xFF64B5F6),
      title: 'Âm lượng Video Gốc',
      volume: _originalVolume,
      mutedOrLowIcon:
          _originalVolume > 0 ? Icons.volume_down : Icons.volume_mute,
      onChanged: _updateOriginalVolume,
    );

    final aiCard = _buildVolumeCard(
      context: context,
      icon: Icons.record_voice_over,
      accentColor: AppTheme.primaryEmerald,
      title: 'Âm lượng Giọng Đọc AI',
      volume: _aiVolume,
      mutedOrLowIcon: _aiVolume > 0 ? Icons.volume_down : Icons.volume_off,
      onChanged: _updateAiVolume,
    );

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          decoration: BoxDecoration(
            color: AppTheme.darkCard,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.graphic_eq,
                      color: AppTheme.primaryEmerald,
                      size: 24,
                    ),
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
                const SizedBox(height: 12),
                if (isLandscape)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: originalCard),
                      const SizedBox(width: 14),
                      Expanded(child: aiCard),
                    ],
                  )
                else ...[
                  originalCard,
                  const SizedBox(height: 12),
                  aiCard,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
