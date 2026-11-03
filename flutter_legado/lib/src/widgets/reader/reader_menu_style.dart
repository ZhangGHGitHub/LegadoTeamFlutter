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
  if (argb == 0) return 0;
  final rgb = argb & 0x00FFFFFF;
  final alpha = (argb >> 24) & 0xFF;
  if (alpha == 0xFF) return 0xFF000000 | rgb;
  return 0xFF000000 | rgb;
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
       titleIconStyle = titleIconStyle.clamp(0, 2);

  /// 默认样式（对齐参考版 ReadSettings 默认值；titleBarMode 按批3a
  /// 任务口径为 '0'，与参考版 ReadSettings 的 '1' 差异已登记）
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
/// [pageBackgroundColor]/[pageTextColor] 为阅读页当前底色/文字色，
/// 仅 readBarStyle=1 与 readBarStyle=2 自定义背景缺失时作为回落源。
ResolvedReaderMenuColors resolveReaderMenuColors({
  required ReaderMenuStyle style,
  required bool isDark,
  required ColorScheme scheme,
  Color? pageBackgroundColor,
  Color? pageTextColor,
}) {
  switch (style.readBarStyle) {
    case ReaderMenuBarStyle.followPage:
      return _resolveFollowPage(
        scheme: scheme,
        pageBackgroundColor: pageBackgroundColor,
        pageTextColor: pageTextColor,
      );
    case ReaderMenuBarStyle.custom:
      return _resolveCustom(
        style: style,
        isDark: isDark,
        scheme: scheme,
        pageBackgroundColor: pageBackgroundColor,
      );
    case ReaderMenuBarStyle.system:
    default:
      return _resolveSystem(scheme);
  }
}

ResolvedReaderMenuColors _resolveSystem(ColorScheme scheme) {
  return ResolvedReaderMenuColors(
    background: scheme.surface,
    container: scheme.surfaceContainerLow,
    accent: scheme.primary,
    onSurface: scheme.onSurface,
    text: scheme.onSurface,
    onSurfaceVariant: scheme.onSurfaceVariant,
  );
}

ResolvedReaderMenuColors _resolveFollowPage({
  required ColorScheme scheme,
  Color? pageBackgroundColor,
  Color? pageTextColor,
}) {
  // 无阅读页色（如独立的菜单测试宿主）→ 回落系统样式
  if (pageBackgroundColor == null) return _resolveSystem(scheme);
  final background = _opaqueColor(pageBackgroundColor);
  final text = pageTextColor == null
      ? _contrastText(background)
      : _opaqueColor(pageTextColor);
  return ResolvedReaderMenuColors(
    background: background,
    container: background,
    accent: scheme.primary,
    onSurface: text,
    text: text,
    onSurfaceVariant: _mutedOn(text, background),
  );
}

ResolvedReaderMenuColors _resolveCustom({
  required ReaderMenuStyle style,
  required bool isDark,
  required ColorScheme scheme,
  Color? pageBackgroundColor,
}) {
  if (style.colorMode == ReaderMenuColorMode.seed) {
    final accentArgb = style.accentColorFor(isDark);
    final seed = accentArgb != 0
        ? Color(normalizeReaderMenuColor(accentArgb))
        : scheme.primary;
    final palette = normalizeReaderMenuPaletteStyle(style.paletteStyle);
    final rolesPair = buildParameterizedRoles(
      style: palette,
      seed: seed.toARGB32(),
      contrastLevel: 0,
    );
    final Md3Roles roles = isDark ? rolesPair.dark : rolesPair.light;
    return ResolvedReaderMenuColors(
      background: Color(roles.background),
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

/// 黑/白对比文字（对齐参考版 `contrastContentColor`：亮底黑字、暗底白字）
Color _contrastText(Color background) {
  return background.computeLuminance() > 0.5
      ? const Color(0xFF000000)
      : const Color(0xFFFFFFFF);
}

/// 次级前景色：把文字色以 72% 混入背景，得到不透明的 onSurfaceVariant 近似
Color _mutedOn(Color text, Color background) {
  return Color.alphaBlend(text.withValues(alpha: 0.72), background);
}
