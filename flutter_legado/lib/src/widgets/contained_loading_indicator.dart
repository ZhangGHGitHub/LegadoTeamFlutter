import 'package:flutter/material.dart';

/// M3 Expressive ContainedLoadingIndicator 等效组件
///
/// 对齐 Compose Material3 Expressive 的 ContainedLoadingIndicator 视觉签名：
/// 固定 48dp 容器 + 内置 CircularProgressIndicator（primary），容器底为
/// surfaceContainer，形状为全圆角（24dp），供列表行内/小区域加载复用。
// [LAYOUT_PLAN P4] 新增 Contained 等效组件，高频小 spinner 统一入口
class ContainedLoadingIndicator extends StatelessWidget {
  /// 容器边长（默认 48dp，M3 指示器规格）
  final double size;

  /// 内置环的描边宽度（默认 3.0）
  final double strokeWidth;

  /// 内置环颜色（默认 colorScheme.primary）
  final Color? color;

  /// 无障碍语义标签
  final String semanticsLabel;

  const ContainedLoadingIndicator({
    super.key,
    this.size = 48,
    this.strokeWidth = 3.0,
    this.color,
    this.semanticsLabel = '加载中',
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      label: semanticsLabel,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(size / 2),
        ),
        child: Center(
          child: SizedBox(
            width: size / 2,
            height: size / 2,
            child: CircularProgressIndicator(
              strokeWidth: strokeWidth,
              color: color ?? colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}
