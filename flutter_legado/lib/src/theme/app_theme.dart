import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_typography.dart';

/// 应用主题定义
///
/// 集中管理 light/dark 双 ThemeData，对齐安卓原版色值并切换到 M3 体系。
/// 使用方式：MaterialApp(theme: AppTheme.light, darkTheme: AppTheme.dark)
class AppTheme {
  AppTheme._();

  /// 亮色主题
  static ThemeData get light => _buildTheme(
        brightness: Brightness.light,
        colorScheme: AppColors.lightColorScheme,
        textTheme: AppTypography.lightTextTheme,
        scaffoldBackground: AppColors.lightBackground,
        appBarBackground: AppColors.lightPrimary,
        cardColor: AppColors.lightBackgroundCard,
        cardBorder: AppColors.lightCardBorder,
        dividerColor: AppColors.lightBgDividerLine,
      );

  /// 暗色主题
  static ThemeData get dark => _buildTheme(
        brightness: Brightness.dark,
        colorScheme: AppColors.darkColorScheme,
        textTheme: AppTypography.darkTextTheme,
        scaffoldBackground: AppColors.darkBackground,
        appBarBackground: AppColors.darkPrimary,
        cardColor: AppColors.darkBackgroundCard,
        cardBorder: AppColors.darkCardBorder,
        dividerColor: AppColors.darkBgDividerLine,
      );

  /// 构建 ThemeData 通用方法
  static ThemeData _buildTheme({
    required Brightness brightness,
    required ColorScheme colorScheme,
    required TextTheme textTheme,
    required Color scaffoldBackground,
    required Color appBarBackground,
    required Color cardColor,
    required Color cardBorder,
    required Color dividerColor,
  }) {
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      textTheme: textTheme,
      scaffoldBackgroundColor: scaffoldBackground,
      dividerColor: dividerColor,

      // AppBar 主题 —— 对齐安卓原版 colorPrimary 背景 + 白色前景
      appBarTheme: AppBarTheme(
        backgroundColor: appBarBackground,
        foregroundColor: AppColors.white,
        centerTitle: false,
        elevation: 4,
        scrolledUnderElevation: 4,
      ),

      // 底部导航栏主题
      navigationBarTheme: NavigationBarThemeData(
        elevation: 1,
        indicatorColor: colorScheme.secondary.withValues(alpha: 0.12),
        backgroundColor: scaffoldBackground,
      ),

      // 卡片主题 —— 对齐安卓端 background_card + card_border_water
      cardTheme: CardThemeData(
        color: cardColor,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: cardBorder),
        ),
      ),

      // 按钮主题
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),

      // 文字按钮主题
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colorScheme.primary,
        ),
      ),

      // 输入框主题
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),

      // ListTile 主题
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        iconColor: colorScheme.onSurfaceVariant,
      ),

      // 分割线主题
      dividerTheme: DividerThemeData(
        color: dividerColor,
        thickness: 0.5,
        space: 1,
      ),

      // FloatingActionButton 主题
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        elevation: 2,
      ),

      // Dialog 主题
      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),

      // BottomSheet 主题
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
      ),

      // TabBar 主题
      tabBarTheme: TabBarThemeData(
        labelColor: colorScheme.primary,
        unselectedLabelColor: colorScheme.onSurfaceVariant,
        indicatorColor: colorScheme.primary,
      ),

      // Switch 主题
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return brightness == Brightness.light
              ? AppColors.lightTvBtnNormal
              : AppColors.darkTvBtnNormal;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary.withValues(alpha: 0.3);
          }
          return colorScheme.outline.withValues(alpha: 0.3);
        }),
      ),

      // PopupMenu 主题
      popupMenuTheme: PopupMenuThemeData(
        color: colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),

      // Snackbar 主题
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colorScheme.inverseSurface,
        contentTextStyle: TextStyle(color: colorScheme.onInverseSurface),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}
