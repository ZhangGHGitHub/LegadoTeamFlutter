import 'package:flutter/material.dart';

/// 应用字体排版定义
///
/// [UI_SYNC_REFACTOR B1] 字阶拉齐参考仓 miuix 压缩字阶（Typography.kt
/// 映射表）：display32 / title18 / body17 / label13 为核心锚点，
/// bodySmall 钉死 12、labelLarge 钉死 14——整体比标准 M3 更紧凑，
/// 与 HapeLee 观感一致（原登记差异口径废除，2026-09-05 用户确认拉齐）。
///
/// 不指定 fontFamily——运行时跟随系统字体；重点固化字号/字重/行高层级。
/// Emphasized 档（+Medium 字重）经各组件显式样式引用（如
/// LabelMediumEmphasized），不占用 TextTheme 槽位。
class AppTypography {
  AppTypography._();

  // ============================================================
  // miuix 压缩字阶常量（字号 / 行高）
  // ============================================================

  /// Display Large（32/40，miuix title1）
  static const double displaySize = 32.0;

  /// Display Medium（24/32，miuix title2）
  static const double displayMediumSize = 24.0;

  /// Display Small（20/28，miuix title3）
  static const double displaySmallSize = 20.0;

  /// Headline Large（32/40）
  static const double headlineLargeSize = 32.0;

  /// Headline Medium（24/32，miuix title2）
  static const double headlineMediumSize = 24.0;

  /// Headline Small（20/28，miuix title3）
  static const double headlineSize = 20.0;

  /// Title Large（18/24，miuix title4）
  static const double titleSize = 18.0;

  /// Title Medium（16/24，miuix headline2，w500）
  static const double titleMediumSize = 16.0;

  /// Title Small（14/20，miuix subtitle，w600）
  static const double titleSmallSize = 14.0;

  /// Body Large（17/24，miuix paragraph）
  static const double bodySize = 17.0;

  /// Body Medium（16/22，miuix body1）
  static const double bodyMediumSize = 16.0;

  /// Body Small（12/16，miuix body2 钉死 12）
  static const double bodySmallSize = 12.0;

  /// Label Large（14/20，miuix footnote1 钉死 14，w500）
  static const double labelLargeSize = 14.0;

  /// Label Medium（13/18，miuix footnote1，w500）
  static const double labelSize = 13.0;

  /// Label Small（11/16，miuix footnote2，w500）
  static const double captionSize = 11.0;

  // ============================================================
  // TextTheme 构建（不含颜色——由 ColorScheme 经 ThemeData 统一着色；
  // 不指定 fontFamily，跟随系统）
  // ============================================================

  /// 亮色 TextTheme（miuix 压缩字阶）
  static const TextTheme lightTextTheme = TextTheme(
    displayLarge: TextStyle(
      fontSize: 32,
      fontWeight: FontWeight.w400,
      height: 40 / 32,
      letterSpacing: -0.25,
    ),
    displayMedium: TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.w400,
      height: 32 / 24,
      letterSpacing: 0,
    ),
    displaySmall: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w400,
      height: 28 / 20,
      letterSpacing: 0,
    ),
    headlineLarge: TextStyle(
      fontSize: 32,
      fontWeight: FontWeight.w400,
      height: 40 / 32,
      letterSpacing: 0,
    ),
    headlineMedium: TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.w400,
      height: 32 / 24,
      letterSpacing: 0,
    ),
    headlineSmall: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w400,
      height: 28 / 20,
      letterSpacing: 0,
    ),
    titleLarge: TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w400,
      height: 24 / 18,
      letterSpacing: 0,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      height: 24 / 16,
      letterSpacing: 0.15,
    ),
    titleSmall: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 20 / 14,
      letterSpacing: 0.1,
    ),
    bodyLarge: TextStyle(
      fontSize: 17,
      fontWeight: FontWeight.w400,
      height: 24 / 17,
      letterSpacing: 0.25,
    ),
    bodyMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w400,
      height: 22 / 16,
      letterSpacing: 0.15,
    ),
    bodySmall: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w400,
      height: 16 / 12,
      letterSpacing: 0.4,
    ),
    labelLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      height: 20 / 14,
      letterSpacing: 0.1,
    ),
    labelMedium: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      height: 18 / 13,
      letterSpacing: 0.4,
    ),
    labelSmall: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w500,
      height: 16 / 11,
      letterSpacing: 0.5,
    ),
  );

  /// 暗色 TextTheme（与亮色相同排版，颜色由 ColorScheme 控制）
  static const TextTheme darkTextTheme = lightTextTheme;
}
