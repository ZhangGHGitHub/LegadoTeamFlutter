import 'package:flutter/material.dart';

/// 自定义下拉刷新组件
///
/// 封装 Flutter 的 [RefreshIndicator]，配置与安卓端 SwipeRefreshLayout 一致的视觉参数。
/// 安卓端书架使用 `binding.refreshLayout.setColorSchemeColors(accentColor)` 设置刷新颜色，
/// 此组件使用主题色 [Theme.of(context).colorScheme.primary] 实现相同效果。
class CustomRefreshIndicator extends StatelessWidget {
  /// 子组件
  final Widget child;

  /// 刷新回调
  final Future<void> Function() onRefresh;

  /// 是否启用下拉刷新
  final bool enabled;

  const CustomRefreshIndicator({
    super.key,
    required this.child,
    required this.onRefresh,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    // 禁用时直接返回子组件，不包裹刷新指示器
    if (!enabled) return child;

    final colorScheme = Theme.of(context).colorScheme;

    return RefreshIndicator(
      onRefresh: onRefresh,
      // 下拉触发距离，与安卓 SwipeRefreshLayout 默认值一致（约 64dp）
      displacement: 64.0,
      // 指示器颜色：使用主题主色，对应安卓端的 accentColor
      color: colorScheme.primary,
      // 指示器背景色：使用表面色
      backgroundColor: colorScheme.surface,
      // 线条宽度：与安卓 SwipeRefreshLayout 默认 CircularProgressDrawable 一致（约 2.5）
      strokeWidth: 2.5,
      // 触发模式：与安卓端一致，在任意位置下拉均可触发
      triggerMode: RefreshIndicatorTriggerMode.anywhere,
      child: child,
    );
  }
}
