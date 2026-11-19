import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/capsub_logo.dart';

/// Màn hình mở đầu kiểu TikTok: hiện logo tức thì khi app khởi động,
/// giữ nhịp thở mượt trong lúc nạp dịch vụ nền rồi tan vào giao diện chính.
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
  late final Animation<double> _exitOpacity;
  late final Animation<double> _exitScale;

  bool _isReady = false;
  bool _splashDismissed = false;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1150),
    )..repeat(reverse: true);

    _pulseScale = Tween<double>(begin: 0.96, end: 1.03).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _pulseGlow = Tween<double>(begin: 0.45, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _exitController = AnimationController(
      vsync: this,
      duration: widget.exitDuration,
    );
    _exitOpacity = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _exitController, curve: Curves.easeOutCubic),
    );
    _exitScale = Tween<double>(begin: 1.0, end: 1.07).animate(
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
    final secondary = palette.secondaryFor(AppTabId.studio);
    final bgTop = palette.isDark
        ? const Color(0xFF171B2A)
        : Color.lerp(palette.surface, accent, 0.08)!;
    final bgBottom = palette.backgroundFor(AppTabId.studio);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: bgBottom,
        gradient: RadialGradient(
          center: const Alignment(0.0, -0.18),
          radius: 0.9,
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
                          Container(
                            width: 152,
                            height: 152,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  accent.withValues(
                                    alpha: 0.16 * _pulseGlow.value,
                                  ),
                                  secondary.withValues(
                                    alpha: 0.08 * _pulseGlow.value,
                                  ),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                          Transform.scale(
                            scale: _pulseScale.value,
                            child: child,
                          ),
                        ],
                      );
                    },
                    child: const CapSubLogoMark(size: 112),
                  ),
                  const SizedBox(height: 18),
                  ShaderMask(
                    shaderCallback: (bounds) => LinearGradient(
                      colors: [
                        palette.textPrimary,
                        accent,
                      ],
                    ).createShader(bounds),
                    child: Text(
                      'CapSub AI',
                      style: TextStyle(
                        color: palette.isDark ? Colors.white : palette.textPrimary,
                        fontSize: 23,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.4,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'Dịch phim & lồng tiếng thông minh',
                    style: TextStyle(
                      color: palette.textSecondary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.2,
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
                  SizedBox(
                    width: 132,
                    height: 3.5,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        backgroundColor: accent.withValues(alpha: 0.14),
                        valueColor: AlwaysStoppedAnimation<Color>(accent),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'STUDIO · HỒNG QUẢ · BILIBILI',
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
