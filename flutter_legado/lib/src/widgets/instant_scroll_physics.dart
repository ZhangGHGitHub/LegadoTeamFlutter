import 'package:flutter/material.dart';

/// 无动画滚动物理效果 - 页面切换无动画，瞬间完成
class InstantScrollPhysics extends ScrollPhysics {
  const InstantScrollPhysics({super.parent});

  @override
  InstantScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return InstantScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    // 如果有速度，直接跳到目标页面，无动画
    if ((velocity <= 0.0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0.0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    
    // 计算目标页面
    final double targetPage = _getPage(position.pixels, position.viewportDimension);
    final double targetPixels = targetPage * position.viewportDimension;
    
    // 返回一个瞬间完成的模拟
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      targetPixels,
      velocity,
      tolerance: const Tolerance(distance: 1.0, velocity: 1.0),
    );
  }

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    // 用户拖动时正常响应
    return offset;
  }

  double _getPage(double pixels, double viewportDimension) {
    return (pixels / viewportDimension).roundToDouble();
  }
}
