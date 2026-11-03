// 阅读器菜单系统样式模型与配色解析（批3a）
//
// 参考依据（legado-with-MD3，源码路径以 docs/REFACTORING_ACTIVE_PLAN.md
// 批3a 登记为准）：
// - `ui/book/read/sheet/SystemMenuPage.kt`：全局 / 底栏布局 / 顶栏布局三子页；
// - `ui/book/read/ReadBookMenuBarBottom.kt:200-290`：每行图标数、行数、
//   溢出分页、行距 12dp、按钮 40dp、图标 20dp、文字在图标下 2dp；
// - `ui/book/read/ReadBookMenuBarTitle.kt`：titleBarMode 四档、标题胶囊、
//   合并按钮、图标三态（0 透明 / 1 surfaceContainerLow 圆底 / 2 描边）；
// - `ui/book/read/ReadBookColorTheme.kt:100-330`：readBarStyle 三档与
//   readMenuColorMode 两种取色来源；
// - `domain/model/settings/ReadSettings.kt:60-135`：默认值；
// - `res/values/arrays.xml` paletteStyle：9 档调色板。
//
// 编码约定：
// - 所有颜色以 ARGB int 持久化，`0` = 跟随主题/回落（不是透明黑）；
// - 取色器写入 `0xFFRRGGBB`；历史/第三方数据若为 `0x00RRGGBB`（alpha=0
//   的纯 RGB）按不透明处理，避免「选过色却看不见」；
// - 旧键 `readBarStyleFollowPage` 仅在新键 `readBarStyle` 缺失时迁移
//   （见 ReaderMenuStyleNotifier），本文件只负责模型与纯函数解析。
//
// 编写：全栈工程师（批3a） ｜ 2026-11-04
import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/material.dart' show Color, ColorScheme;

import '../../constants/pref_keys.dart';
import '../../theme/md3_colors.dart';
import '../../theme/theme_engine_parameterized.dart';

/// 工具栏样式（readBarStyle）
abstract final class ReaderMenuBarStyle {
  /// 跟随系统（Material 主题）
  static const int system = 0;

  /// 跟随阅读背景（底色/文字取阅读页）
  static const int followPage = 1;

  /// 自定义（种子色或自定义主题色）
  static const int custom = 2;
}

/// 菜单颜色来源（readMenuColorMode）
abstract final class ReaderMenuColorMode {
  /// 由强调色（种子）生成整套 scheme
  static const int seed = 0;

  /// 用户逐项指定背景/强调/容器/文字
  static const int custom = 1;
}

/// 图标容器样式（readMenuIconStyle / titleBarIconStyle）
abstract final class ReaderMenuIconStyle {
  /// 无底衬
  static const int plain = 0;

  /// surfaceContainerLow 圆底
  static const int tonal = 1;

  /// 1dp onSurfaceVariant@45% 描边
  static const int outlined = 2;
}

/// 菜单模糊模式（readMenuTopBarBlurMode / readMenuBottomBarBlurMode）
abstract final class ReaderMenuBlurMode {
  /// 不模糊（实色）
  static const int none = 0;

  /// BackdropFilter + 半透明底色
  static const int haze = 1;

  /// 液态玻璃近似（模糊 + 高光描边 + 镜面渐变）
  static const int liquidGlass = 2;
}

/// 菜单模糊风格（readMenuTopBarBlurStyle / readMenuBottomBarBlurStyle）
abstract final class ReaderMenuBlurStyle {
  /// 均匀半透明
  static const int solid = 0;

  /// 边缘更实、中部更透的线性渐变（近似）
  static const int progressive = 1;
}

/// 顶栏标题显示方式（titleBarMode）
abstract final class ReaderMenuTitleBarMode {
  /// 书名显示在顶栏行内
  static const String inTopBar = '0';

  /// 书名另起一行
  static const String ownLine = '1';

  /// 仅显示章节
  static const String chapterOnly = '2';

  /// 不显示标题/章节
  static const String hidden = '3';

  static const List<String> values = [inTopBar, ownLine, chapterOnly, hidden];

  static String normalize(String raw) {
    final value = raw.trim();
    return values.contains(value) ? value : inTopBar;
  }
}

/// 调色板显示名（与 kPaletteStyles 同序；用于设置页下拉）
const Map<String, String> kReaderMenuPaletteLabels = {
  '': '跟随系统',
  'tonalSpot': 'TonalSpot',
  'neutral': 'Neutral',
  'vibrant': 'Vibrant',
  'expressive': 'Expressive',
  'rainbow': 'Rainbow',
  'fruitSalad': 'FruitSalad',
  'monochrome': 'Monochrome',
  'fidelity': 'Fidelity',
  'content': 'Content',
};

/// 把参考版 `arrays.xml paletteStyle`（首字母大写/驼峰）或任意历史值
/// 归一化为 `theme_engine_parameterized.dart` 的 kPaletteStyles 键。
String normalizeReaderMenuPaletteStyle(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return 'tonalSpot';
  for (final key in kPaletteStyles) {
    if (key.toLowerCase() == value.toLowerCase()) return key;
  }
  return 'tonalSpot';
}

/// 菜单颜色不透明化：0 保留为「未设置」，`0x00RRGGBB` 视为不透明 RGB，
/// 其余 alpha 一律拉满到 0xFF。
int normalizeReaderMenuColor(int argb) {
  // 0 保留「未设置」；其余颜色统一拉满 alpha（含历史 0x00RRGGBB 纯 RGB）
  if (argb == 0) return 0;
  return 0xFF000000 | (argb & 0x00FFFFFF);
}

/// 阅读器菜单样式（不可变值对象）
@immutable
class ReaderMenuStyle {
  /// 底栏图标文字（图标下 2dp，labelSmall）
  final bool showIconText;

  /// 底栏每行图标数（2..8）
  final int itemsPerRow;

  /// 底栏图标行数（1..2）
  final int rowCount;

  /// 底栏图标容器样式（0/1/2）
  final int iconStyle;

  /// 浮动底栏（16dp 边距 + 四角圆角）或贴底全宽（仅上圆角）
  final bool floatingBottomBar;

  /// 底栏圆角（0..32）
  final int bottomCornerRadius;

  /// 工具栏样式（0 系统 / 1 跟随阅读背景 / 2 自定义）
  final int readBarStyle;

  /// 菜单颜色来源（0 种子 / 1 自定义）
  final int colorMode;

  /// 调色板（'' = 跟随系统；其余 kPaletteStyles 键）
  final String paletteStyle;

  /// 自定义颜色（ARGB，0 = 跟随/回落）
  final int bgColor;
  final int bgColorNight;
  final int accentColor;
  final int accentColorNight;
  final int containerColor;
  final int containerColorNight;
  final int textColor;
  final int textColorNight;

  /// 顶栏标题胶囊
  final bool titleCapsule;

  /// 顶栏标题显示方式（'0'..'3'）
  final String titleBarMode;

  /// 顶栏动作合并进单个胶囊
  final bool mergeButtons;

  /// 顶栏图标容器样式（0/1/2，独立于底栏）
  final int titleIconStyle;

  /// 菜单边框宽度（0 关闭，1..4）
  final int borderWidth;

  /// 菜单边框颜色（ARGB，0=outlineVariant）
  final int borderColor;
  final int borderColorNight;

  /// 菜单模糊半径 dp（0..32）
  final int blurRadius;

  /// 菜单背景透明度百分比（0..100，用于 alpha/100）
  final int blurAlpha;

  /// 菜单模糊底色（ARGB，0=跟随菜单背景）
  final int blurColor;
  final int blurColorNight;

  /// 顶/底栏模糊模式（0 None / 1 Haze / 2 LiquidGlass）
  final int topBarBlurMode;
  final int bottomBarBlurMode;

  /// 顶/底栏模糊风格（0 Solid / 1 Progressive）
  final int topBarBlurStyle;
  final int bottomBarBlurStyle;

  /// 顶/底栏按钮液态玻璃（近似）
  final bool topBarLiquidGlassButtons;
  final bool bottomBarLiquidGlassButtons;

  /// 顶栏紧凑模式：仅保留「更多」动作
  final bool titleBarCompact;

  ReaderMenuStyle({
    this.showIconText = false,
    int itemsPerRow = 5,
    int rowCount = 1,
    int iconStyle = ReaderMenuIconStyle.plain,
    this.floatingBottomBar = true,
    int bottomCornerRadius = 32,
    int readBarStyle = ReaderMenuBarStyle.followPage,
    int colorMode = ReaderMenuColorMode.custom,
    this.paletteStyle = '',
    int bgColor = 0,
    int bgColorNight = 0,
    int accentColor = 0,
    int accentColorNight = 0,
    int containerColor = 0,
    int containerColorNight = 0,
    int textColor = 0,
    int textColorNight = 0,
    this.titleCapsule = false,
    String titleBarMode = ReaderMenuTitleBarMode.inTopBar,
    this.mergeButtons = false,
    int titleIconStyle = ReaderMenuIconStyle.plain,
    int borderWidth = 1,
    int borderColor = 0,
    int borderColorNight = 0,
    int blurRadius = 24,
    int blurAlpha = 85,
    int blurColor = 0,
    int blurColorNight = 0,
    int topBarBlurMode = ReaderMenuBlurMode.none,
    int bottomBarBlurMode = ReaderMenuBlurMode.none,
    int topBarBlurStyle = ReaderMenuBlurStyle.solid,
    int bottomBarBlurStyle = ReaderMenuBlurStyle.solid,
    this.topBarLiquidGlassButtons = false,
    this.bottomBarLiquidGlassButtons = false,
    this.titleBarCompact = false,
  }) : itemsPerRow = itemsPerRow.clamp(2, 8),
       rowCount = rowCount.clamp(1, 2),
       iconStyle = iconStyle.clamp(0, 2),
       bottomCornerRadius = bottomCornerRadius.clamp(0, 32),
       readBarStyle = readBarStyle.clamp(0, 2),
       colorMode = colorMode.clamp(0, 1),
       bgColor = normalizeReaderMenuColor(bgColor),
       bgColorNight = normalizeReaderMenuColor(bgColorNight),
       accentColor = normalizeReaderMenuColor(accentColor),
       accentColorNight = normalizeReaderMenuColor(accentColorNight),
       containerColor = normalizeReaderMenuColor(containerColor),
       containerColorNight = normalizeReaderMenuColor(containerColorNight),
       textColor = normalizeReaderMenuColor(textColor),
       textColorNight = normalizeReaderMenuColor(textColorNight),
       titleBarMode = ReaderMenuTitleBarMode.normalize(titleBarMode),
       titleIconStyle = titleIconStyle.clamp(0, 2),
       borderWidth = borderWidth.clamp(0, 4),
       borderColor = normalizeReaderMenuColor(borderColor),
       borderColorNight = normalizeReaderMenuColor(borderColorNight),
       blurRadius = blurRadius.clamp(0, 32),
       blurAlpha = blurAlpha.clamp(0, 100),
       blurColor = normalizeReaderMenuColor(blurColor),
       blurColorNight = normalizeReaderMenuColor(blurColorNight),
       topBarBlurMode = topBarBlurMode.clamp(0, 2),
       bottomBarBlurMode = bottomBarBlurMode.clamp(0, 2),
       topBarBlurStyle = topBarBlurStyle.clamp(0, 1),
       bottomBarBlurStyle = bottomBarBlurStyle.clamp(0, 1);

  /// 默认样式（对齐参考版 ReadSettings 默认值；titleBarMode 按批3a
  /// 任务口径为 '0'，与参考版 ReadSettings 的 '1' 差异见 ACTIVE_PLAN
  /// 批3a 登记（收尾写入））
  static ReaderMenuStyle defaults() => ReaderMenuStyle();

  /// 当前明暗下的背景色原始值
  int bgColorFor(bool isDark) => isDark ? bgColorNight : bgColor;

  /// 当前明暗下的强调色原始值
  int accentColorFor(bool isDark) => isDark ? accentColorNight : accentColor;

  /// 当前明暗下的容器色原始值
  int containerColorFor(bool isDark) =>
      isDark ? containerColorNight : containerColor;

  /// 当前明暗下的文字色原始值
  int textColorFor(bool isDark) => isDark ? textColorNight : textColor;

  /// 底栏每页容量
  int get pageSize => itemsPerRow * rowCount;

  ReaderMenuStyle copyWith({
    bool? showIconText,
    int? itemsPerRow,
    int? rowCount,
    int? iconStyle,
    bool? floatingBottomBar,
    int? bottomCornerRadius,
    int? readBarStyle,
    int? colorMode,
    String? paletteStyle,
    int? bgColor,
    int? bgColorNight,
    int? accentColor,
    int? accentColorNight,
    int? containerColor,
    int? containerColorNight,
    int? textColor,
    int? textColorNight,
    bool? titleCapsule,
    String? titleBarMode,
    bool? mergeButtons,
    int? titleIconStyle,
    int? borderWidth,
    int? borderColor,
    int? borderColorNight,
    int? blurRadius,
    int? blurAlpha,
    int? blurColor,
    int? blurColorNight,
    int? topBarBlurMode,
    int? bottomBarBlurMode,
    int? topBarBlurStyle,
    int? bottomBarBlurStyle,
    bool? topBarLiquidGlassButtons,
    bool? bottomBarLiquidGlassButtons,
    bool? titleBarCompact,
  }) {
    return ReaderMenuStyle(
      showIconText: showIconText ?? this.showIconText,
      itemsPerRow: itemsPerRow ?? this.itemsPerRow,
      rowCount: rowCount ?? this.rowCount,
      iconStyle: iconStyle ?? this.iconStyle,
      floatingBottomBar: floatingBottomBar ?? this.floatingBottomBar,
      bottomCornerRadius: bottomCornerRadius ?? this.bottomCornerRadius,
      readBarStyle: readBarStyle ?? this.readBarStyle,
      colorMode: colorMode ?? this.colorMode,
      paletteStyle: paletteStyle ?? this.paletteStyle,
      bgColor: bgColor ?? this.bgColor,
      bgColorNight: bgColorNight ?? this.bgColorNight,
      accentColor: accentColor ?? this.accentColor,
      accentColorNight: accentColorNight ?? this.accentColorNight,
      containerColor: containerColor ?? this.containerColor,
      containerColorNight: containerColorNight ?? this.containerColorNight,
      textColor: textColor ?? this.textColor,
      textColorNight: textColorNight ?? this.textColorNight,
      titleCapsule: titleCapsule ?? this.titleCapsule,
      titleBarMode: titleBarMode ?? this.titleBarMode,
      mergeButtons: mergeButtons ?? this.mergeButtons,
      titleIconStyle: titleIconStyle ?? this.titleIconStyle,
      borderWidth: borderWidth ?? this.borderWidth,
      borderColor: borderColor ?? this.borderColor,
      borderColorNight: borderColorNight ?? this.borderColorNight,
      blurRadius: blurRadius ?? this.blurRadius,
      blurAlpha: blurAlpha ?? this.blurAlpha,
      blurColor: blurColor ?? this.blurColor,
      blurColorNight: blurColorNight ?? this.blurColorNight,
      topBarBlurMode: topBarBlurMode ?? this.topBarBlurMode,
      bottomBarBlurMode: bottomBarBlurMode ?? this.bottomBarBlurMode,
      topBarBlurStyle: topBarBlurStyle ?? this.topBarBlurStyle,
      bottomBarBlurStyle: bottomBarBlurStyle ?? this.bottomBarBlurStyle,
      topBarLiquidGlassButtons:
          topBarLiquidGlassButtons ?? this.topBarLiquidGlassButtons,
      bottomBarLiquidGlassButtons:
          bottomBarLiquidGlassButtons ?? this.bottomBarLiquidGlassButtons,
      titleBarCompact: titleBarCompact ?? this.titleBarCompact,
    );
  }

  /// 序列化为与偏好键同名的 JSON（测试/调试/未来导入导出复用）
  Map<String, Object?> toJson() => <String, Object?>{
    PrefKeys.readMenuIconShowText: showIconText,
    PrefKeys.readMenuIconItemsPerRow: itemsPerRow,
    PrefKeys.readMenuIconRowCount: rowCount,
    PrefKeys.readMenuIconStyle: iconStyle,
    PrefKeys.readMenuFloatingBottomBar: floatingBottomBar,
    PrefKeys.readMenuBottomCornerRadius: bottomCornerRadius,
    PrefKeys.readBarStyle: readBarStyle,
    PrefKeys.readMenuColorMode: colorMode,
    PrefKeys.readMenuPaletteStyle: paletteStyle,
    PrefKeys.readMenuBgColor: bgColor,
    PrefKeys.readMenuBgColorNight: bgColorNight,
    PrefKeys.readMenuAccentColor: accentColor,
    PrefKeys.readMenuAccentColorNight: accentColorNight,
    PrefKeys.readMenuContainerColor: containerColor,
    PrefKeys.readMenuContainerColorNight: containerColorNight,
    PrefKeys.readMenuTextColor: textColor,
    PrefKeys.readMenuTextColorNight: textColorNight,
    PrefKeys.readMenuTopBarTitleCapsule: titleCapsule,
    PrefKeys.titleBarMode: titleBarMode,
    PrefKeys.readMenuTopBarMergeButtons: mergeButtons,
    PrefKeys.titleBarIconStyle: titleIconStyle,
    PrefKeys.readMenuBorderWidth: borderWidth,
    PrefKeys.readMenuBorderColor: borderColor,
    PrefKeys.readMenuBorderColorNight: borderColorNight,
    PrefKeys.readMenuBlurRadius: blurRadius,
    PrefKeys.readMenuBlurAlpha: blurAlpha,
    PrefKeys.readMenuBlurColor: blurColor,
    PrefKeys.readMenuBlurColorNight: blurColorNight,
    PrefKeys.readMenuTopBarBlurMode: topBarBlurMode,
    PrefKeys.readMenuBottomBarBlurMode: bottomBarBlurMode,
    PrefKeys.readMenuTopBarBlurStyle: topBarBlurStyle,
    PrefKeys.readMenuBottomBarBlurStyle: bottomBarBlurStyle,
    PrefKeys.readMenuTopBarLiquidGlassButtons: topBarLiquidGlassButtons,
    PrefKeys.readMenuBottomBarLiquidGlassButtons: bottomBarLiquidGlassButtons,
    PrefKeys.titleBarCompact: titleBarCompact,
  };

  /// 从 JSON 宽松解码（int/double/String/bool 均可；非法值回落默认）
  static ReaderMenuStyle fromJson(Map<String, Object?> json) {
    int intOf(String key, int fallback) {
      final value = json[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is bool) return value ? 1 : 0;
      if (value is String) return int.tryParse(value.trim()) ?? fallback;
      return fallback;
    }

    bool boolOf(String key, bool fallback) {
      final value = json[key];
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) {
        final text = value.trim().toLowerCase();
        if (text == 'true' || text == '1') return true;
        if (text == 'false' || text == '0') return false;
      }
      return fallback;
    }

    String stringOf(String key, String fallback) {
      final value = json[key];
      if (value == null) return fallback;
      return '$value';
    }

    final defaults = ReaderMenuStyle.defaults();
    return ReaderMenuStyle(
      showIconText: boolOf(
        PrefKeys.readMenuIconShowText,
        defaults.showIconText,
      ),
      itemsPerRow: intOf(
        PrefKeys.readMenuIconItemsPerRow,
        defaults.itemsPerRow,
      ),
      rowCount: intOf(PrefKeys.readMenuIconRowCount, defaults.rowCount),
      iconStyle: intOf(PrefKeys.readMenuIconStyle, defaults.iconStyle),
      floatingBottomBar: boolOf(
        PrefKeys.readMenuFloatingBottomBar,
        defaults.floatingBottomBar,
      ),
      bottomCornerRadius: intOf(
        PrefKeys.readMenuBottomCornerRadius,
        defaults.bottomCornerRadius,
      ),
      readBarStyle: intOf(PrefKeys.readBarStyle, defaults.readBarStyle),
      colorMode: intOf(PrefKeys.readMenuColorMode, defaults.colorMode),
      paletteStyle: stringOf(
        PrefKeys.readMenuPaletteStyle,
        defaults.paletteStyle,
      ),
      bgColor: intOf(PrefKeys.readMenuBgColor, defaults.bgColor),
      bgColorNight: intOf(PrefKeys.readMenuBgColorNight, defaults.bgColorNight),
      accentColor: intOf(PrefKeys.readMenuAccentColor, defaults.accentColor),
      accentColorNight: intOf(
        PrefKeys.readMenuAccentColorNight,
        defaults.accentColorNight,
      ),
      containerColor: intOf(
        PrefKeys.readMenuContainerColor,
        defaults.containerColor,
      ),
      containerColorNight: intOf(
        PrefKeys.readMenuContainerColorNight,
        defaults.containerColorNight,
      ),
      textColor: intOf(PrefKeys.readMenuTextColor, defaults.textColor),
      textColorNight: intOf(
        PrefKeys.readMenuTextColorNight,
        defaults.textColorNight,
      ),
      titleCapsule: boolOf(
        PrefKeys.readMenuTopBarTitleCapsule,
        defaults.titleCapsule,
      ),
      titleBarMode: stringOf(PrefKeys.titleBarMode, defaults.titleBarMode),
      mergeButtons: boolOf(
        PrefKeys.readMenuTopBarMergeButtons,
        defaults.mergeButtons,
      ),
      titleIconStyle: intOf(
        PrefKeys.titleBarIconStyle,
        defaults.titleIconStyle,
      ),
      borderWidth: intOf(PrefKeys.readMenuBorderWidth, defaults.borderWidth),
      borderColor: intOf(PrefKeys.readMenuBorderColor, defaults.borderColor),
      borderColorNight: intOf(
        PrefKeys.readMenuBorderColorNight,
        defaults.borderColorNight,
      ),
      blurRadius: intOf(PrefKeys.readMenuBlurRadius, defaults.blurRadius),
      blurAlpha: intOf(PrefKeys.readMenuBlurAlpha, defaults.blurAlpha),
      blurColor: intOf(PrefKeys.readMenuBlurColor, defaults.blurColor),
      blurColorNight: intOf(
        PrefKeys.readMenuBlurColorNight,
        defaults.blurColorNight,
      ),
      topBarBlurMode: intOf(
        PrefKeys.readMenuTopBarBlurMode,
        defaults.topBarBlurMode,
      ),
      bottomBarBlurMode: intOf(
        PrefKeys.readMenuBottomBarBlurMode,
        defaults.bottomBarBlurMode,
      ),
      topBarBlurStyle: intOf(
        PrefKeys.readMenuTopBarBlurStyle,
        defaults.topBarBlurStyle,
      ),
      bottomBarBlurStyle: intOf(
        PrefKeys.readMenuBottomBarBlurStyle,
        defaults.bottomBarBlurStyle,
      ),
      topBarLiquidGlassButtons: boolOf(
        PrefKeys.readMenuTopBarLiquidGlassButtons,
        defaults.topBarLiquidGlassButtons,
      ),
      bottomBarLiquidGlassButtons: boolOf(
        PrefKeys.readMenuBottomBarLiquidGlassButtons,
        defaults.bottomBarLiquidGlassButtons,
      ),
      titleBarCompact: boolOf(
        PrefKeys.titleBarCompact,
        defaults.titleBarCompact,
      ),
    );
  }
}

/// 编码为 JSON 字符串（与 [decodeReaderMenuStyle] 成对）
String encodeReaderMenuStyle(ReaderMenuStyle style) =>
    jsonEncode(style.toJson());

/// 从 JSON 字符串解码；空串/非法 JSON 回落默认
ReaderMenuStyle decodeReaderMenuStyle(String? raw) {
  if (raw == null || raw.trim().isEmpty) return ReaderMenuStyle.defaults();
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return ReaderMenuStyle.fromJson(decoded);
    }
  } catch (_) {
    // 非法 JSON：按默认值处理（备份/历史脏数据不阻塞阅读器启动）
  }
  return ReaderMenuStyle.defaults();
}

/// 解析后的菜单颜色（纯函数输出，不含任何 Widget 状态）
@immutable
class ResolvedReaderMenuColors {
  /// 顶栏/底栏背景
  final Color background;

  /// 容器/按钮底衬（surfaceContainerLow 语义）
  final Color container;

  /// 强调色（primary 语义，选中图标/强调）
  final Color accent;

  /// 基础前景色（图标/正文，onSurface 语义）
  final Color onSurface;

  /// 文字色（标题/标签）
  final Color text;

  /// 次级前景色（非选中动作图标，onSurfaceVariant 语义）
  final Color onSurfaceVariant;

  const ResolvedReaderMenuColors({
    required this.background,
    required this.container,
    required this.accent,
    required this.onSurface,
    required this.text,
    required this.onSurfaceVariant,
  });
}

/// 按工具栏样式解析菜单颜色
///
/// [isDark] 取应用当前明暗（对齐参考版「日夜按 App 暗色」）；
/// [pageBackgroundColor] 为阅读页底色：readBarStyle=1 时作为 seed 生成
/// 整套 roles，readBarStyle=2 自定义背景缺失时作为回落源。
/// [pageTextColor] 仅保留签名兼容；3b 起文字由 seed roles.onSurface 决定
/// （不足 4.5 对比度时回退黑白），不再直接使用阅读页文字色。
ResolvedReaderMenuColors resolveReaderMenuColors({
  required ReaderMenuStyle style,
  required bool isDark,
  required ColorScheme scheme,
  Color? pageBackgroundColor,
  Color? pageTextColor,
  String appPaletteStyle = '',
}) {
  switch (style.readBarStyle) {
    case ReaderMenuBarStyle.followPage:
      return _resolveFollowPage(
        style: style,
        isDark: isDark,
        scheme: scheme,
        pageBackgroundColor: pageBackgroundColor,
        appPaletteStyle: appPaletteStyle,
      );
    case ReaderMenuBarStyle.custom:
      return _resolveCustom(
        style: style,
        isDark: isDark,
        scheme: scheme,
        pageBackgroundColor: pageBackgroundColor,
        appPaletteStyle: appPaletteStyle,
      );
    case ReaderMenuBarStyle.system:
    default:
      return _resolveSystem(scheme);
  }
}

ResolvedReaderMenuColors _resolveSystem(ColorScheme scheme) {
  return ResolvedReaderMenuColors(
    // 参考 ReadBookColorTheme 的 system 档取 surfaceContainerHigh
    background: scheme.surfaceContainerHigh,
    container: scheme.surfaceContainerLow,
    accent: scheme.primary,
    onSurface: scheme.onSurface,
    text: scheme.onSurface,
    onSurfaceVariant: scheme.onSurfaceVariant,
  );
}

ResolvedReaderMenuColors _resolveFollowPage({
  required ReaderMenuStyle style,
  required bool isDark,
  required ColorScheme scheme,
  Color? pageBackgroundColor,
  required String appPaletteStyle,
}) {
  // 无阅读页色（如独立的菜单测试宿主）→ 回落系统样式。
  // 阅读页当前只有纯色背景（ReaderState 无 backgroundImagePath），
  // 图片背景取种留 3b 登记；见最终汇报。
  if (pageBackgroundColor == null) return _resolveSystem(scheme);
  final seed = _opaqueColor(pageBackgroundColor);
  final palette = style.paletteStyle.trim().isEmpty
      ? normalizeReaderMenuPaletteStyle(appPaletteStyle)
      : normalizeReaderMenuPaletteStyle(style.paletteStyle);
  final rolesPair = buildParameterizedRoles(
    style: palette,
    seed: seed.toARGB32(),
    contrastLevel: 0,
  );
  final Md3Roles roles = isDark ? rolesPair.dark : rolesPair.light;
  final background = Color(roles.surfaceContainerHigh);
  final roleText = Color(roles.onSurface);
  // 参考 ReadBookColorTheme：菜单底 surfaceContainerHigh、容器
  // surfaceContainerLow、accent=primary、文字=onSurface；若某预设
  // onSurface 对 surfaceContainerHigh 不足 4.5，按 WCAG 回退黑白。
  final text = _contrastRatio(roleText, background) < 4.5
      ? _contrastText(background)
      : roleText;
  return ResolvedReaderMenuColors(
    background: background,
    container: Color(roles.surfaceContainerLow),
    accent: Color(roles.primary),
    onSurface: text,
    text: text,
    onSurfaceVariant: Color(roles.onSurfaceVariant),
  );
}

ResolvedReaderMenuColors _resolveCustom({
  required ReaderMenuStyle style,
  required bool isDark,
  required ColorScheme scheme,
  Color? pageBackgroundColor,
  required String appPaletteStyle,
}) {
  if (style.colorMode == ReaderMenuColorMode.seed) {
    final accentArgb = style.accentColorFor(isDark);
    final seed = accentArgb != 0
        ? Color(normalizeReaderMenuColor(accentArgb))
        : scheme.primary;
    // [批3a P2-3] paletteStyle='' 跟随应用调色板（UiSettingsState.
    // themeStyle；'none'/空 → tonalSpot），非空时用户选择优先。
    final palette = style.paletteStyle.trim().isEmpty
        ? normalizeReaderMenuPaletteStyle(appPaletteStyle)
        : normalizeReaderMenuPaletteStyle(style.paletteStyle);
    final rolesPair = buildParameterizedRoles(
      style: palette,
      seed: seed.toARGB32(),
      contrastLevel: 0,
    );
    final Md3Roles roles = isDark ? rolesPair.dark : rolesPair.light;
    return ResolvedReaderMenuColors(
      // [批3a P2-2] 种子档背景与 system 档一致取 surfaceContainerHigh
      background: Color(roles.surfaceContainerHigh),
      container: Color(roles.surfaceContainerLow),
      accent: Color(roles.primary),
      onSurface: Color(roles.onSurface),
      text: Color(roles.onSurface),
      onSurfaceVariant: Color(roles.onSurfaceVariant),
    );
  }

  final bgArgb = style.bgColorFor(isDark);
  final background = bgArgb != 0
      ? Color(normalizeReaderMenuColor(bgArgb))
      : (pageBackgroundColor != null
            ? _opaqueColor(pageBackgroundColor)
            : scheme.surface);
  final containerArgb = style.containerColorFor(isDark);
  final container = containerArgb != 0
      ? Color(normalizeReaderMenuColor(containerArgb))
      : background;
  final accentArgb = style.accentColorFor(isDark);
  final accent = accentArgb != 0
      ? Color(normalizeReaderMenuColor(accentArgb))
      : scheme.primary;
  final textArgb = style.textColorFor(isDark);
  final text = textArgb != 0
      ? Color(normalizeReaderMenuColor(textArgb))
      : _contrastText(background);
  return ResolvedReaderMenuColors(
    background: background,
    container: container,
    accent: accent,
    onSurface: text,
    text: text,
    onSurfaceVariant: _mutedOn(text, background),
  );
}

/// 阅读页色不透明化（阅读页颜色恒为实色，历史值可能带 alpha）
Color _opaqueColor(Color color) =>
    Color(normalizeReaderMenuColor(color.toARGB32()));

/// WCAG 对比度（1.0..21.0）
double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final lighter = la > lb ? la : lb;
  final darker = la > lb ? lb : la;
  return (lighter + 0.05) / (darker + 0.05);
}

/// 黑/白中对比度更高的文字色
Color _contrastText(Color background) {
  final luminance = background.computeLuminance();
  final blackContrast = (luminance + 0.05) / 0.05;
  final whiteContrast = 1.05 / (luminance + 0.05);
  return blackContrast >= whiteContrast
      ? const Color(0xFF000000)
      : const Color(0xFFFFFFFF);
}

/// 次级前景色：把文字色以 72% 混入背景，得到不透明的 onSurfaceVariant 近似
Color _mutedOn(Color text, Color background) {
  return Color.alphaBlend(text.withValues(alpha: 0.72), background);
}
