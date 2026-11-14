import 'package:flutter/material.dart';

import '../../data/repository/settings_repository.dart';
import '../../domain/ai/live/live_stream_translator.dart';
import '../theme/app_theme.dart';

/// Bottom sheet điều khiển tính năng Nghe Dịch Trực Tiếp (Gemini 3.5 Live Translate),
/// nổi bật thanh chỉnh "Cho AI nghe trước" (0.0s - 8.0s) để người dùng tinh chỉnh theo tốc độ thoại.
class LiveTranslateSheet extends StatefulWidget {
  final LiveStreamTranslator translator;
  final SettingsRepository settings;
  final double originalVideoVolume;
  final ValueChanged<double> onOriginalVideoVolumeChanged;
  final Future<void> Function(bool enabled) onToggleEnabled;
  final bool hasGeminiKeys;
  final VoidCallback? onOpenGeminiSettings;

  const LiveTranslateSheet({
    super.key,
    required this.translator,
    required this.settings,
    required this.originalVideoVolume,
    required this.onOriginalVideoVolumeChanged,
    required this.onToggleEnabled,
    this.hasGeminiKeys = true,
    this.onOpenGeminiSettings,
  });

  @override
  State<LiveTranslateSheet> createState() => _LiveTranslateSheetState();
}

class _LiveTranslateSheetState extends State<LiveTranslateSheet> {
  static const List<int> _leadPresetsMs = [0, 1000, 1500, 2000, 3000, 4000];
  static const List<(String code, String label)> _targetLanguages = [
    ('vi', 'Tiếng Việt'),
    ('en', 'English'),
    ('ja', '日本語'),
    ('ko', '한국어'),
  ];

  bool _isToggling = false;
  late double _originalVol;

  @override
  void initState() {
    super.initState();
    _originalVol = widget.originalVideoVolume.clamp(0.0, 1.0);
  }

  @override
  void didUpdateWidget(covariant LiveTranslateSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.originalVideoVolume - widget.originalVideoVolume).abs() >
        0.005) {
      _originalVol = widget.originalVideoVolume.clamp(0.0, 1.0);
    }
  }

  Future<void> _handleToggle(bool nextEnabled) async {
    if (_isToggling) return;
    setState(() => _isToggling = true);
    try {
      await widget.onToggleEnabled(nextEnabled);
    } finally {
      if (mounted) {
        setState(() => _isToggling = false);
      }
    }
  }

  Color _statusColor(LiveTranslateStatus status) {
    switch (status) {
      case LiveTranslateStatus.active:
        return AppTheme.primaryEmerald;
      case LiveTranslateStatus.connecting:
      case LiveTranslateStatus.buffering:
      case LiveTranslateStatus.reconnecting:
        return const Color(0xFF64B5F6);
      case LiveTranslateStatus.paused:
        return AppTheme.accentGold;
      case LiveTranslateStatus.error:
        return Colors.redAccent;
      case LiveTranslateStatus.idle:
        return Colors.white54;
    }
  }

  IconData _statusIcon(LiveTranslateStatus status) {
    switch (status) {
      case LiveTranslateStatus.active:
        return Icons.graphic_eq_rounded;
      case LiveTranslateStatus.connecting:
      case LiveTranslateStatus.buffering:
      case LiveTranslateStatus.reconnecting:
        return Icons.sync_rounded;
      case LiveTranslateStatus.paused:
        return Icons.pause_circle_outline_rounded;
      case LiveTranslateStatus.error:
        return Icons.error_outline_rounded;
      case LiveTranslateStatus.idle:
        return Icons.surround_sound_outlined;
    }
  }

  String _formatLeadBadge(int ms) {
    final sec = ms / 1000.0;
    if (ms % 1000 == 0) return '${sec.toInt()}s';
    return '${sec.toStringAsFixed(1)}s';
  }

  String _leadHintText(int leadMs) {
    if (leadMs == 0) {
      return '0.0s: Đọc cùng nhịp video. Hình khớp tuyệt đối nhưng AI sẽ nói trễ hơn thoại gốc ~1–1.5s.';
    }
    if (leadMs <= 1200) {
      return 'Nghe trước ít (+${(leadMs / 1000).toStringAsFixed(1)}s): Hợp video nói chậm. Nếu thấy câu bị đứt hãy tăng lên 1.5s–2.5s.';
    }
    if (leadMs <= 2800) {
      return 'Mức cân bằng khuyến nghị (+${(leadMs / 1000).toStringAsFixed(1)}s): AI kịp nghe trọn cụm câu và đọc đè khớp cảnh nhất.';
    }
    return 'Nghe trước sâu (+${(leadMs / 1000).toStringAsFixed(1)}s): Dịch mượt câu dài hoặc nói cực nhanh, nhưng giọng dịch có thể hơi đi trước cảnh.';
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.88;
    final translator = widget.translator;

    return AnimatedBuilder(
      animation: translator,
      builder: (context, _) {
        final statusColor = _statusColor(translator.status);
        final leadMs = translator.leadMs.clamp(
          LiveStreamTranslator.minLeadMs,
          LiveStreamTranslator.maxLeadMs,
        );

        return Container(
          constraints: BoxConstraints(maxHeight: maxH),
          decoration: const BoxDecoration(
            color: AppTheme.darkCard,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(color: AppTheme.cardBorder, width: 1),
            ),
          ),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Tiêu đề + Switch Bật/Tắt nhanh
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: translator.isEnabled
                              ? AppTheme.primaryEmerald.withValues(alpha: 0.16)
                              : Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: translator.isEnabled
                                ? AppTheme.primaryEmerald.withValues(alpha: 0.5)
                                : Colors.white12,
                          ),
                        ),
                        child: Icon(
                          Icons.spatial_audio_rounded,
                          color: translator.isEnabled
                              ? AppTheme.primaryEmerald
                              : Colors.white70,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Text(
                                  'Nghe Dịch Trực Tiếp',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xFF64B5F6,
                                    ).withValues(alpha: 0.16),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: const Color(
                                        0xFF64B5F6,
                                      ).withValues(alpha: 0.4),
                                    ),
                                  ),
                                  child: const Text(
                                    '3.5 LIVE',
                                    style: TextStyle(
                                      color: Color(0xFF90CAF9),
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            const Text(
                              'Stream trực tiếp từ luồng phát • Không lưu file',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_isToggling)
                        const Padding(
                          padding: EdgeInsets.only(right: 10),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppTheme.primaryEmerald,
                            ),
                          ),
                        ),
                      Switch.adaptive(
                        value: translator.isEnabled,
                        activeTrackColor: AppTheme.primaryEmerald,
                        onChanged: _isToggling ? null : _handleToggle,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Cảnh báo thiếu Gemini API Key nếu chưa cấu hình
                  if (!widget.hasGeminiKeys) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orangeAccent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Colors.orangeAccent.withValues(alpha: 0.45),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.vpn_key_off_rounded,
                            color: Colors.orangeAccent,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Chưa có Gemini API Key. Thêm key để dùng Nghe Dịch Live.',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          if (widget.onOpenGeminiSettings != null)
                            TextButton(
                              onPressed: () {
                                Navigator.of(context).pop();
                                widget.onOpenGeminiSettings!();
                              },
                              child: const Text(
                                'Thêm Key',
                                style: TextStyle(
                                  color: Colors.orangeAccent,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Thẻ trạng thái luồng + Thông số realtime
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F2029),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: statusColor.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              _statusIcon(translator.status),
                              size: 16,
                              color: statusColor,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                translator.statusMessage,
                                style: TextStyle(
                                  color: statusColor,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (translator.isAiSpeaking)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AppTheme.primaryEmerald.withValues(
                                    alpha: 0.18,
                                  ),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: const Text(
                                  'ĐANG NÓI',
                                  style: TextStyle(
                                    color: AppTheme.primaryEmerald,
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        if (translator.isEnabled) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              _MetricChip(
                                icon: Icons.fast_forward_rounded,
                                label:
                                    'Đang đi trước: ${(translator.actualLeadMs / 1000).toStringAsFixed(1)}s',
                                color: const Color(0xFF64B5F6),
                              ),
                              _MetricChip(
                                icon: Icons.mic_none_rounded,
                                label:
                                    'Đã gửi: ${translator.sentAudioSeconds}s',
                                color: Colors.white70,
                              ),
                              if (translator.vadFilterEnabled)
                                _MetricChip(
                                  icon: Icons.noise_control_off_rounded,
                                  label:
                                      'Lọc im lặng: ${translator.skippedSilenceChunks}',
                                  color: AppTheme.primaryEmerald,
                                ),
                              if (translator.maskedActiveKey.isNotEmpty)
                                _MetricChip(
                                  icon: Icons.key_rounded,
                                  label: translator.maskedActiveKey,
                                  color: Colors.white54,
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // MỤC CHÍNH: Cho AI nghe trước (Lookahead Slider + Preset Chips)
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F2029),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFF64B5F6).withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.timer_outlined,
                              color: Color(0xFF64B5F6),
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'Cho AI nghe trước',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF64B5F6,
                                ).withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: const Color(
                                    0xFF64B5F6,
                                  ).withValues(alpha: 0.45),
                                ),
                              ),
                              child: Text(
                                '+${(leadMs / 1000).toStringAsFixed(1)}s',
                                style: const TextStyle(
                                  color: Color(0xFF90CAF9),
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 4,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 8,
                            ),
                            activeTrackColor: const Color(0xFF64B5F6),
                            inactiveTrackColor: Colors.white12,
                            thumbColor: const Color(0xFF90CAF9),
                            overlayColor: const Color(
                              0xFF64B5F6,
                            ).withValues(alpha: 0.18),
                          ),
                          child: Slider(
                            value: leadMs.toDouble(),
                            min: LiveStreamTranslator.minLeadMs.toDouble(),
                            max: LiveStreamTranslator.maxLeadMs.toDouble(),
                            divisions: 40, // mỗi nấc 0.2s (200ms)
                            onChanged: (value) {
                              final rounded = (value / 200).round() * 200;
                              translator.setLeadMs(rounded);
                            },
                          ),
                        ),
                        // Preset nhanh: 0s, 1s, 1.5s, 2s, 3s, 4s
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _leadPresetsMs.map((presetMs) {
                            final selected = leadMs == presetMs;
                            return ChoiceChip(
                              label: Text(
                                presetMs == 0
                                    ? '0s'
                                    : '+${_formatLeadBadge(presetMs)}',
                              ),
                              selected: selected,
                              visualDensity: VisualDensity.compact,
                              selectedColor: const Color(0xFF64B5F6),
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.06,
                              ),
                              side: BorderSide(
                                color: selected
                                    ? const Color(0xFF90CAF9)
                                    : Colors.white12,
                              ),
                              labelStyle: TextStyle(
                                color: selected
                                    ? Colors.black
                                    : Colors.white70,
                                fontSize: 12,
                                fontWeight: selected
                                    ? FontWeight.bold
                                    : FontWeight.w500,
                              ),
                              onSelected: (_) => translator.setLeadMs(presetMs),
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _leadHintText(leadMs),
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 11.5,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Cụm Âm lượng kép nhanh cho Live Translate
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F2029),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      children: [
                        _VolumeSliderRow(
                          icon: Icons.movie_outlined,
                          label: 'Âm thanh Video gốc',
                          value: _originalVol,
                          color: Colors.white70,
                          onChanged: (val) {
                            setState(() => _originalVol = val);
                            widget.onOriginalVideoVolumeChanged(val);
                          },
                        ),
                        const SizedBox(height: 6),
                        _VolumeSliderRow(
                          icon: Icons.record_voice_over_rounded,
                          label: 'Giọng dịch AI Live',
                          value: translator.aiVolume,
                          color: AppTheme.primaryEmerald,
                          onChanged: (val) {
                            translator.setVolume(val);
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Chọn ngôn ngữ đích
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F2029),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Ngôn ngữ AI nói ra',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _targetLanguages.map((lang) {
                            final selected =
                                translator.targetLanguageCode == lang.$1;
                            return ChoiceChip(
                              label: Text(lang.$2),
                              selected: selected,
                              visualDensity: VisualDensity.compact,
                              selectedColor: AppTheme.primaryEmerald,
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.06,
                              ),
                              labelStyle: TextStyle(
                                color: selected ? Colors.black : Colors.white70,
                                fontSize: 12,
                                fontWeight: selected
                                    ? FontWeight.bold
                                    : FontWeight.w500,
                              ),
                              onSelected: (_) {
                                translator.setTargetLanguageCode(lang.$1);
                              },
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Các tùy chọn nâng cao (Caption tạm, Warmup, VAD lọc im lặng, Echo)
                  Material(
                    color: const Color(0xFF1F2029),
                    borderRadius: BorderRadius.circular(16),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        SwitchListTile.adaptive(
                          dense: true,
                          value: translator.showLiveCaptions,
                          activeTrackColor: AppTheme.primaryEmerald,
                          title: const Text(
                            'Hiện phụ đề live tạm trên video',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: const Text(
                            'Chỉ hiển thị tạm theo lời dịch, không ghi file.',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                          onChanged: translator.setShowLiveCaptions,
                        ),
                        const Divider(height: 1, color: Colors.white10),
                        SwitchListTile.adaptive(
                          dense: true,
                          value: translator.pauseVideoOnWarmup,
                          activeTrackColor: AppTheme.primaryEmerald,
                          title: const Text(
                            'Tạm chờ AI ~2s khi mới bật/tua',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: const Text(
                            'Giúp câu đầu tiên phát ra khớp ngay với hình.',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                          onChanged: translator.setPauseVideoOnWarmup,
                        ),
                        const Divider(height: 1, color: Colors.white10),
                        SwitchListTile.adaptive(
                          dense: true,
                          value: translator.vadFilterEnabled,
                          activeTrackColor: AppTheme.primaryEmerald,
                          title: const Text(
                            'Lọc khoảng lặng (tiết kiệm 20k TPM)',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: const Text(
                            'Bỏ qua đoạn không có tiếng thoại để kéo dài phiên.',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                          onChanged: translator.setVadFilterEnabled,
                        ),
                        const Divider(height: 1, color: Colors.white10),
                        SwitchListTile.adaptive(
                          dense: true,
                          value: translator.echoTargetLanguage,
                          activeTrackColor: AppTheme.primaryEmerald,
                          title: const Text(
                            'Phát lại nếu video đã nói đúng ngôn ngữ đích',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: const Text(
                            'Tắt để AI bỏ qua khi video đã nói tiếng Việt.',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                          onChanged: (v) {
                            translator.setEchoTargetLanguage(v);
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MetricChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _MetricChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _VolumeSliderRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final double value;
  final Color color;
  final ValueChanged<double> onChanged;

  const _VolumeSliderRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final pct = (value.clamp(0.0, 1.0) * 100).round();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 12.5),
              ),
            ),
            Text(
              '$pct%',
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            activeTrackColor: color,
            inactiveTrackColor: Colors.white12,
            thumbColor: color,
          ),
          child: Slider(
            value: value.clamp(0.0, 1.0),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

/// Banner phụ đề live tạm thời trên trình phát video (không lưu file).
class LiveTranslateCaptionBanner extends StatelessWidget {
  final LiveStreamTranslator translator;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry margin;

  const LiveTranslateCaptionBanner({
    super.key,
    required this.translator,
    this.onTap,
    this.margin = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: translator,
      builder: (context, _) {
        if (!translator.isEnabled) {
          return const SizedBox.shrink();
        }
        final text = translator.liveOutputTranscript.trim();
        final isWaitingState =
            translator.status == LiveTranslateStatus.connecting ||
            translator.status == LiveTranslateStatus.buffering ||
            translator.status == LiveTranslateStatus.reconnecting ||
            translator.status == LiveTranslateStatus.error;
        if (!translator.showLiveCaptions && !isWaitingState) {
          return const SizedBox.shrink();
        }
        if (text.isEmpty && !isWaitingState) {
          return const SizedBox.shrink();
        }

        final display = text.isNotEmpty ? text : translator.statusMessage;
        final isError = translator.status == LiveTranslateStatus.error;
        final accent = isError
            ? Colors.redAccent
            : (translator.isAiSpeaking
                  ? AppTheme.primaryEmerald
                  : const Color(0xFF64B5F6));

        final child = Container(
          margin: margin,
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0xFF101218).withValues(alpha: 0.84),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: accent.withValues(alpha: 0.55),
              width: 1,
            ),
            boxShadow: const [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 10,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      translator.isAiSpeaking
                          ? Icons.graphic_eq_rounded
                          : Icons.spatial_audio_rounded,
                      size: 11,
                      color: accent,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '+${translator.leadSeconds.toStringAsFixed(1)}s',
                      style: TextStyle(
                        color: accent,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  display,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
        );

        if (onTap == null) return child;
        return GestureDetector(onTap: onTap, child: child);
      },
    );
  }
}
