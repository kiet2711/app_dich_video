import 'package:flutter/material.dart';

/// Biểu trưng Ksub hiệu ứng Liquid Glass đồng bộ với App Icon và Native Splash.
class KsubLogoMark extends StatelessWidget {
  final double size;
  final bool showGlow;
  final bool showPedestal;

  const KsubLogoMark({
    super.key,
    this.size = 112,
    this.showGlow = true,
    this.showPedestal = true,
  });

  @override
  Widget build(BuildContext context) {
    final emblem = Image.asset(
      'assets/images/ksub_logo.png',
      width: size * (showPedestal ? 0.78 : 1.0),
      height: size * (showPedestal ? 0.78 : 1.0),
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );

    if (!showPedestal) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(child: emblem),
      );
    }

    final radius = size * 0.245;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: const RadialGradient(
          center: Alignment(0.0, -0.15),
          radius: 0.92,
          colors: [Color(0xFF101014), Color(0xFF000000)],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.22),
          width: 1.1,
        ),
        boxShadow: [
          if (showGlow)
            BoxShadow(
              color: const Color(0xFFF9021A).withValues(alpha: 0.22),
              blurRadius: size * 0.26,
              offset: Offset(0, size * 0.08),
            ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.34),
            blurRadius: size * 0.22,
            offset: Offset(0, size * 0.10),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.15),
                    Colors.transparent,
                    const Color(0xFFF9021A).withValues(alpha: 0.07),
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
          ),
          emblem,
        ],
      ),
    );
  }
}
