library;

import 'package:flutter/material.dart' show Color;
import 'package:material_color_utilities/material_color_utilities.dart';

import 'md3_colors.dart';

/// [UI_SYNC_REFACTOR S4] 主题引擎参数化（对齐参考仓 ThemeEngine：
/// paletteStyle 9 档 + contrastLevel + isAmoled）
///
/// 参考链路：Custom 模式 customSeedColor → materialkolor 按 PaletteStyle
/// 生成全 scheme（Spec2021/2025）。Dart material_color_utilities 0.13
/// 提供 9 个 Scheme* 类（sourceColorHct/isDark/contrastLevel）——
/// **2025 spec 为 Kotlin materialkolor 独有，Dart 无对应实现**（登记差异，
/// materialVersion 设置暂映射 2021 spec）。

/// paletteStyle 档位（对齐参考 ThemeResolver.resolvePaletteStyle）
const List<String> kPaletteStyles = [
  'tonalSpot',
  'neutral',
  'vibrant',
  'expressive',
  'fidelity',
  'content',
  'rainbow',
  'fruitSalad',
  'monochrome',
];

/// 按参数生成明暗两套角色（seed=调色板锚点或自定义主色）
/// [contrastLevel] 0.0(Default)/0.5(Medium)/1.0(High)
({Md3Roles light, Md3Roles dark}) buildParameterizedRoles({
  required String style,
  required int seed,
  required double contrastLevel,
  bool amoledDark = false,
}) {
  final hct = Hct.fromInt(seed);
  DynamicScheme schemeFor(bool isDark) {
    switch (style) {
      case 'neutral':
        return SchemeNeutral(
            sourceColorHct: hct, isDark: isDark, contrastLevel: contrastLevel);
      case 'vibrant':
        return SchemeVibrant(
            sourceColorHct: hct, isDark: isDark, contrastLevel: contrastLevel);
      case 'expressive':
        return SchemeExpressive(
            sourceColorHct: hct, isDark: isDark, contrastLevel: contrastLevel);
      case 'fidelity':
        return SchemeFidelity(
            sourceColorHct: hct, isDark: isDark, contrastLevel: contrastLevel);
      case 'content':
        return SchemeContent(
            sourceColorHct: hct, isDark: isDark, contrastLevel: contrastLevel);
      case 'rainbow':
        return SchemeRainbow(
            sourceColorHct: hct, isDark: isDark, contrastLevel: contrastLevel);
      case 'fruitSalad':
        return SchemeFruitSalad(
            sourceColorHct: hct, isDark: isDark, contrastLevel: contrastLevel);
      case 'monochrome':
        return SchemeMonochrome(
            sourceColorHct: hct, isDark: isDark, contrastLevel: contrastLevel);
      case 'tonalSpot':
      default:
        return SchemeTonalSpot(
            sourceColorHct: hct, isDark: isDark, contrastLevel: contrastLevel);
    }
  }

  final light = _rolesFrom(schemeFor(false), false, amoledDark);
  final dark = _rolesFrom(schemeFor(true), true, amoledDark);
  return (light: light, dark: dark);
}

/// DynamicScheme → Md3Roles（ARGB int 映射；AMOLED 暗色纯黑覆写）
Md3Roles _rolesFrom(DynamicScheme scheme, bool isDark, bool amoledDark) {
  int argb(Color c) => c.toARGB32();
  // AMOLED 覆写辅助（非覆写集字段直接原值）
  return Md3Roles(
    primary: argb(Color(scheme.primary)),
    onPrimary: argb(Color(scheme.onPrimary)),
    primaryContainer: argb(Color(scheme.primaryContainer)),
    onPrimaryContainer: argb(Color(scheme.onPrimaryContainer)),
    secondary: argb(Color(scheme.secondary)),
    onSecondary: argb(Color(scheme.onSecondary)),
    secondaryContainer: argb(Color(scheme.secondaryContainer)),
    onSecondaryContainer: argb(Color(scheme.onSecondaryContainer)),
    tertiary: argb(Color(scheme.tertiary)),
    onTertiary: argb(Color(scheme.onTertiary)),
    tertiaryContainer: argb(Color(scheme.tertiaryContainer)),
    onTertiaryContainer: argb(Color(scheme.onTertiaryContainer)),
    error: argb(Color(scheme.error)),
    onError: argb(Color(scheme.onError)),
    errorContainer: argb(Color(scheme.errorContainer)),
    onErrorContainer: argb(Color(scheme.onErrorContainer)),
    background: _amooledOr(scheme.background, isDark, amoledDark, 0xFF000000),
    onBackground: argb(Color(scheme.onBackground)),
    surface: _amooledOr(scheme.surface, isDark, amoledDark, 0xFF000000),
    onSurface: argb(Color(scheme.onSurface)),
    surfaceVariant: argb(Color(scheme.surfaceVariant)),
    onSurfaceVariant: argb(Color(scheme.onSurfaceVariant)),
    outline: argb(Color(scheme.outline)),
    outlineVariant: argb(Color(scheme.outlineVariant)),
    scrim: argb(Color(scheme.scrim)),
    inverseSurface: argb(Color(scheme.inverseSurface)),
    inverseOnSurface: argb(Color(scheme.inverseOnSurface)),
    inversePrimary: argb(Color(scheme.inversePrimary)),
    primaryFixed: argb(Color(scheme.primaryFixed)),
    onPrimaryFixed: argb(Color(scheme.onPrimaryFixed)),
    primaryFixedDim: argb(Color(scheme.primaryFixedDim)),
    onPrimaryFixedVariant: argb(Color(scheme.onPrimaryFixedVariant)),
    secondaryFixed: argb(Color(scheme.secondaryFixed)),
    onSecondaryFixed: argb(Color(scheme.onSecondaryFixed)),
    secondaryFixedDim: argb(Color(scheme.secondaryFixedDim)),
    onSecondaryFixedVariant: argb(Color(scheme.onSecondaryFixedVariant)),
    tertiaryFixed: argb(Color(scheme.tertiaryFixed)),
    onTertiaryFixed: argb(Color(scheme.onTertiaryFixed)),
    tertiaryFixedDim: argb(Color(scheme.tertiaryFixedDim)),
    onTertiaryFixedVariant: argb(Color(scheme.onTertiaryFixedVariant)),
    surfaceDim: argb(Color(scheme.surfaceDim)),
    surfaceBright: argb(Color(scheme.surfaceBright)),
    surfaceContainerLowest: _amooledOr(scheme.surfaceContainerLowest, isDark, amoledDark, 0xFF000000),
    surfaceContainerLow: _amooledOr(scheme.surfaceContainerLow, isDark, amoledDark, 0xFF0A0A0A),
    surfaceContainer: _amooledOr(scheme.surfaceContainer, isDark, amoledDark, 0xFF0A0A0A),
    surfaceContainerHigh: _amooledOr(scheme.surfaceContainerHigh, isDark, amoledDark, 0xFF121212),
    surfaceContainerHighest: argb(Color(scheme.surfaceContainerHighest)),
  );
}

/// AMOLED 覆写辅助：暗色+AMOLED 时取覆写值，否则原值
int _amooledOr(int original, bool isDark, bool amoledDark, int override) {
  if (amoledDark && isDark) return override;
  return original;
}
