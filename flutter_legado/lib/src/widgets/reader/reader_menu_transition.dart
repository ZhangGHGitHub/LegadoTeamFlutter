import 'package:flutter/material.dart';

/// [UI_SYNC_REFACTOR B5] 阅读菜单进出场统一封装
///
/// 对齐参考仓 ReadBookRouteScreen（enter = fadeIn(tween 180) +
/// scaleIn(tween 220, initialScale 0.88)；exit = fadeOut(140) +
/// scaleOut(180, targetScale 0.88)）。
///
/// 本组件承载**进场**（挂载即从 0.88 缩放 + 全透明过渡到位）；退出侧因
/// 阅读器 showControls 条件挂载为即时卸载，退出动画登记差异（后续批接
/// 双向 AnimatedSwitcher）。替代旧 AnimatedSlide+AnimatedOpacity 组合。
class ReaderMenuTransition extends StatefulWidget {
  final Widget child;

  const ReaderMenuTransition({super.key, required this.child});

  @override
  State<ReaderMenuTransition> createState() => _ReaderMenuTransitionState();
}

class _ReaderMenuTransitionState extends State<ReaderMenuTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // scale 用 220ms 全程，fade 用 180ms（前 82%）——对齐参考仓双时长
    final scale = Tween<double>(begin: 0.88, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.fastOutSlowIn),
    );
    final fade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.82, curve: Curves.easeOut),
      ),
    );
    return FadeTransition(
      opacity: fade,
      child: ScaleTransition(
        scale: scale,
        alignment: Alignment.bottomCenter,
        child: widget.child,
      ),
    );
  }
}
