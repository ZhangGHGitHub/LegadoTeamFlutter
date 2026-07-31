import 'package:flutter/material.dart';

/// 应用字体排版定义
///
/// 字号层级对齐安卓端：28/22/18/16/14/12
/// 行高规范：标题 1.2、正文 1.5、辅助 1.4
class AppTypography {
  AppTypography._();

  // ============================================================
  // 字号常量（对齐安卓端 sp 值）
  // ============================================================

  /// 大标题字号（28sp）
  static const double displaySize = 28.0;

  /// 标题字号（22sp）
  static const double largeTitleSize = 22.0;

  /// 副标题字号（18sp）
  static const double titleSize = 18.0;

  /// 正文字号（16sp）
  static const double bodySize = 16.0;

  /// 辅助文字字号（14sp）
  static const double labelSize = 14.0;

  /// 小字字号（12sp）
  static const double captionSize = 12.0;

  // ============================================================
  // 行高常量
  // ============================================================

  /// 标题行高
  static const double headingLineHeight = 1.2;

  /// 正文行高
  static const double bodyLineHeight = 1.5;

  /// 辅助文字行高
  static const double labelLineHeight = 1.4;

  // ============================================================
  // M3 TextTheme 构建
  // ============================================================

  /// 亮色 TextTheme
  static const TextTheme lightTextTheme = TextTheme(
    displayLarge: TextStyle(
      fontSize: displaySize,
      fontWeight: FontWeight.w400,
      height: headingLineHeight,
      letterSpacing: -0.25,
    ),
    displayMedium: TextStyle(
      fontSize: displaySize,
      fontWeight: FontWeight.w400,
      height: headingLineHeight,
    ),
    displaySmall: TextStyle(
      fontSize: largeTitleSize,
      fontWeight: FontWeight.w400,
      height: headingLineHeight,
    ),
    headlineMedium: TextStyle(
      fontSize: largeTitleSize,
      fontWeight: FontWeight.w500,
      height: headingLineHeight,
    ),
    headlineSmall: TextStyle(
      fontSize: titleSize,
      fontWeight: FontWeight.w500,
      height: headingLineHeight,
    ),
    titleLarge: TextStyle(
      fontSize: titleSize,
      fontWeight: FontWeight.w500,
      height: headingLineHeight,
      letterSpacing: 0.15,
    ),
    titleMedium: TextStyle(
      fontSize: bodySize,
      fontWeight: FontWeight.w500,
      height: labelLineHeight,
      letterSpacing: 0.15,
    ),
    titleSmall: TextStyle(
      fontSize: labelSize,
      fontWeight: FontWeight.w500,
      height: labelLineHeight,
      letterSpacing: 0.1,
    ),
    bodyLarge: TextStyle(
      fontSize: bodySize,
      fontWeight: FontWeight.w400,
      height: bodyLineHeight,
      letterSpacing: 0.5,
    ),
    bodyMedium: TextStyle(
      fontSize: labelSize,
      fontWeight: FontWeight.w400,
      height: bodyLineHeight,
      letterSpacing: 0.25,
    ),
    bodySmall: TextStyle(
      fontSize: captionSize,
      fontWeight: FontWeight.w400,
      height: labelLineHeight,
      letterSpacing: 0.4,
    ),
    labelLarge: TextStyle(
      fontSize: labelSize,
      fontWeight: FontWeight.w500,
      height: labelLineHeight,
      letterSpacing: 0.1,
    ),
    labelMedium: TextStyle(
      fontSize: captionSize,
      fontWeight: FontWeight.w500,
      height: labelLineHeight,
      letterSpacing: 0.5,
    ),
    labelSmall: TextStyle(
      fontSize: 10.0,
      fontWeight: FontWeight.w500,
      height: labelLineHeight,
      letterSpacing: 0.5,
    ),
  );

  /// 暗色 TextTheme（与亮色相同排版，颜色由 ColorScheme 控制）
  static const TextTheme darkTextTheme = lightTextTheme;
}
