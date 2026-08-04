import 'package:flutter/material.dart';

/// 应用字体排版定义（Apple / iOS 设计体系）
///
/// 字阶对齐 iOS Human Interface Guidelines 的 Dynamic Type 规格。
/// iOS 使用 SF Pro（本文件不指定 fontFamily，运行时自动取系统字体：
/// iOS 上即 SF Pro，Android 上为 Roboto），重点还原字号 / 字重 / 行高层级。
///
/// 语义槽位与原版保持一致（保证既有引用不破坏），另补充 iOS 完整字阶常量。
class AppTypography {
  AppTypography._();

  // ============================================================
  // iOS Dynamic Type 字号常量
  // ============================================================

  /// Large Title（34pt）—— 大标题导航
  static const double displaySize = 34.0;

  /// Title 1（28pt）
  static const double largeTitleSize = 28.0;

  /// Title 2（22pt）
  static const double title2Size = 22.0;

  /// Title 3（20pt）
  static const double titleSize = 20.0;

  /// Headline（17pt，semibold）
  static const double headlineSize = 17.0;

  /// Body（17pt）
  static const double bodySize = 17.0;

  /// Callout（16pt）
  static const double calloutSize = 16.0;

  /// Subheadline（15pt）
  static const double labelSize = 15.0;

  /// Footnote（13pt）
  static const double footnoteSize = 13.0;

  /// Caption 1（12pt）
  static const double captionSize = 12.0;

  /// Caption 2（11pt）
  static const double caption2Size = 11.0;

  // ============================================================
  // 行高常量（iOS 行距比例）
  // ============================================================

  /// 标题行高（≈ 1.21）
  static const double headingLineHeight = 1.21;

  /// 正文行高（≈ 1.47）
  static const double bodyLineHeight = 1.47;

  /// 辅助文字行高（≈ 1.38）
  static const double labelLineHeight = 1.38;

  // ============================================================
  // M3 TextTheme 构建（映射到 iOS 字阶）
  // ============================================================

  /// 亮色 TextTheme
  static const TextTheme lightTextTheme = TextTheme(
    displayLarge: TextStyle(
      fontSize: displaySize,
      fontWeight: FontWeight.w700,
      height: headingLineHeight,
      letterSpacing: -0.4,
    ),
    displayMedium: TextStyle(
      fontSize: largeTitleSize,
      fontWeight: FontWeight.w700,
      height: headingLineHeight,
      letterSpacing: 0.0,
    ),
    displaySmall: TextStyle(
      fontSize: title2Size,
      fontWeight: FontWeight.w600,
      height: headingLineHeight,
      letterSpacing: 0.37,
    ),
    headlineMedium: TextStyle(
      fontSize: titleSize,
      fontWeight: FontWeight.w600,
      height: headingLineHeight,
      letterSpacing: 0.38,
    ),
    headlineSmall: TextStyle(
      fontSize: headlineSize,
      fontWeight: FontWeight.w600,
      height: 1.29,
      letterSpacing: -0.41,
    ),
    titleLarge: TextStyle(
      fontSize: titleSize,
      fontWeight: FontWeight.w600,
      height: headingLineHeight,
      letterSpacing: 0.38,
    ),
    titleMedium: TextStyle(
      fontSize: bodySize,
      fontWeight: FontWeight.w500,
      height: 1.35,
      letterSpacing: -0.41,
    ),
    titleSmall: TextStyle(
      fontSize: labelSize,
      fontWeight: FontWeight.w500,
      height: 1.33,
      letterSpacing: -0.24,
    ),
    bodyLarge: TextStyle(
      fontSize: bodySize,
      fontWeight: FontWeight.w400,
      height: bodyLineHeight,
      letterSpacing: -0.41,
    ),
    bodyMedium: TextStyle(
      fontSize: calloutSize,
      fontWeight: FontWeight.w400,
      height: 1.31,
      letterSpacing: -0.32,
    ),
    bodySmall: TextStyle(
      fontSize: labelSize,
      fontWeight: FontWeight.w400,
      height: 1.33,
      letterSpacing: -0.24,
    ),
    labelLarge: TextStyle(
      fontSize: bodySize,
      fontWeight: FontWeight.w500,
      height: 1.29,
      letterSpacing: -0.41,
    ),
    labelMedium: TextStyle(
      fontSize: footnoteSize,
      fontWeight: FontWeight.w400,
      height: 1.38,
      letterSpacing: -0.08,
    ),
    labelSmall: TextStyle(
      fontSize: caption2Size,
      fontWeight: FontWeight.w400,
      height: 1.18,
      letterSpacing: 0.07,
    ),
  );

  /// 暗色 TextTheme（与亮色相同排版，颜色由 ColorScheme 控制）
  static const TextTheme darkTextTheme = lightTextTheme;
}
