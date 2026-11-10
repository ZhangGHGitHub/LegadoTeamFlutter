// [批13 | 2026-11-10] 主题配色 JSON 导出/导入编解码 — 全栈工程师 + UI
//
// 设置页「导出主题 / 导入主题」与 themeConfigList 的配色字段共用本服务，
// 把内联在 UI 方法里的 JSON 构造/解析抽出来，便于对「导出 → 编码 → 解码 →
// 应用」做真实往返测试（不依赖 FilePicker / 文件保存插件）。
//
// 槽位构成登记：日/夜各 6 槽，但第 6 槽我方为**底部操作栏颜色**
// （colorBottomBackground），参考版为**标签容器色**
// （colorMD3SurfaceContainerLow / labelContainerColor）——数量对齐、构成
// 不同，禁止表述为「与参考 12 色槽完全一致」。本批只补字体色两槽。
import 'package:flutter/material.dart';

import '../constants/pref_keys.dart';
import '../providers/theme/theme_colors_notifier.dart';

/// 主题配色 JSON 编解码
///
/// 导出结构（version 1）：
/// ```json
/// {
///   "app": "legado", "type": "theme", "version": 1,
///   "paletteId": "def", "themeMode": "system",
///   "day":   {"primary": 0, "accent": 0, "primaryText": 0,
///             "secondaryText": 0, "background": 0, "bottomBackground": 0},
///   "night": {"primary": 0, ... 同构 ...}
/// }
/// ```
/// 导入为宽松解析：缺组/缺字段/非数值 → null，`applyColors` 按 0 清除，
/// 旧版主题 JSON（无字体色字段）与参考版备份（未设置槽写 0）均不报错。
abstract final class ThemeConfigJson {
  ThemeConfigJson._();

  /// ThemeMode → JSON 名称
  static String themeModeName(ThemeMode mode) => switch (mode) {
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
    _ => 'system',
  };

  /// JSON 名称 → ThemeMode（未知/缺省返回 null，导入端保持原值）
  static ThemeMode? themeModeFromName(dynamic name) => switch (name) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    'system' => ThemeMode.system,
    _ => null,
  };

  /// JSON 数值容错转换：非数值/缺字段返回 null（= 未设置，按 0 处理）
  static int? asInt(dynamic value) =>
      value is int ? value : (value is num ? value.toInt() : null);

  /// 构造导出 JSON：paletteId + 主题模式 + 日/夜各 6 槽
  ///
  /// 字体色槽位以 0 导出（0 = 未设置，与参考版语义及旧导入端兼容）。
  static Map<String, dynamic> buildExportPayload({
    required ThemeColorsState colors,
    required String paletteId,
    required ThemeMode themeMode,
  }) {
    return <String, dynamic>{
      'app': 'legado',
      'type': 'theme',
      'version': 1,
      'paletteId': paletteId,
      'themeMode': themeModeName(themeMode),
      'day': <String, int?>{
        'primary': colors.primary,
        'accent': colors.accent,
        'primaryText': colors.primaryTextColor,
        'secondaryText': colors.secondaryTextColor,
        'background': colors.background,
        'bottomBackground': colors.bottomBackground,
      },
      'night': <String, int?>{
        'primary': colors.primaryNight,
        'accent': colors.accentNight,
        'primaryText': colors.primaryTextColorNight,
        'secondaryText': colors.secondaryTextColorNight,
        'background': colors.backgroundNight,
        'bottomBackground': colors.bottomBackgroundNight,
      },
    };
  }

  /// 导入 JSON → `applyColors` 入参（日/夜各 6 槽）
  ///
  /// 缺组/缺字段/非数值统一返回 null（清除）；显式 0 同样由
  /// `applyColors` 归一为清除。
  static Map<String, int?> decodeColors(Map<String, dynamic> decoded) {
    final dayMap = decoded['day'] is Map<String, dynamic>
        ? decoded['day'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final nightMap = decoded['night'] is Map<String, dynamic>
        ? decoded['night'] as Map<String, dynamic>
        : const <String, dynamic>{};
    return <String, int?>{
      PrefKeys.cPrimary: asInt(dayMap['primary']),
      PrefKeys.cAccent: asInt(dayMap['accent']),
      PrefKeys.cPrimaryText: asInt(dayMap['primaryText']),
      PrefKeys.cSecondaryText: asInt(dayMap['secondaryText']),
      PrefKeys.cBackground: asInt(dayMap['background']),
      PrefKeys.cBBackground: asInt(dayMap['bottomBackground']),
      PrefKeys.cNPrimary: asInt(nightMap['primary']),
      PrefKeys.cNAccent: asInt(nightMap['accent']),
      PrefKeys.cNPrimaryText: asInt(nightMap['primaryText']),
      PrefKeys.cNSecondaryText: asInt(nightMap['secondaryText']),
      PrefKeys.cNBackground: asInt(nightMap['background']),
      PrefKeys.cNBBackground: asInt(nightMap['bottomBackground']),
    };
  }
}
