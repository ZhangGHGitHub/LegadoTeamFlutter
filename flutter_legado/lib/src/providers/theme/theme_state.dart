import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'theme_state.freezed.dart';

/// 全局主题 UI 状态（immutable）
///
/// 对齐 Android 原版 ThemeConfigFragment：
/// - [themeMode]：主题模式（亮/暗/跟随系统），驱动 MaterialApp.themeMode 全局实时切换
/// - [fontScaleRaw]：字体缩放原始值（0 = 跟随系统；8~16 → 0.8x~1.6x，对齐 PreferKey.fontScale）
/// - [paletteId]：内置 MD3 调色板 id（UI_MD3_PLAN.md Batch 0，默认 WH；
///   与用户自定义 themeConfigList 并存，自定义已应用色优先 — 第九节）
@freezed
class ThemeState with _$ThemeState {
  const factory ThemeState({
    /// 主题模式（亮/暗/跟随系统）
    @Default(ThemeMode.system) ThemeMode themeMode,

    /// 字体缩放原始值（0 = 跟随系统；8~16 → 0.8x~1.6x）
    @Default(0) int fontScaleRaw,

    /// 内置 MD3 调色板 id（Md3Palettes.byId 消费；未知值回退 WH）
    @Default('wh') String paletteId,
  }) = _ThemeState;
}

/// 主题展示扩展 —— 纯派生计算，不改变数据内容
extension ThemeStateDerived on ThemeState {
  /// 是否跟随系统字体缩放（原始值换算后超出 0.8~1.6 有效范围）
  bool get isSystemFontScale {
    final scale = fontScaleRaw / 10.0;
    return scale < 0.8 || scale > 1.6;
  }

  /// 实际字体缩放倍数：跟随系统时返回 null（表示不覆盖系统缩放）
  double? get fontScale {
    if (isSystemFontScale) return null;
    return fontScaleRaw / 10.0;
  }

  /// 字体缩放展示文本（对齐原版 font_scale_summary「当前字体大小：%.1f」）
  String get fontScaleLabel {
    final scale = fontScale;
    if (scale == null) return '跟随系统';
    return '当前字体大小：${scale.toStringAsFixed(1)}';
  }
}
