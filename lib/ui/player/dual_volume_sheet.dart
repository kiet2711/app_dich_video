import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

typedef VoiceToneChangedCallback = void Function({
  required double pitch,
  required double warmth,
  required double brightness,
});

class DualVolumeSheet extends StatefulWidget {
  final double originalVolume;
  final double aiVolume;
  final ValueChanged<double> onOriginalVolumeChanged;
  final ValueChanged<double> onAiVolumeChanged;
  final double? voicePitch;
  final double? voiceWarmth;
  final double? voiceBrightness;
  final VoiceToneChangedCallback? onVoiceToneChanged;

  const DualVolumeSheet({
    super.key,
    required this.originalVolume,
    required this.aiVolume,
    required this.onOriginalVolumeChanged,
    required this.onAiVolumeChanged,
    this.voicePitch,
    this.voiceWarmth,
    this.voiceBrightness,
    this.onVoiceToneChanged,
  });

  @override
  State<DualVolumeSheet> createState() => _DualVolumeSheetState();
}

class _DualVolumeSheetState extends State<DualVolumeSheet> {
  static const List<({String label, double pitch, double warmth, double brightness})>
      _voicePresets = [
    (label: 'Mặc định', pitch: 1.0, warmth: 0.0, brightness: 0.0),
    (label: 'Giảm the thé', pitch: 0.94, warmth: 0.45, brightness: -0.45),
    (label: 'Trầm ấm', pitch: 0.88, warmth: 0.65, brightness: -0.25),
    (label: 'Trong rõ', pitch: 1.04, warmth: -0.10, brightness: 0.40),
  ];

  late double _originalVolume;
  late double _aiVolume;
  late double _voicePitch;
  late double _voiceWarmth;
  late double _voiceBrightness;

  @override
  void initState() {
    super.initState();
    _originalVolume = widget.originalVolume.clamp(0.0, 1.0);
    _aiVolume = widget.aiVolume.clamp(0.0, 1.0);
    _voicePitch = (widget.voicePitch ?? 1.0).clamp(0.75, 1.25);
    _voiceWarmth = (widget.voiceWarmth ?? 0.0).clamp(-1.0, 1.0);
    _voiceBrightness = (widget.voiceBrightness ?? 0.0).clamp(-1.0, 1.0);
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
    if (oldWidget.voicePitch != widget.voicePitch && widget.voicePitch != null) {
      _voicePitch = widget.voicePitch!.clamp(0.75, 1.25);
    }
    if (oldWidget.voiceWarmth != widget.voiceWarmth &&
        widget.voiceWarmth != null) {
      _voiceWarmth = widget.voiceWarmth!.clamp(-1.0, 1.0);
    }
    if (oldWidget.voiceBrightness != widget.voiceBrightness &&
        widget.voiceBrightness != null) {
      _voiceBrightness = widget.voiceBrightness!.clamp(-1.0, 1.0);
    }
  }

  void _updateVoiceTone({
    double? pitch,
    double? warmth,
    double? brightness,
  }) {
    setState(() {
      if (pitch != null) _voicePitch = pitch.clamp(0.75, 1.25);
      if (warmth != null) _voiceWarmth = warmth.clamp(-1.0, 1.0);
      if (brightness != null) _voiceBrightness = brightness.clamp(-1.0, 1.0);
    });
    widget.onVoiceToneChanged?.call(
      pitch: _voicePitch,
      warmth: _voiceWarmth,
      brightness: _voiceBrightness,
    );
  }

  String _formatSignedPct(double v) {
    final pct = (v * 100).round();
    if (pct > 0) return '+$pct%';
    return '$pct%';
  }

  Widget _buildToneSliderRow({
    required BuildContext context,
    required IconData icon,
    required String label,
    required String valueText,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: Colors.white70, size: 16),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            Text(
              valueText,
              style: const TextStyle(
                color: AppTheme.primaryEmerald,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: AppTheme.primaryEmerald,
            thumbColor: AppTheme.primaryEmerald,
            inactiveTrackColor: const Color(0xFF323444),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          ),
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  Widget _buildVoiceTuningCard(BuildContext context) {
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
            children: [
              const Icon(
                Icons.tune_rounded,
                color: AppTheme.primaryEmerald,
                size: 19,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Tinh chỉnh Giọng AI (Đỡ chói / Ấm hơn)',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: () =>
                    _updateVoiceTone(pitch: 1.0, warmth: 0.0, brightness: 0.0),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text(
                  'Đặt lại',
                  style: TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: _voicePresets.map((preset) {
              final selected =
                  (_voicePitch - preset.pitch).abs() < 0.015 &&
                  (_voiceWarmth - preset.warmth).abs() < 0.03 &&
                  (_voiceBrightness - preset.brightness).abs() < 0.03;
              return GestureDetector(
                onTap: () => _updateVoiceTone(
                  pitch: preset.pitch,
                  warmth: preset.warmth,
                  brightness: preset.brightness,
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? AppTheme.primaryEmerald.withValues(alpha: 0.2)
                        : const Color(0xFF282A36),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: selected
                          ? AppTheme.primaryEmerald
                          : Colors.white12,
                    ),
                  ),
                  child: Text(
                    preset.label,
                    style: TextStyle(
                      color: selected ? AppTheme.primaryEmerald : Colors.white70,
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          _buildToneSliderRow(
            context: context,
            icon: Icons.height_rounded,
            label: 'Cao độ (Pitch)',
            valueText: '${_voicePitch.toStringAsFixed(2)}x',
            value: _voicePitch,
            min: 0.75,
            max: 1.25,
            divisions: 50,
            onChanged: (v) => _updateVoiceTone(pitch: v),
          ),
          _buildToneSliderRow(
            context: context,
            icon: Icons.wb_sunny_outlined,
            label: 'Độ ấm (Dày giọng)',
            valueText: _formatSignedPct(_voiceWarmth),
            value: _voiceWarmth,
            min: -1.0,
            max: 1.0,
            divisions: 40,
            onChanged: (v) => _updateVoiceTone(warmth: v),
          ),
          _buildToneSliderRow(
            context: context,
            icon: Icons.auto_awesome_outlined,
            label: 'Độ sáng (Âm cao / Giảm thé)',
            valueText: _formatSignedPct(_voiceBrightness),
            value: _voiceBrightness,
            min: -1.0,
            max: 1.0,
            divisions: 40,
            onChanged: (v) => _updateVoiceTone(brightness: v),
          ),
        ],
      ),
    );
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
                if (widget.onVoiceToneChanged != null) ...[
                  const SizedBox(height: 12),
                  _buildVoiceTuningCard(context),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
