import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/ksub_logo.dart';

/// Màn hình khởi động Ksub: hiệu ứng Liquid Glass đồng bộ với App Icon & Native Splash,
/// giữ nhịp thở ánh sáng mượt trong lúc nạp dịch vụ nền rồi tan vào giao diện chính.
class AppStartupSplash extends StatefulWidget {
  final Future<void> Function() onInitialize;
  final WidgetBuilder homeBuilder;
  final Duration minDisplayDuration;
  final Duration exitDuration;

  const AppStartupSplash({
    super.key,
    required this.onInitialize,
    required this.homeBuilder,
    this.minDisplayDuration = Duration.zero,
    this.exitDuration = const Duration(milliseconds: 200),
  });

  @override
  State<AppStartupSplash> createState() => _AppStartupSplashState();
}

class _AppStartupSplashState extends State<AppStartupSplash>
    with TickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final AnimationController _exitController;
  late final Animation<double> _pulseScale;
  late final Animation<double> _pulseGlow;
  late final Animation<double> _shimmerProgress;
  late final Animation<double> _exitOpacity;
  late final Animation<double> _exitScale;

  bool _isReady = false;
  bool _splashDismissed = false;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1450),
    )..repeat(reverse: true);

    _pulseScale = Tween<double>(begin: 0.97, end: 1.025).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _pulseGlow = Tween<double>(begin: 0.42, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _shimmerProgress = Tween<double>(begin: -1.2, end: 1.4).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOutSine),
    );

    _exitController = AnimationController(
      vsync: this,
      duration: widget.exitDuration,
    );
    _exitOpacity = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _exitController, curve: Curves.easeOutCubic),
    );
    _exitScale = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _exitController, curve: Curves.easeOutCubic),
    );

    unawaited(_runStartupSequence());
  }

  Future<void> _runStartupSequence() async {
    final minDelay = widget.minDisplayDuration > Duration.zero
        ? Future<void>.delayed(widget.minDisplayDuration)
        : Future<void>.value();

    try {
      await Future.wait<void>([
        widget.onInitialize(),
        minDelay,
      ]);
    } catch (_) {
      await minDelay;
    }

    if (!mounted) return;
    setState(() => _isReady = true);

    // Chờ frame đầu của màn hình chính lên hình rồi mới tan màn splash.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    await _exitController.forward();
    if (!mounted) return;
    _pulseController.stop();
    setState(() => _splashDismissed = true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _exitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (_isReady) widget.homeBuilder(context),
        if (!_splashDismissed)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: _isReady,
              child: FadeTransition(
                opacity: _exitOpacity,
                child: ScaleTransition(
                  scale: _exitScale,
                  child: _buildSplashSurface(context),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSplashSurface(BuildContext context) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.studio);
    final freshGradient = palette.backgroundGradientFor(AppTabId.studio);
    final bgTop = palette.isDark
        ? const Color(0xFF141824)
        : Color.lerp(palette.surface, accent, 0.08)!;
    final bgBottom = palette.isDark
        ? const Color(0xFF07090E)
        : palette.backgroundFor(AppTabId.studio);
    const ksubCrimson = Color(0xFFF9021A);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: freshGradient == null ? bgBottom : null,
        gradient: freshGradient ??
            RadialGradient(
              center: const Alignment(0.0, -0.16),
              radius: 0.92,
              colors: [bgTop, bgBottom],
            ),
      ),
      child: SafeArea(
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedBuilder(
                    animation: _pulseController,
                    builder: (_, child) {
                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          // Hào quang dịu đồng bộ với điểm nhấn đỏ & sắc băng kính của icon Ksub
                          Container(
                            width: 176,
                            height: 176,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  ksubCrimson.withValues(
                                    alpha: 0.14 * _pulseGlow.value,
                                  ),
                                  accent.withValues(
                                    alpha: 0.10 * _pulseGlow.value,
                                  ),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                          // Vòng viền kính đồng tâm mỏng
                          Container(
                            width: 138,
                            height: 138,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(34),
                              border: Border.all(
                                color: (palette.isDark
                                        ? Colors.white
                                        : palette.textPrimary)
                                    .withValues(
                                      alpha: 0.09 + 0.07 * _pulseGlow.value,
                                    ),
                                width: 1.0,
                              ),
                            ),
                          ),
                          Transform.scale(
                            scale: _pulseScale.value,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(28),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  child!,
                                  // Tia sáng quét chéo mặt kính (Liquid Glass Shimmer)
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: FractionalTranslation(
                                        translation: Offset(
                                          _shimmerProgress.value,
                                          0,
                                        ),
                                        child: Transform.rotate(
                                          angle: -0.45,
                                          child: Container(
                                            width: 44,
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                colors: [
                                                  Colors.transparent,
                                                  Colors.white.withValues(
                                                    alpha: 0.16,
                                                  ),
                                                  Colors.transparent,
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                    child: const KsubLogoMark(size: 114),
                  ),
                  const SizedBox(height: 20),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: 'K',
                          style: TextStyle(
                            color: palette.isDark
                                ? Colors.white
                                : palette.textPrimary,
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.8,
                            shadows: [
                              Shadow(
                                color: ksubCrimson.withValues(alpha: 0.38),
                                blurRadius: 12,
                              ),
                            ],
                          ),
                        ),
                        TextSpan(
                          text: 'sub',
                          style: TextStyle(
                            color: palette.isDark
                                ? const Color(0xFFDDE6F5)
                                : palette.textSecondary,
                            fontSize: 27,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                          ),
                        ),
                      ],
                    ),
                    style: const TextStyle(decoration: TextDecoration.none),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Phụ đề & Lồng tiếng AI',
                    style: TextStyle(
                      color: palette.textSecondary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.25,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 34,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 138,
                    height: 4,
                    padding: const EdgeInsets.all(0.5),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      color: (palette.isDark
                              ? Colors.white
                              : palette.textPrimary)
                          .withValues(alpha: 0.10),
                      border: Border.all(
                        color: (palette.isDark
                                ? Colors.white
                                : palette.textPrimary)
                            .withValues(alpha: 0.14),
                        width: 0.5,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2.5),
                      child: LinearProgressIndicator(
                        backgroundColor: Colors.transparent,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          palette.isDark ? const Color(0xFFFF2438) : accent,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'KSUB · HỒNG QUẢ · BILIBILI',
                    style: TextStyle(
                      color: palette.textMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
