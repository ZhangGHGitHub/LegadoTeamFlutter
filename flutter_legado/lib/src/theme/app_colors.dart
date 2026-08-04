import 'package:flutter/material.dart';

/// 应用色值定义（Apple / iOS 设计体系）
///
/// 设计目标：在保持与原版 Legado 功能 100% 对等的前提下，
/// 将视觉语言切换为 iOS Human Interface Guidelines 风格。
///
/// 语义槽位与原版一一对应（保证既有引用不破坏），色值取自 iOS 系统色：
/// - 背景采用「分组背景（灰）+ 卡片（白）」的经典 iOS Settings 层次
/// - 强调色采用 iOS 系统蓝（Tint），辅以系统语义色（红/绿/橙…）
///
/// 命名约定：`light*` / `dark*` 前缀为亮/暗两套；无前缀为通用。
class AppColors {
  AppColors._();

  // ============================================================
  // iOS 系统强调色与语义色（不区分亮暗的基础参考）
  // ============================================================

  /// iOS 系统红（destructive）
  static const Color iosRedLight = Color(0xFFFF3B30);
  static const Color iosRedDark = Color(0xFFFF453A);

  /// iOS 系统橙
  static const Color iosOrangeLight = Color(0xFFFF9500);
  static const Color iosOrangeDark = Color(0xFFFF9F0A);

  /// iOS 系统黄
  static const Color iosYellowLight = Color(0xFFFFCC00);
  static const Color iosYellowDark = Color(0xFFFFD60A);

  /// iOS 系统绿（开关/成功）
  static const Color iosGreenLight = Color(0xFF34C759);
  static const Color iosGreenDark = Color(0xFF30D158);

  /// iOS 系统薄荷绿
  static const Color iosMintLight = Color(0xFF00C7BE);
  static const Color iosMintDark = Color(0xFF63E6E2);

  /// iOS 系统青
  static const Color iosTealLight = Color(0xFF5AC8FA);
  static const Color iosTealDark = Color(0xFF40C8E0);

  /// iOS 系统蓝（Tint / 强调色）
  static const Color iosBlueLight = Color(0xFF007AFF);
  static const Color iosBlueDark = Color(0xFF0A84FF);

  /// iOS 系统靛蓝
  static const Color iosIndigoLight = Color(0xFF5856D6);
  static const Color iosIndigoDark = Color(0xFF5E5CE6);

  /// iOS 系统紫
  static const Color iosPurpleLight = Color(0xFFAF52DE);
  static const Color iosPurpleDark = Color(0xFFBF5AF2);

  /// iOS 系统粉
  static const Color iosPinkLight = Color(0xFFFF2D55);
  static const Color iosPinkDark = Color(0xFFFF375F);

  /// iOS 系统棕
  static const Color iosBrownLight = Color(0xFFA2845E);
  static const Color iosBrownDark = Color(0xFFAC8E68);

  // ============================================================
  // 亮色主题色值（iOS Light）
  // ============================================================

  /// primary / Tint：iOS 系统蓝
  static const Color lightPrimary = iosBlueLight;

  /// primaryDark：按压态加深
  static const Color lightPrimaryDark = Color(0xFF0062CC);

  /// accent：iOS 系统粉（次强调）
  static const Color lightAccent = iosPinkLight;

  /// background / 分组背景：iOS Grouped Background
  static const Color lightBackground = Color(0xFFF2F2F7);

  /// background_card / 次级分组背景：iOS Secondary Grouped Background（卡片白）
  static const Color lightBackgroundCard = Color(0xFFFFFFFF);

  /// background_menu / 三级背景：iOS Tertiary System Grouped Background
  static const Color lightBackgroundMenu = Color(0xFFF2F2F7);

  /// background_prefs
  static const Color lightBackgroundPrefs = Color(0x7FFFFFFF);

  /// divider / 分隔线：iOS Separator（半透明 hairline）
  static const Color lightDivider = Color(0x4A3C3C43);

  /// 分隔线不透明参考色
  static const Color lightSeparatorOpaque = Color(0xFFC6C6C8);

  /// error：iOS 系统红
  static const Color lightError = iosRedLight;

  /// success：iOS 系统绿
  static const Color lightSuccess = iosGreenLight;

  /// primaryText / Label
  static const Color lightPrimaryText = Color(0xFF000000);

  /// secondaryText / Secondary Label（60%）
  static const Color lightSecondaryText = Color(0x993C3C43);

  /// tv_text_summary / Tertiary Label（30%）
  static const Color lightTextSummary = Color(0x4D3C3C43);

  /// Quaternary Label（18%）
  static const Color lightQuaternaryText = Color(0x2E3C3C43);

  /// menu_color_default（近似 Label）
  static const Color lightMenuColor = Color(0xFF1C1C1E);

  /// card_border_water：iOS 卡片几乎无边框，仅极淡 hairline
  static const Color lightCardBorder = Color(0x1E3C3C43);

  /// card_bg_water（卡片白）
  static const Color lightCardBgWater = Color(0xFFFFFFFF);

  /// btn_bg_press：iOS 按压态填充
  static const Color lightBtnBgPress = Color(0x1F3C3C43);

  /// btn_bg_press_2
  static const Color lightBtnBgPress2 = Color(0x2E3C3C43);

  /// highlight：iOS 系统红
  static const Color lightHighlight = iosRedLight;

  /// tv_btn_normal_black（次级按钮/未选中图标）
  static const Color lightTvBtnNormal = Color(0x993C3C43);

  /// tv_btn_press_black
  static const Color lightTvBtnPress = Color(0xFF3C3C43);

  /// common_gray：iOS Fill
  static const Color lightCommonGray = Color(0xFFE5E5EA);

  /// bg_divider_line：iOS Separator
  static const Color lightBgDividerLine = Color(0x4A3C3C43);

  /// navigation_bar_bag：iOS Tab Bar 半透明底
  static const Color lightNavigationBarBg = Color(0xFFF9F9F9);

  /// disabled：iOS Disabled（30% Label）
  static const Color lightDisabled = Color(0x4D3C3C43);

  /// iOS Fill（20%）
  static const Color lightFill = Color(0x33787878);

  /// iOS Secondary Fill（16%）
  static const Color lightSecondaryFill = Color(0x29787878);

  /// iOS Tertiary Fill（12%）
  static const Color lightTertiaryFill = Color(0x1F767680);

  // ============================================================
  // 暗色主题色值（iOS Dark）
  // ============================================================

  /// primary / Tint：iOS 系统蓝（暗）
  static const Color darkPrimary = iosBlueDark;

  /// primaryDark
  static const Color darkPrimaryDark = Color(0xFF0A84FF);

  /// accent：iOS 系统粉（暗）
  static const Color darkAccent = iosPinkDark;

  /// background / 分组背景：iOS Dark Grouped Background
  static const Color darkBackground = Color(0xFF000000);

  /// background_card / 次级分组背景：iOS Secondary System Grouped Background
  static const Color darkBackgroundCard = Color(0xFF1C1C1E);

  /// background_menu / 三级背景
  static const Color darkBackgroundMenu = Color(0xFF2C2C2E);

  /// background_prefs
  static const Color darkBackgroundPrefs = Color(0x10303030);

  /// divider / 分隔线：iOS Dark Separator
  static const Color darkDivider = Color(0x99545458);

  /// 分隔线不透明参考色
  static const Color darkSeparatorOpaque = Color(0xFF38383A);

  /// error：iOS 系统红（暗）
  static const Color darkError = iosRedDark;

  /// primaryText / Label
  static const Color darkPrimaryText = Color(0xFFFFFFFF);

  /// secondaryText / Secondary Label（60%）
  static const Color darkSecondaryText = Color(0x99EBEBF5);

  /// tv_text_summary / Tertiary Label（30%）
  static const Color darkTextSummary = Color(0x4DEBEBF5);

  /// Quaternary Label（18%）
  static const Color darkQuaternaryText = Color(0x2EEBEBF5);

  /// menu_color_default
  static const Color darkMenuColor = Color(0xFFF2F2F7);

  /// card_border_water：极淡 hairline
  static const Color darkCardBorder = Color(0x1E545458);

  /// card_bg_water
  static const Color darkCardBgWater = Color(0xFF1C1C1E);

  /// btn_bg_press
  static const Color darkBtnBgPress = Color(0x1FEBEBF5);

  /// btn_bg_press_2
  static const Color darkBtnBgPress2 = Color(0x2EEBEBF5);

  /// tv_btn_normal_black
  static const Color darkTvBtnNormal = Color(0x99EBEBF5);

  /// tv_btn_press_black
  static const Color darkTvBtnPress = Color(0xFFEBEBF5);

  /// bg_divider_line：iOS Dark Separator
  static const Color darkBgDividerLine = Color(0x99545458);

  /// navigation_bar_bag：iOS Dark Tab Bar 底
  static const Color darkNavigationBarBg = Color(0xFF161617);

  /// night_mask
  static const Color darkNightMask = Color(0x69000000);

  /// disabled：iOS Dark Disabled（30% Label）
  static const Color darkDisabled = Color(0x4DEBEBF5);

  /// iOS Dark Fill（36%）
  static const Color darkFill = Color(0x5C787878);

  /// iOS Dark Secondary Fill（32%）
  static const Color darkSecondaryFill = Color(0x52787878);

  /// iOS Dark Tertiary Fill（24%）
  static const Color darkTertiaryFill = Color(0x3D767680);

  // ============================================================
  // 通用色值（不区分亮暗）
  // ============================================================

  /// 透明
  static const Color transparent = Color(0x00000000);

  /// 纯黑
  static const Color black = Color(0xFF000000);

  /// 纯白
  static const Color white = Color(0xFFFFFFFF);

  /// 保留的历史语义色（部分阅读器配色引用）
  static const Color lightBlue = Color(0xFF578FCC);

  // ============================================================
  // M3 ColorScheme 构建（语义映射到 iOS 色）
  // ============================================================

  /// 亮色 ColorScheme —— 关键槽位映射 iOS 系统色
  static const ColorScheme lightColorScheme = ColorScheme(
    brightness: Brightness.light,
    primary: lightPrimary,
    onPrimary: white,
    primaryContainer: Color(0xFFD6E9FF),
    onPrimaryContainer: Color(0xFF003E82),
    secondary: lightAccent,
    onSecondary: white,
    secondaryContainer: Color(0xFFFFDCE3),
    onSecondaryContainer: Color(0xFF8A0F2E),
    tertiary: iosIndigoLight,
    onTertiary: white,
    error: lightError,
    onError: white,
    errorContainer: Color(0xFFFFDAD6),
    onErrorContainer: Color(0xFF410002),
    surface: white,
    onSurface: lightPrimaryText,
    surfaceContainerHighest: lightBackground,
    onSurfaceVariant: lightSecondaryText,
    outline: lightDivider,
    outlineVariant: lightCardBorder,
    inverseSurface: Color(0xFF1C1C1E),
    onInverseSurface: Color(0xFFF2F2F7),
    inversePrimary: iosBlueDark,
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
  );

  /// 暗色 ColorScheme —— 关键槽位映射 iOS 暗色系统色
  static const ColorScheme darkColorScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: darkPrimary,
    onPrimary: white,
    primaryContainer: Color(0xFF0A3A6B),
    onPrimaryContainer: Color(0xFFD6E9FF),
    secondary: darkAccent,
    onSecondary: white,
    secondaryContainer: Color(0xFF5C0F22),
    onSecondaryContainer: Color(0xFFFFDCE3),
    tertiary: iosIndigoDark,
    onTertiary: white,
    error: darkError,
    onError: white,
    errorContainer: Color(0xFF93000A),
    onErrorContainer: Color(0xFFFFDAD6),
    surface: darkBackgroundCard,
    onSurface: darkPrimaryText,
    surfaceContainerHighest: Color(0xFF2C2C2E),
    onSurfaceVariant: darkSecondaryText,
    outline: darkDivider,
    outlineVariant: darkCardBorder,
    inverseSurface: Color(0xFFF2F2F7),
    onInverseSurface: Color(0xFF1C1C1E),
    inversePrimary: iosBlueLight,
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
  );
}
