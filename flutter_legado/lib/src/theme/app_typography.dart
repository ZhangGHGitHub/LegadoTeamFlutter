import 'package:flutter/material.dart';

/// 应用字体排版定义（Material Design 3 字阶）
///
/// 字阶对齐 Material Design 3 官方 type scale（2021 版 M3 规范）。
/// 不指定 fontFamily——运行时跟随系统字体（UI_MD3_PLAN.md 第三节：
/// 字体跟随系统），重点固化字号 / 字重 / 行高 / 字距层级。
///
/// 语义槽位与原版保持一致（保证既有引用不破坏）。
class AppTypography {
  AppTypography._();

  // ============================================================
  // M3 字阶常量（字号 / 行高）
  // ============================================================

  /// Display Large（57/64）
  static const double displaySize = 57.0;

  /// Display Medium（45/52）
  static const double displayMediumSize = 45.0;

  /// Display Small（36/44）
  static const double displaySmallSize = 36.0;

  /// Headline Large（32/40）
  static const double headlineLargeSize = 32.0;

  /// Headline Medium（28/36）
  static const double headlineMediumSize = 28.0;

  /// Headline Small（24/32）
  static const double headlineSize = 24.0;

  /// Title Large（22/28）
  static const double titleSize = 22.0;

  /// Title Medium（16/24，w500）
  static const double titleMediumSize = 16.0;

  /// Title Small（14/20，w500）
  static const double titleSmallSize = 14.0;

  /// Body Large（16/24）
  static const double bodySize = 16.0;

  /// Body Medium（14/20）
  static const double bodyMediumSize = 14.0;

  /// Body Small（12/16）
  static const double bodySmallSize = 12.0;

  /// Label Large（14/20，w500）
  static const double labelLargeSize = 14.0;

  /// Label Medium（12/16，w500）
  static const double labelSize = 12.0;

  /// Label Small（11/16，w500）
  static const double captionSize = 11.0;

  // ============================================================
  // M3 TextTheme 构建（不含颜色——由 ColorScheme 经 ThemeData 统一着色；
  // 不指定 fontFamily，跟随系统）
  // ============================================================

  /// 亮色 TextTheme（M3 type scale）
  static const TextTheme lightTextTheme = TextTheme(
    displayLarge: TextStyle(
      fontSize: 57,
      fontWeight: FontWeight.w400,
      height: 64 / 57,
      letterSpacing: -0.25,
    ),
    displayMedium: TextStyle(
      fontSize: 45,
      fontWeight: FontWeight.w400,
      height: 52 / 45,
      letterSpacing: 0,
    ),
    displaySmall: TextStyle(
      fontSize: 36,
      fontWeight: FontWeight.w400,
      height: 44 / 36,
      letterSpacing: 0,
    ),
    headlineLarge: TextStyle(
      fontSize: 32,
      fontWeight: FontWeight.w400,
      height: 40 / 32,
      letterSpacing: 0,
    ),
    headlineMedium: TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w400,
      height: 36 / 28,
      letterSpacing: 0,
    ),
    headlineSmall: TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.w400,
      height: 32 / 24,
      letterSpacing: 0,
    ),
    titleLarge: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w400,
      height: 28 / 22,
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
      fontWeight: FontWeight.w500,
      height: 20 / 14,
      letterSpacing: 0.1,
    ),
    bodyLarge: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w400,
      height: 24 / 16,
      letterSpacing: 0.5,
    ),
    bodyMedium: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      height: 20 / 14,
      letterSpacing: 0.25,
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
      fontSize: 12,
      fontWeight: FontWeight.w500,
      height: 16 / 12,
      letterSpacing: 0.5,
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
