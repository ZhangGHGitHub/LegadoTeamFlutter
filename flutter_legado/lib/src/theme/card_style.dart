// [设置批2b-1b-1 | 2026-11-01] 卡片圆角/边框与设置行分隔线的统一解析 — 全栈工程师
//
// 参考版证据：
// - `SplicedColumnGroup.kt:50-64`：圆角优先级 disable → override → 16dp；
//   边框开关开时 0 色回落 `colorScheme.outlineVariant`，宽度取
//   `baseCardBorderWidth`，日/夜各取 baseCardBorderColor(Night)。
// - `GlassCard.kt:78-96`：同一全局覆盖逻辑作用于基础卡片（Glass/Normal）。
// - `SettingItemDivider.kt:19-43`：长度 `itemDividerLength / 100f` 作为
//   `fillMaxWidth(fraction)`（百分比，不是 dp）；0 色回落
//   `Color.Gray.copy(alpha = 0.3f)`；线高 = `itemDividerWidth`。
//
// 本文件只放纯函数，便于单测；渲染接线见 `widgets/ios_widgets.dart`
//（IosGroup）与 `theme/app_theme.dart`（全局 CardTheme）。
import 'package:flutter/material.dart';

import '../providers/ui_settings/ui_settings_notifier.dart';

/// 拼接分组默认圆角（参考版 SplicedColumnGroup 非覆盖分支 16.dp）
const double kSplicedGroupDefaultCornerRadius = 16;

/// 全局 CardTheme 默认圆角（我方 MD3 Expressive 卡片档，不随分组开关变化）
const double kCardThemeDefaultCornerRadius = 20;

/// 分隔线 0 色回落色（参考版 `Color.Gray.copy(alpha = 0.3f)`）
const Color kItemDividerFallbackColor = Color(0xFF888888);

/// 拼接分组圆角：disable 优先 → override 取 baseCardCornerRadius → 16dp
double resolveSplicedGroupCornerRadius(UiSettingsState ui) {
  if (ui.disableSplicedColumnGroupCornerRadius) return 0;
  if (ui.overrideBaseCardCornerRadius) {
    return ui.baseCardCornerRadius.toDouble();
  }
  return kSplicedGroupDefaultCornerRadius;
}

/// 全局 CardTheme 圆角：override 取 baseCardCornerRadius → 20dp
///
/// `disableSplicedColumnGroupCornerRadius` 只作用于拼接分组，不影响其他
/// 基础卡片（参考版同一优先级链只出现在 SplicedColumnGroup 内）。
double resolveCardThemeCornerRadius(UiSettingsState ui) {
  if (ui.overrideBaseCardCornerRadius) {
    return ui.baseCardCornerRadius.toDouble();
  }
  return kCardThemeDefaultCornerRadius;
}

/// 基础卡片边框；开关关 / 宽度 0 → null（不绘制、不占布局）
///
/// 0 色回落主题 [ColorScheme.outlineVariant]（参考版 BorderStroke 分支）。
BorderSide? resolveBaseCardBorderSide(
  UiSettingsState ui,
  ColorScheme scheme, {
  required Brightness brightness,
  double widthExtra = 0,
}) {
  if (!ui.overrideBaseCardBorder) return null;
  final width = ui.baseCardBorderWidth.toDouble() + widthExtra;
  if (width <= 0) return null;
  final configured = brightness == Brightness.dark
      ? ui.baseCardBorderColorNight
      : ui.baseCardBorderColor;
  return BorderSide(
    color: configured != 0 ? Color(configured) : scheme.outlineVariant,
    width: width,
  );
}

/// 分隔线颜色：0 色回落灰色 30%（参考版 `Color.Gray.copy(alpha = 0.3f)`）
Color resolveItemDividerColor(int configured) {
  return configured != 0
      ? Color(configured)
      : kItemDividerFallbackColor.withValues(alpha: 0.3);
}

/// 分隔线长度占比：`itemDividerLength / 100`（参考版 fillMaxWidth(fraction)）
double resolveItemDividerWidthFraction(int lengthPercent) {
  return (lengthPercent / 100).clamp(0.0, 1.0);
}

/// 分隔线实际宽度（px/dp）：可用宽度 × 百分比
double resolveItemDividerLength(int lengthPercent, double availableWidth) {
  return availableWidth * resolveItemDividerWidthFraction(lengthPercent);
}
