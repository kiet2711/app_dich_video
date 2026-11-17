import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Biểu trưng vector CapSub AI Studio đồng bộ với App Icon và Native Splash.
class CapSubLogoMark extends StatelessWidget {
  final double size;
  final bool showGlow;

  const CapSubLogoMark({
    super.key,
    this.size = 112,
    this.showGlow = true,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _CapSubLogoPainter(showGlow: showGlow),
      ),
    );
  }
}

class _CapSubLogoPainter extends CustomPainter {
  final bool showGlow;

  const _CapSubLogoPainter({required this.showGlow});

  @override
  void paint(Canvas canvas, Size size) {
    final u = math.min(size.width, size.height);
    final cx = size.width * 0.5;
    final cy = size.height * 0.5;

    final playCx = cx - u * 0.014;
    final playCy = cy - u * 0.060;
    final triR = u * 0.245;

    final vTop = Offset(playCx - triR * 0.72, playCy - triR * 0.96);
    final vBot = Offset(playCx - triR * 0.72, playCy + triR * 0.96);
    final vTip = Offset(playCx + triR * 1.04, playCy);

    if (showGlow) {
      final emeraldGlow = Paint()
        ..color = AppColors.primaryEmerald.withValues(alpha: 0.16)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, u * 0.14);
      canvas.drawCircle(
        Offset(playCx - u * 0.03, playCy - u * 0.03),
        u * 0.24,
        emeraldGlow,
      );

      final cyanGlow = Paint()
        ..color = AppColors.primaryEmeraldDark.withValues(alpha: 0.16)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, u * 0.14);
      canvas.drawCircle(
        Offset(playCx + u * 0.07, playCy + u * 0.05),
        u * 0.22,
        cyanGlow,
      );
    }

    // 1. Bóng echo xanh dương tạo chiều sâu nhẹ
    final echoOffset = Offset(u * 0.022, u * 0.0176);
    final echoPath = _buildRoundedTriangle(
      [vTop + echoOffset, vTip + echoOffset, vBot + echoOffset],
      u * 0.052,
    );
    final echoPaint = Paint()
      ..color = AppColors.primaryEmeraldDark.withValues(alpha: 0.34)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, u * 0.012);
    canvas.drawPath(echoPath, echoPaint);

    // 2. Tam giác Play bo tròn góc (Gradient Emerald -> Aqua -> Cyan)
    final playPath = _buildRoundedTriangle([vTop, vTip, vBot], u * 0.052);
    final playBounds = Rect.fromLTRB(vTop.dx, vTop.dy, vTip.dx, vBot.dy);
    final playPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          AppColors.primaryEmerald,
          Color(0xFF00E0B9),
          AppColors.primaryEmeraldDark,
        ],
        stops: [0.0, 0.5, 1.0],
      ).createShader(playBounds);
    canvas.drawPath(playPath, playPaint);

    // Highlight nhẹ nửa trên khối Play
    canvas.save();
    canvas.clipPath(playPath);
    final upperHighlight = Path()
      ..moveTo(vTop.dx, vTop.dy)
      ..lineTo(vTip.dx, vTip.dy)
      ..lineTo(playCx - triR * 0.72, playCy)
      ..close();
    canvas.drawPath(
      upperHighlight,
      Paint()..color = Colors.white.withValues(alpha: 0.11),
    );
    canvas.restore();

    // 3. Ngôi sao AI 4 cánh góc trên phải
    final starCenter = Offset(playCx + triR * 0.76, playCy - triR * 0.72);
    final starPath = _buildFourPointStar(starCenter, outerR: u * 0.088);
    if (showGlow) {
      canvas.drawPath(
        starPath,
        Paint()
          ..color = AppColors.accentGold.withValues(alpha: 0.45)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, u * 0.018),
      );
    }
    canvas.drawPath(starPath, Paint()..color = AppColors.accentGold);

    // 4. Hai thanh phụ đề song ngữ bên dưới nút Play
    final barH = u * 0.055;
    final barRadius = Radius.circular(barH * 0.5);
    final bar1Y = playCy + triR * 1.18;
    final bar1W = u * 0.44;
    final bar1Rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(cx - bar1W * 0.5, bar1Y, bar1W, barH),
      barRadius,
    );
    canvas.drawRRect(
      bar1Rect,
      Paint()..color = const Color(0xFFF4F7FC).withValues(alpha: 0.97),
    );

    final bar2Y = bar1Y + barH + u * 0.036;
    final seg1W = u * 0.145;
    final gap = u * 0.028;
    final seg2W = u * 0.175;
    final total2W = seg1W + gap + seg2W;
    final bar2X0 = cx - total2W * 0.5;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(bar2X0, bar2Y, seg1W, barH),
        barRadius,
      ),
      Paint()..color = AppColors.primaryEmerald,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(bar2X0 + seg1W + gap, bar2Y, seg2W, barH),
        barRadius,
      ),
      Paint()..color = AppColors.primaryEmeraldDark.withValues(alpha: 0.96),
    );
  }

  Path _buildRoundedTriangle(List<Offset> vertices, double radius) {
    final path = Path();
    final n = vertices.length;
    for (var i = 0; i < n; i++) {
      final prev = vertices[(i - 1 + n) % n];
      final curr = vertices[i];
      final next = vertices[(i + 1) % n];

      final v1 = prev - curr;
      final v2 = next - curr;
      final len1 = v1.distance;
      final len2 = v2.distance;
      final d = math.min(radius, math.min(len1 * 0.42, len2 * 0.42));

      final a = curr + (v1 / len1) * d;
      final b = curr + (v2 / len2) * d;

      if (i == 0) {
        path.moveTo(a.dx, a.dy);
      } else {
        path.lineTo(a.dx, a.dy);
      }
      path.quadraticBezierTo(curr.dx, curr.dy, b.dx, b.dy);
    }
    path.close();
    return path;
  }

  Path _buildFourPointStar(Offset center, {required double outerR}) {
    final innerR = outerR * 0.25;
    final cardinals = [
      Offset(center.dx, center.dy - outerR),
      Offset(center.dx + innerR, center.dy - innerR),
      Offset(center.dx + outerR, center.dy),
      Offset(center.dx + innerR, center.dy + innerR),
      Offset(center.dx, center.dy + outerR),
      Offset(center.dx - innerR, center.dy + innerR),
      Offset(center.dx - outerR, center.dy),
      Offset(center.dx - innerR, center.dy - innerR),
    ];

    final path = Path()..moveTo(cardinals[0].dx, cardinals[0].dy);
    for (var i = 0; i < 4; i++) {
      final mid = cardinals[i * 2 + 1];
      final tipNext = cardinals[(i * 2 + 2) % 8];
      final ctrl = Offset(
        center.dx + (mid.dx - center.dx) * 0.65,
        center.dy + (mid.dy - center.dy) * 0.65,
      );
      path.quadraticBezierTo(ctrl.dx, ctrl.dy, tipNext.dx, tipNext.dy);
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(covariant _CapSubLogoPainter oldDelegate) =>
      oldDelegate.showGlow != showGlow;
}

