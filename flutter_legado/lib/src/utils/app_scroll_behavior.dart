import 'package:flutter/material.dart';

/// 全局滚动行为：所有列表统一 BouncingScrollPhysics
///
/// 对齐安卓原版滚动手感（回弹），移除 Material 默认的水波纹 overscroll 效果。
/// 在 MaterialApp 顶层通过 scrollBehavior 字段注册。
class AppScrollBehavior extends ScrollBehavior {
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const BouncingScrollPhysics();
  }

  /// 移除 Android 默认的水波纹 overscroll 指示器
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}
