import 'dart:math' as math;

import 'package:flutter/material.dart';

/// MD3 Expressive 风格波浪加载指示器（参考 Compose Material3 Expressive
/// 的 LoadingIndicator 视觉签名：环形半径按正弦波调制 + 呼吸幅度 +
/// 相位流动；UI_MD3_PLAN.md 参考风格目标）
///
/// - 常规：波浪流动 + 幅度呼吸，主色（colorScheme.primary）；
/// - 系统减少动画（MediaQuery.disableAnimations）时退化为静态 240° 弧；
/// - 语义标签经 [Semantics] 暴露给无障碍树。
class Md3LoadingIndicator extends StatefulWidget {
  /// 指示器外径（默认 48dp，M3 指示器规格）
  final double size;

  /// 描边宽度（默认随外径推导：size/10，夹在 2.5~6）
  final double? strokeWidth;

  /// 波浪颜色（默认 colorScheme.primary）
  final Color? color;

  /// 无障碍语义标签
  final String semanticsLabel;

  const Md3LoadingIndicator({
    super.key,
    this.size = 48,
    this.strokeWidth,
    this.color,
    this.semanticsLabel = '加载中',
  });

  @override
  State<Md3LoadingIndicator> createState() => _Md3LoadingIndicatorState();
}

class _Md3LoadingIndicatorState extends State<Md3LoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3600),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final strokeWidth = widget.strokeWidth ?? (widget.size / 10).clamp(2.5, 6);

    return Semantics(
      label: widget.semanticsLabel,
      child: ExcludeSemantics(
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: reduceMotion
              ? CustomPaint(
                  painter: _StaticArcPainter(
                    color: color,
                    strokeWidth: strokeWidth,
                  ),
                )
              : AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) => CustomPaint(
                    painter: _WavyRingPainter(
                      progress: _controller.value,
                      color: color,
                      strokeWidth: strokeWidth,
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// 波浪环画笔：r(θ) = R + amp(t)·sin(waves·θ − phase(t))
class _WavyRingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double strokeWidth;

  /// 波峰数（Expressive 波浪环观感近似）
  static const double _waves = 4.5;
  static const double _tau = math.pi * 2;

  _WavyRingPainter({
    required this.progress,
    required this.color,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    // 波峰外扩余量，避免裁切
    final maxAmp = strokeWidth * 1.6;
    final baseR = size.width / 2 - strokeWidth / 2 - maxAmp;

    // 相位流动（波沿环面传播 2 周/循环）
    final phase = progress * _tau * 2;
    // 幅度呼吸：0.55~1.0 慢正弦，体现 Expressive 的弹性律动
    final amp = maxAmp * (0.55 + 0.45 * (0.5 + 0.5 * math.sin(progress * _tau)));

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = color;

    final path = Path();
    const steps = 120;
    for (var i = 0; i <= steps; i++) {
      final theta = i / steps * _tau;
      final r = baseR + amp * math.sin(theta * _waves - phase);
      final x = center.dx + r * math.cos(theta);
      final y = center.dy + r * math.sin(theta);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_WavyRingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth;
}

/// 减少动画时的静态弧（240°，M3 determinate 观感）
class _StaticArcPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;

  _StaticArcPainter({required this.color, required this.strokeWidth});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - strokeWidth / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r),
      -math.pi / 2,
      math.pi * 2 * (240 / 360),
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_StaticArcPainter oldDelegate) => oldDelegate.color != color;
}
