import 'package:flutter/material.dart';

/// 应用色值定义
///
/// 唯一色值来源：Android 端 app/src/main/res/values/colors.xml
/// 以及 values-night/colors.xml
///
/// 安卓原版为 M2（Theme.AppCompat），此处映射到 M3 ColorScheme 体系。
class AppColors {
  AppColors._();

  // ============================================================
  // 亮色主题色值（对应 values/colors.xml）
  // ============================================================

  /// primary: md_light_blue_600
  static const Color lightPrimary = Color(0xFF039BE5);

  /// primaryDark: md_light_blue_700
  static const Color lightPrimaryDark = Color(0xFF0288D1);

  /// accent: md_pink_800
  static const Color lightAccent = Color(0xFFAD1457);

  /// background: md_grey_50
  static const Color lightBackground = Color(0xFFFAFAFA);

  /// background_card: md_grey_100
  static const Color lightBackgroundCard = Color(0xFFF5F5F5);

  /// background_menu: md_grey_200
  static const Color lightBackgroundMenu = Color(0xFFEEEEEE);

  /// background_prefs: 50% 白
  static const Color lightBackgroundPrefs = Color(0x7FFFFFFF);

  /// divider: 40% 灰
  static const Color lightDivider = Color(0x66666666);

  /// error
  static const Color lightError = Color(0xFFEB4333);

  /// success
  static const Color lightSuccess = Color(0xFF439B53);

  /// primaryText: 87% 黑
  static const Color lightPrimaryText = Color(0xDE000000);

  /// secondaryText: 54% 黑
  static const Color lightSecondaryText = Color(0x8A000000);

  /// tv_text_summary: 54% 深灰
  static const Color lightTextSummary = Color(0x8A2C2C2C);

  /// menu_color_default
  static const Color lightMenuColor = Color(0xFF383838);

  /// card_border_water
  static const Color lightCardBorder = Color(0x39424242);

  /// card_bg_water
  static const Color lightCardBgWater = Color(0x69FDFDFD);

  /// btn_bg_press
  static const Color lightBtnBgPress = Color(0x63ACACAC);

  /// btn_bg_press_2
  static const Color lightBtnBgPress2 = Color(0x63858585);

  /// highlight
  static const Color lightHighlight = Color(0xFFD3321B);

  /// tv_btn_normal_black
  static const Color lightTvBtnNormal = Color(0xFF737373);

  /// tv_btn_press_black
  static const Color lightTvBtnPress = Color(0xFFADADAD);

  /// common_gray
  static const Color lightCommonGray = Color(0xFFEEEEEE);

  /// bg_divider_line
  static const Color lightBgDividerLine = Color(0x8FE0E0E0);

  /// navigation_bar_bag
  static const Color lightNavigationBarBg = Color(0xFFF4F4F4);

  /// disabled: md_light_disabled (26% 黑)
  static const Color lightDisabled = Color(0x43000000);

  // ============================================================
  // 暗色主题色值（对应 values-night/colors.xml）
  // ============================================================

  /// primary: md_blue_grey_600
  static const Color darkPrimary = Color(0xFF546E7A);

  /// primaryDark: md_blue_grey_700
  static const Color darkPrimaryDark = Color(0xFF455A64);

  /// accent: md_deep_orange_800
  static const Color darkAccent = Color(0xFFD84315);

  /// background: md_grey_900
  static const Color darkBackground = Color(0xFF212121);

  /// background_card: md_grey_850
  static const Color darkBackgroundCard = Color(0xFF303030);

  /// background_menu: md_grey_800
  static const Color darkBackgroundMenu = Color(0xFF424242);

  /// background_prefs
  static const Color darkBackgroundPrefs = Color(0x10303030);

  /// divider（同亮色）
  static const Color darkDivider = Color(0x66666666);

  /// error（同亮色）
  static const Color darkError = Color(0xFFEB4333);

  /// primaryText: 100% 白
  static const Color darkPrimaryText = Color(0xFFFFFFFF);

  /// secondaryText: 70% 白
  static const Color darkSecondaryText = Color(0xB3FFFFFF);

  /// tv_text_summary
  static const Color darkTextSummary = Color(0xFFB3B3B3);

  /// menu_color_default
  static const Color darkMenuColor = Color(0xFFB7B7B7);

  /// card_border_water (night)
  static const Color darkCardBorder = Color(0x39BDBDBD);

  /// card_bg_water (night)
  static const Color darkCardBgWater = Color(0x69121212);

  /// btn_bg_press (night)
  static const Color darkBtnBgPress = Color(0x634D4D4D);

  /// btn_bg_press_2 (night)
  static const Color darkBtnBgPress2 = Color(0x63686868);

  /// tv_btn_normal_black (night)
  static const Color darkTvBtnNormal = Color(0xFF737373);

  /// tv_btn_press_black (night)
  static const Color darkTvBtnPress = Color(0xFF565656);

  /// bg_divider_line (night)
  static const Color darkBgDividerLine = Color(0xFF363636);

  /// navigation_bar_bag (night)
  static const Color darkNavigationBarBg = Color(0xFF222222);

  /// night_mask
  static const Color darkNightMask = Color(0x69000000);

  /// disabled: md_dark_disabled (30% 白)
  static const Color darkDisabled = Color(0x4DFFFFFF);

  // ============================================================
  // 通用色值（不区分亮暗）
  // ============================================================

  /// 透明
  static const Color transparent = Color(0x00000000);

  /// 纯黑
  static const Color black = Color(0xFF000000);

  /// 纯白
  static const Color white = Color(0xFFFFFFFF);

  /// lightBlue_color
  static const Color lightBlue = Color(0xFF578FCC);

  // ============================================================
  // M3 ColorScheme 构建
  // ============================================================

  /// 亮色 ColorScheme —— 基于安卓端 primary/accent 显式指定关键槽位
  static const ColorScheme lightColorScheme = ColorScheme(
    brightness: Brightness.light,
    primary: lightPrimary,
    onPrimary: white,
    primaryContainer: Color(0xFFB3E5FC), // md_light_blue_100
    onPrimaryContainer: Color(0xFF01579B), // md_light_blue_900
    secondary: lightAccent,
    onSecondary: white,
    secondaryContainer: Color(0xFFF8BBD0), // md_pink_100
    onSecondaryContainer: Color(0xFF880E4F), // md_pink_900
    tertiary: Color(0xFF578FCC),
    onTertiary: white,
    error: lightError,
    onError: white,
    errorContainer: Color(0xFFFFDAD6),
    onErrorContainer: Color(0xFF410002),
    surface: white,
    onSurface: lightPrimaryText,
    surfaceContainerHighest: lightBackgroundCard,
    onSurfaceVariant: lightSecondaryText,
    outline: lightDivider,
    outlineVariant: Color(0x39424242),
    inverseSurface: Color(0xFF303030),
    onInverseSurface: Color(0xFFF5F5F5),
    inversePrimary: Color(0xFF81D4FA),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
  );

  /// 暗色 ColorScheme —— 基于安卓端 night primary/accent 显式指定关键槽位
  static const ColorScheme darkColorScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: darkPrimary,
    onPrimary: white,
    primaryContainer: Color(0xFF37474F), // md_blue_grey_800
    onPrimaryContainer: Color(0xFFCFD8DC), // md_blue_grey_100
    secondary: darkAccent,
    onSecondary: white,
    secondaryContainer: Color(0xFFBF360C), // md_deep_orange_900
    onSecondaryContainer: Color(0xFFFFCCBC), // md_deep_orange_100
    tertiary: Color(0xFF578FCC),
    onTertiary: white,
    error: darkError,
    onError: white,
    errorContainer: Color(0xFF93000A),
    onErrorContainer: Color(0xFFFFDAD6),
    surface: darkBackgroundCard,
    onSurface: darkPrimaryText,
    surfaceContainerHighest: Color(0xFF424242),
    onSurfaceVariant: darkSecondaryText,
    outline: darkDivider,
    outlineVariant: Color(0x39BDBDBD),
    inverseSurface: Color(0xFFE0E0E0),
    onInverseSurface: Color(0xFF303030),
    inversePrimary: Color(0xFF546E7A),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
  );
}
