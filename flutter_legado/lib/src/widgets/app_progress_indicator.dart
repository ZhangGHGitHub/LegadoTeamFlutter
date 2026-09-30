import 'package:flutter/material.dart';

import 'contained_loading_indicator.dart';

/// [STAGE-UI-P43UNIFY2 B3] 应用级加载指示器统一封装三件套
///
/// 对齐参考版 `progressIndicator/` 三件套命名
///（legado-with-MD3 `.../ui/widget/components/progressIndicator/`）：
/// - [AppCircularProgressIndicator] ↔ `AppCircularProgressIndicator.kt`
///   （`progress: Float? = null` 确定性 / `strokeWidth: Dp = 4.dp` 默认 4dp）
/// - [AppLinearProgressIndicator] ↔ `AppLinearProgressIndicator.kt`
///   （`progress: Float? = null`，无独立线宽参数）
/// - [AppContainedLoadingIndicator] ↔ `AppContainedLoadingIndicator.kt`
///   （MD3 Expressive ContainedLoadingIndicator；本仓实现委托既有
///   [ContainedLoadingIndicator]，签名已对齐，属调研报告 §4.3 勿误改项，
///   此处仅做三件套命名对齐出口）
///
/// **双引擎裁决（本批取证）**：参考版三件套均有
/// `ThemeResolver.isMiuixEngine(composeEngine)` 双引擎分支（Miuix 引擎走
/// MiuixCircularProgressIndicator / MiuixLinearProgressIndicator /
/// InfiniteProgressIndicator，否则走 MD3）。我方现状取证（全仓 grep
/// 无 Miuix 实现，[theme_engine_parameterized](../theme/theme_engine_parameterized.dart)
/// 仅为 MD3 9 档调色板参数化，非风格引擎切换）→ **本封装只实现 MD3 路径**；
/// Miuix 分支登记待「风格切换」批接线，此处不造无消费者分支。
///
/// **线宽口径（B4 取证）**：参考版 34 处 `AppCircularProgressIndicator`
/// 调用 0 处覆盖 `strokeWidth`（3 处多行调用亦仅传 modifier）→ 参考主流
/// 即默认 4dp。本封装默认 `strokeWidth = 4.0` 对齐参考默认；我方现有
/// `strokeWidth: 2` 调用点（38 处）换接时**保留 2dp 实参**
///（`AppCircularProgressIndicator(strokeWidth: 2)`），不机械全改 4dp，
/// 避免既有细环视觉抖动。
///
/// **色槽**：默认走 `Theme.of(context).colorScheme.primary`（与参考版
/// 「色全部走主题槽，无硬编码」一致）；显式传 [AppCircularProgressIndicator.color]
/// 可覆盖。

/// 应用级圆形加载指示器（MD3 路径）
///
/// - [progress] 为 0.0~1.0 的确定性进度（对齐参考版 `progress: Float?`
///   语义；`null` = indeterminate 不定态转圈）；
/// - 颜色默认 `colorScheme.primary` 主题槽（参考版无硬编码色）；
/// - [strokeWidth] 默认 4.0（对齐参考版 4dp 默认；细环调用点显式传 2）。
class AppCircularProgressIndicator extends StatelessWidget {
  /// 确定性进度（0.0~1.0）；`null` 为 indeterminate
  final double? progress;

  /// 描边宽度（默认 4.0，对齐参考版默认 4dp）
  final double strokeWidth;

  /// 环颜色（默认 null → colorScheme.primary 主题槽）
  final Color? color;

  /// 无障碍语义标签
  final String semanticsLabel;

  const AppCircularProgressIndicator({
    super.key,
    this.progress,
    this.strokeWidth = 4.0,
    this.color,
    this.semanticsLabel = '加载中',
  });

  @override
  Widget build(BuildContext context) {
    // 不强加尺寸、不显式解析色：布局行为与裸用 CircularProgressIndicator
    // 完全一致（按调用点约束展开）；color 透传（null = 组件默认主题槽
    // colorScheme.primary），保留「color == null 即主题槽」的取证口径
    //（reader_comic_loading_theme_test B2 断言依赖）。参考版三件套
    // 「色全部走主题槽，无硬编码」语义等价。
    return Semantics(
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: progress == null
            ? CircularProgressIndicator(
                strokeWidth: strokeWidth,
                color: color,
              )
            : CircularProgressIndicator(
                value: progress,
                strokeWidth: strokeWidth,
                color: color,
              ),
      ),
    );
  }
}

/// 应用级线性加载指示器（MD3 路径）
///
/// - [progress] 为 0.0~1.0 的确定性进度（对齐参考版 `progress: Float?`
///   语义；`null` = indeterminate）；
/// - 参考版本件套无线宽参数，本封装对齐（SDK 3.44 `LinearProgressIndicator`
///   亦无线宽形参）；保留 [minHeight] 透传，供调用点已有细线实参
///   （如 `minHeight: 2`）时保留视觉不变。
class AppLinearProgressIndicator extends StatelessWidget {
  /// 确定性进度（0.0~1.0）；`null` 为 indeterminate
  final double? progress;

  /// 最小高度（透传 `LinearProgressIndicator.minHeight`）
  final double? minHeight;

  /// 条颜色（默认 null → colorScheme.primary 主题槽）
  final Color? color;

  /// 无障碍语义标签
  final String semanticsLabel;

  const AppLinearProgressIndicator({
    super.key,
    this.progress,
    this.minHeight,
    this.color,
    this.semanticsLabel = '加载中',
  });

  @override
  Widget build(BuildContext context) {
    // color 透传（null = 组件默认主题槽 colorScheme.primary），同 circular
    return Semantics(
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: LinearProgressIndicator(
          // 确定性 value 语义 0.0~1.0（SDK 线性指示器 value 即 0~1 比例）
          value: progress,
          minHeight: minHeight,
          color: color,
        ),
      ),
    );
  }
}

/// 应用级容器加载指示器（MD3 Expressive 等效）
///
/// 对齐参考版 `AppContainedLoadingIndicator`（MD3 分支 = M3 Expressive
/// `ContainedLoadingIndicator`；Miuix 分支 = `InfiniteProgressIndicator`
/// ——登记待风格切换批）。本仓 MD3 实现由既有 [ContainedLoadingIndicator]
/// 承载（调研报告 §4.3 勿误改项，签名已对齐），此处为三件套命名对齐出口。
class AppContainedLoadingIndicator extends StatelessWidget {
  /// 容器边长（默认 48dp，M3 指示器规格）
  final double size;

  /// 内置环描边宽度（默认 3.0）
  final double strokeWidth;

  /// 内置环颜色（默认 colorScheme.primary）
  final Color? color;

  /// 无障碍语义标签
  final String semanticsLabel;

  const AppContainedLoadingIndicator({
    super.key,
    this.size = 48,
    this.strokeWidth = 3.0,
    this.color,
    this.semanticsLabel = '加载中',
  });

  @override
  Widget build(BuildContext context) {
    return ContainedLoadingIndicator(
      size: size,
      strokeWidth: strokeWidth,
      color: color,
      semanticsLabel: semanticsLabel,
    );
  }
}
