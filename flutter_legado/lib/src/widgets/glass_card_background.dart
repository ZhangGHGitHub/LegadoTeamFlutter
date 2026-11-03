// [设置批2b-1b-2b | 2026-11-03] 项目（卡片）背景图图层 — 全栈工程师 + UI
//
// 语义基准（参考版 legado-with-MD3）：
// - `GlassCard.kt:36-53`：`BaseCardContent` 在 `useItemBackground=true` 时
//   用 `Box` 叠一层 `Spacer(matchParentSize, clip(shape),
//   appContainerBackground(Item))`，内容列在其上；即图片层**位于卡面色
//   之上、内容之下**，圆角与卡片一致。
// - `GlassCard.kt:128-160`：`GlassCard` 固定 `useItemBackground=true`，
//   `SettingCard.kt` 复用 GlassCard → 设置行卡（项目卡面）自动带项目图；
//   `NormalCard` 不带。
// - `AppContainerBackground.kt:51-63`：Item 图取当前亮暗的
//   `itemBackgroundImageLight/Dark`，受 `enableContainerBackgroundImage`
//   总开关约束，alpha = `glassCardBackgroundOpacity / 100f`；
//   `.9.png` 用 NinePatchFillBounds，其余 Crop。
// - 图片层 `IgnorePointer`，不拦截行点击。
import 'package:flutter/material.dart';

import '../providers/ui_settings/ui_settings_notifier.dart';
import '../services/theme_background_image_store.dart';
import 'nine_patch.dart';

/// 当前亮暗模式下的项目背景图偏好值（空=未设置）
String itemBackgroundStoredValue(UiSettingsState ui, Brightness brightness) {
  return brightness == Brightness.dark
      ? ui.itemBackgroundImageDark
      : ui.itemBackgroundImageLight;
}

/// 项目背景图当前是否应渲染（总开关开 + 文件可用）
///
/// 总开关与参考版 `AppContainerBackground.kt:51` 同口径：Large/Item 图共用
/// `enableContainerBackgroundImage`。
bool hasUsableItemBackground(UiSettingsState ui, Brightness brightness) {
  if (!ui.enableContainerBackgroundImage) return false;
  return ThemeBackgroundImageStore.isUsableSync(
    itemBackgroundStoredValue(ui, brightness),
  );
}

/// 项目背景图图层：卡面色之上、内容之下
///
/// - [path] 为已解析的绝对路径（空串/不可用时渲染空盒，不占布局）；
/// - [opacityPercent] 为 `glassCardBackgroundOpacity`（0..100，独立于
///   `containerOpacity`）：100 时图片完全覆盖卡面色，0 时完全透明；
/// - [borderRadius] 与卡片圆角一致，图片被同半径裁剪；
/// - 图层 `IgnorePointer`，不拦截点击/手势。
class GlassCardBackground extends StatelessWidget {
  final String path;
  final int opacityPercent;
  final BorderRadius borderRadius;

  /// 绘制透明度节点 key（测试/诊断用；同父级多实例时由调用方区分）
  final Key? opacityKey;

  /// 图片节点 key（测试/诊断用）
  final Key? imageKey;

  const GlassCardBackground({
    super.key,
    required this.path,
    required this.opacityPercent,
    this.borderRadius = BorderRadius.zero,
    this.opacityKey,
    this.imageKey,
  });

  @override
  Widget build(BuildContext context) {
    if (path.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: Opacity(
        key: opacityKey,
        opacity: (opacityPercent / 100).clamp(0.0, 1.0),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: buildBackgroundImage(
            key: imageKey,
            context: context,
            path: path,
          ),
        ),
      ),
    );
  }
}
