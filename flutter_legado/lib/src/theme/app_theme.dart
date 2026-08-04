import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'app_typography.dart';

/// 应用主题定义（Apple / iOS 设计体系）
///
/// 集中管理 light/dark 双 ThemeData。在保持与原版功能一致的前提下，
/// 将组件视觉切换为 iOS Human Interface Guidelines 风格：
/// - 导航栏（AppBar）采用浅色系统材质 + 深色标题（亮色），hairline 底边
/// - 底部 TabBar 采用 iOS 半透明材质 + 顶部 hairline
/// - 卡片 / 列表采用 iOS「分组背景 + 白色圆角卡片」层次
/// - 开关采用 iOS 绿色；按钮采用胶囊形状；强调色为 iOS 系统蓝
///
/// 使用方式：MaterialApp(theme: AppTheme.light, darkTheme: AppTheme.dark)
class AppTheme {
  AppTheme._();

  /// iOS 圆角：卡片 / 分组
  static const double _cardRadius = 12.0;

  /// iOS 圆角：按钮 / 输入框 / 弹窗
  static const double _controlRadius = 10.0;

  /// 亮色主题
  static ThemeData get light => _buildTheme(
        brightness: Brightness.light,
        colorScheme: AppColors.lightColorScheme,
        textTheme: AppTypography.lightTextTheme,
        scaffoldBackground: AppColors.lightBackground,
        appBarBackground: AppColors.lightBackground,
        appBarForeground: AppColors.lightPrimaryText,
        separator: AppColors.lightBgDividerLine,
        cardColor: AppColors.lightBackgroundCard,
        tabBarBg: AppColors.lightNavigationBarBg,
        tint: AppColors.lightPrimary,
        secondaryLabel: AppColors.lightSecondaryText,
        systemGreen: AppColors.iosGreenLight,
        fill: AppColors.lightTertiaryFill,
      );

  /// 暗色主题
  static ThemeData get dark => _buildTheme(
        brightness: Brightness.dark,
        colorScheme: AppColors.darkColorScheme,
        textTheme: AppTypography.darkTextTheme,
        scaffoldBackground: AppColors.darkBackground,
        appBarBackground: AppColors.darkBackground,
        appBarForeground: AppColors.darkPrimaryText,
        separator: AppColors.darkBgDividerLine,
        cardColor: AppColors.darkBackgroundCard,
        tabBarBg: AppColors.darkNavigationBarBg,
        tint: AppColors.darkPrimary,
        secondaryLabel: AppColors.darkSecondaryText,
        systemGreen: AppColors.iosGreenDark,
        fill: AppColors.darkTertiaryFill,
      );

  /// 构建 ThemeData 通用方法
  static ThemeData _buildTheme({
    required Brightness brightness,
    required ColorScheme colorScheme,
    required TextTheme textTheme,
    required Color scaffoldBackground,
    required Color appBarBackground,
    required Color appBarForeground,
    required Color separator,
    required Color cardColor,
    required Color tabBarBg,
    required Color tint,
    required Color secondaryLabel,
    required Color systemGreen,
    required Color fill,
  }) {
    final bool isLight = brightness == Brightness.light;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      textTheme: textTheme,
      scaffoldBackgroundColor: scaffoldBackground,
      dividerColor: separator,
      splashFactory: InkSparkle.splashFactory,

      // AppBar 主题 —— iOS 浅色系统材质 + 深色标题 + hairline 底边
      appBarTheme: AppBarTheme(
        backgroundColor: appBarBackground,
        foregroundColor: appBarForeground,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: appBarForeground,
        ),
        toolbarTextStyle: textTheme.bodyLarge?.copyWith(
          color: appBarForeground,
        ),
        iconTheme: IconThemeData(color: tint),
        actionsIconTheme: IconThemeData(color: tint),
        // hairline 底边，替代阴影
        shape: Border(
          bottom: BorderSide(color: separator, width: 0.0),
        ),
        // 浅色导航栏 → 深色状态栏图标；暗色导航栏 → 浅色状态栏图标
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarIconBrightness: isLight ? Brightness.dark : Brightness.light,
          statusBarBrightness: isLight ? Brightness.light : Brightness.dark,
          statusBarColor: Colors.transparent,
        ),
      ),

      // 底部导航栏主题 —— iOS Tab Bar（半透明材质 + 顶部 hairline）
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        height: 60,
        backgroundColor: tabBarBg,
        surfaceTintColor: Colors.transparent,
        indicatorColor: Colors.transparent,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final bool selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? tint : secondaryLabel,
            size: 24,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final bool selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: selected ? tint : secondaryLabel,
          );
        }),
      ),

      // 卡片主题 —— iOS 分组卡片（白色圆角，无边框无阴影）
      cardTheme: CardThemeData(
        color: cardColor,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_cardRadius),
        ),
        clipBehavior: Clip.antiAlias,
      ),

      // 按钮主题 —— iOS 胶囊主按钮
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: tint,
          foregroundColor: colorScheme.onPrimary,
          elevation: 0,
          minimumSize: const Size(64, 50),
          textStyle: textTheme.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_controlRadius),
          ),
        ),
      ),

      // 填充按钮（次级）
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 50),
          textStyle: textTheme.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_controlRadius),
          ),
        ),
      ),

      // 轮廓按钮
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: tint,
          minimumSize: const Size(64, 50),
          textStyle: textTheme.labelLarge,
          side: BorderSide(color: colorScheme.outlineVariant),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_controlRadius),
          ),
        ),
      ),

      // 文字按钮 —— iOS 纯文字 Tint 按钮
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: tint,
          textStyle: textTheme.labelLarge,
        ),
      ),

      // 输入框主题 —— iOS 圆角灰色填充
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: fill,
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_controlRadius),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_controlRadius),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_controlRadius),
          borderSide: BorderSide(color: tint, width: 1.5),
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(color: secondaryLabel),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),

      // ListTile 主题
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        iconColor: tint,
        textColor: colorScheme.onSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_controlRadius),
        ),
      ),

      // 分割线主题 —— iOS hairline
      dividerTheme: DividerThemeData(
        color: separator,
        thickness: 0.5,
        space: 0.5,
      ),

      // FloatingActionButton 主题 —— iOS Tint 圆形
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: tint,
        foregroundColor: colorScheme.onPrimary,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
      ),

      // Dialog 主题 —— iOS 弹窗
      dialogTheme: DialogThemeData(
        backgroundColor: cardColor,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),

      // BottomSheet 主题 —— iOS 底部抽屉
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: cardColor,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
        ),
        showDragHandle: false,
      ),

      // TabBar 主题 —— 置于浅色导航栏内，选中为 Tint + Tint 指示器
      tabBarTheme: TabBarThemeData(
        labelColor: tint,
        unselectedLabelColor: secondaryLabel,
        indicatorColor: tint,
        indicatorSize: TabBarIndicatorSize.label,
        labelStyle: textTheme.titleSmall,
        unselectedLabelStyle: textTheme.titleSmall,
        tabAlignment: TabAlignment.start,
      ),

      // Switch 主题 —— iOS 绿色开关（白色滑块）
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          return AppColors.white;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return systemGreen;
          }
          return colorScheme.outline.withValues(alpha: 0.35);
        }),
      ),

      // Checkbox / Radio —— Tint
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return tint;
          return Colors.transparent;
        }),
        checkColor: WidgetStateProperty.all(AppColors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected) ? tint : secondaryLabel;
        }),
      ),

      // PopupMenu 主题 —— iOS 菜单
      popupMenuTheme: PopupMenuThemeData(
        color: cardColor,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(13),
        ),
      ),

      // DropdownMenu 主题
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStateProperty.all(cardColor),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(13),
            ),
          ),
        ),
      ),

      // Snackbar 主题
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colorScheme.inverseSurface,
        contentTextStyle: TextStyle(color: colorScheme.onInverseSurface),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),

      // Slider / Progress —— Tint
      sliderTheme: SliderThemeData(
        activeTrackColor: tint,
        thumbColor: AppColors.white,
        inactiveTrackColor: colorScheme.outline.withValues(alpha: 0.3),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: tint,
        linearTrackColor: colorScheme.outline.withValues(alpha: 0.2),
        circularTrackColor: tint,
      ),

      // Tooltip
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: colorScheme.inverseSurface,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: TextStyle(color: colorScheme.onInverseSurface, fontSize: 13),
      ),
    );
  }
}
