import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_typography.dart';
import 'md3_colors.dart';

/// Android 页面转场（对齐 HapeLee MainActivity NavDisplay 参数）
///
/// HapeLee：push slide 480ms FastOutSlowIn + fade 360ms；
/// pop slide（-1/4 宽）+ scaleOut 0.8 + fade。
/// Flutter 主题 builder 复用路由默认 300ms 总时长，内部按比例切分
/// （slide 全程，fade 前 3/4），近似原生节奏。
class _LegadoAndroidTransitionsBuilder extends PageTransitionsBuilder {
  const _LegadoAndroidTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final slide = Tween<Offset>(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).chain(CurveTween(curve: Curves.fastOutSlowIn)).animate(animation);
    final fade = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: animation, curve: const Interval(0, 0.75)),
    );
    // pop 时次级动画做 scale 0.8 + fade（近似 Compose scaleOut+fadeOut）
    final scale = Tween<double>(begin: 1, end: 0.8)
        .chain(CurveTween(curve: Curves.fastOutSlowIn))
        .animate(secondaryAnimation);
    return SlideTransition(
      position: slide,
      child: FadeTransition(
        opacity: fade,
        child: ScaleTransition(scale: scale, child: child),
      ),
    );
  }
}

/// 应用主题定义（Material Design 3 Expressive）
///
/// 集中管理按调色板装配的 light/dark ThemeData（UI_MD3_PLAN.md Batch 0）：
/// - 12 套内置 MD3 tonal 调色板（[Md3Palettes]，默认 WH）+ 用户自定义 4 色
///   （themeConfigList 功能完整保留，自定义已应用颜色优先于内置 palette role）
/// - Expressive 大圆角经 component theme 显式落地：卡片 20 / 控件 12 /
///   弹窗与底板 28（M3 shape scale 无单一 preset，见计划第七节映射）
/// - Tonal Surface 层次：surfaceContainerLow/Medium/High + 低 elevation
/// - 组件跟随 M3 默认规格（开关/复选框/滑块等不再覆写为 iOS 绿）
///
/// 使用方式：MaterialApp(theme: AppTheme.light, darkTheme: AppTheme.dark)
class AppTheme {
  AppTheme._();

  /// Expressive 圆角：卡片 / 分组
  static const double _cardRadius = 20.0;

  /// 圆角：输入框 / 菜单 / 小控件
  static const double _controlRadius = 12.0;

  /// 圆角：弹窗 / 底部抽屉（M3 extraLarge 28）
  static const double _extraLargeRadius = 28.0;

  /// 亮色主题（默认调色板 WH）
  static ThemeData get light =>
      palette(brightness: Brightness.light, palette: Md3Palettes.wh);

  /// 暗色主题（默认调色板 WH）
  static ThemeData get dark =>
      palette(brightness: Brightness.dark, palette: Md3Palettes.wh);

  /// 亮色主题（支持用户自定义颜色，null 项回退内置默认）
  static ThemeData lightCustom({
    Color? primary,
    Color? accent,
    Color? background,
    Color? bottomBackground,
  }) {
    return palette(
      brightness: Brightness.light,
      palette: Md3Palettes.wh,
      primary: primary,
      accent: accent,
      background: background,
      bottomBackground: bottomBackground,
    );
  }

  /// 暗色主题（支持用户自定义颜色，null 项回退内置默认）
  static ThemeData darkCustom({
    Color? primary,
    Color? accent,
    Color? background,
    Color? bottomBackground,
  }) {
    return palette(
      brightness: Brightness.dark,
      palette: Md3Palettes.wh,
      primary: primary,
      accent: accent,
      background: background,
      bottomBackground: bottomBackground,
    );
  }

  // [UI-fix v2.0.5 | 2026-08-08] 自定义主题颜色支持：对齐原版
  // ThemeConfigFragment 日间/夜间 主色调/强调色/背景色/底部操作栏颜色，
  // 映射：colorPrimary→AppBar 背景（colorBackground 在未设置 primary 时
  // 同时作为 AppBar 背景回退）、colorAccent→全局 Tint+ColorScheme、
  // colorBackground→Scaffold 背景、colorBottomBackground→底部 TabBar 背景；
  // 进入自定义分支后 AppBar 前景一律按 _onColor(appBarBg) 动态计算，
  // 保证深色背景下标题可辨 — Qoder

  /// 按调色板装配主题（UI_MD3_PLAN.md Batch 0：paletteId + themeMode）
  ///
  /// 优先级规则（第九节）：自定义已应用的 4 色 > 内置 palette 对应 role；
  /// 四参数全为 null 时直接使用内置 palette scheme。
  static ThemeData palette({
    required Brightness brightness,
    required Md3Palette palette,
    Color? primary,
    Color? accent,
    Color? background,
    Color? bottomBackground,
  }) {
    var scheme = brightness == Brightness.light
        ? md3LightScheme(palette)
        : md3DarkScheme(palette);

    if (primary == null &&
        accent == null &&
        background == null &&
        bottomBackground == null) {
      return _buildTheme(
        brightness: brightness,
        colorScheme: scheme,
        scaffoldBackground: scheme.surface,
        appBarBackground: scheme.surface,
        appBarForeground: scheme.onSurface,
        separator: scheme.outlineVariant,
        cardColor: brightness == Brightness.light
            ? scheme.surfaceContainerLowest
            : scheme.surfaceContainerLow,
        tabBarBg: scheme.surfaceContainer,
      );
    }

    // 自定义颜色覆盖 palette role：强调色 → primary/secondary/surfaceTint，
    // 背景色 → surface；主色调→AppBar 背景（未设时回退背景色）
    final tint = accent;
    if (tint != null) {
      scheme = scheme.copyWith(
        primary: tint,
        secondary: tint,
        onPrimary: _onColor(tint),
        surfaceTint: tint,
      );
    }
    if (background != null) {
      scheme = scheme.copyWith(surface: background);
    }
    final appBarBg = primary ?? background ?? scheme.surface;
    return _buildTheme(
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackground: background ?? scheme.surface,
      appBarBackground: appBarBg,
      // 前景一律按实际 AppBar 背景明暗动态计算（仅设背景色时同样生效，
      // 避免深色背景配固定深浅文字导致不可辨）
      appBarForeground: _onColor(appBarBg),
      separator: scheme.outlineVariant,
      cardColor: brightness == Brightness.light
          ? scheme.surfaceContainerLowest
          : scheme.surfaceContainerLow,
      tabBarBg: bottomBackground ?? scheme.surfaceContainer,
    );
  }

  /// 根据背景明暗计算前景对比色（对齐原版 ColorUtils.isColorLight 逻辑）
  static Color _onColor(Color bg) =>
      ThemeData.estimateBrightnessForColor(bg) == Brightness.light
          ? Colors.black87
          : Colors.white;

  /// 构建 ThemeData 通用方法（MD3 Expressive 视觉层）
  static ThemeData _buildTheme({
    required Brightness brightness,
    required ColorScheme colorScheme,
    required Color scaffoldBackground,
    required Color appBarBackground,
    required Color appBarForeground,
    required Color separator,
    required Color cardColor,
    required Color tabBarBg,
  }) {
    final bool isLight = brightness == Brightness.light;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      textTheme: AppTypography.lightTextTheme,
      scaffoldBackgroundColor: scaffoldBackground,
      dividerColor: separator,
      splashFactory: InkSparkle.splashFactory,

      // 页面转场 —— M3 标准（对齐 HapeLee MainActivity NavDisplay）
      // Android：push slide480ms FastOutSlowIn + fade360ms LinearOutSlowIn；
      // pop slide + scale0.8 + fade。iOS/桌面走各平台默认。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: _LegadoAndroidTransitionsBuilder(),
        },
      ),

      // AppBar 主题 —— 标准 M3：surface 底 + onSurface 前景，滚动时 tonal 抬升
      appBarTheme: AppBarTheme(
        backgroundColor: appBarBackground,
        foregroundColor: appBarForeground,
        elevation: 0,
        scrolledUnderElevation: 3,
        centerTitle: false,
        titleTextStyle: AppTypography.lightTextTheme.titleLarge
            ?.copyWith(color: appBarForeground),
        toolbarTextStyle: AppTypography.lightTextTheme.bodyLarge
            ?.copyWith(color: appBarForeground),
        // 浅色导航栏 → 深色状态栏图标；暗色导航栏 → 浅色状态栏图标
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarIconBrightness: isLight ? Brightness.dark : Brightness.light,
          statusBarBrightness: isLight ? Brightness.light : Brightness.dark,
          statusBarColor: Colors.transparent,
        ),
      ),

      // 底部导航栏主题 —— M3 NavigationBar（pill 指示器）
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        height: 80,
        backgroundColor: tabBarBg,
        surfaceTintColor: Colors.transparent,
        indicatorColor: colorScheme.secondaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final bool selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected
                ? colorScheme.onSecondaryContainer
                : colorScheme.onSurfaceVariant,
            size: 24,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final bool selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: selected
                ? colorScheme.onSurface
                : colorScheme.onSurfaceVariant,
          );
        }),
      ),

      // 卡片主题 —— tonal 分组容器（亮面用最低层容器，暗面抬一层）
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

      // 按钮主题 —— Expressive 全圆角（stadium）
      // [LAYOUT_MOTION_AUDIT L1] M3 默认高 40dp（原 44 无原生依据）
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          elevation: 0,
          minimumSize: const Size(64, 40),
          padding: const EdgeInsets.symmetric(horizontal: 24),
          textStyle: AppTypography.lightTextTheme.labelLarge,
          shape: const StadiumBorder(),
        ),
      ),

      // 填充按钮（次级）
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 40),
          padding: const EdgeInsets.symmetric(horizontal: 24),
          textStyle: AppTypography.lightTextTheme.labelLarge,
          shape: const StadiumBorder(),
        ),
      ),

      // 轮廓按钮
      // [LAYOUT_MOTION_AUDIT L1] 描边走 outline（原 outlineVariant 差一级）
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.primary,
          minimumSize: const Size(64, 40),
          padding: const EdgeInsets.symmetric(horizontal: 24),
          textStyle: AppTypography.lightTextTheme.labelLarge,
          side: BorderSide(color: colorScheme.outline),
          shape: const StadiumBorder(),
        ),
      ),

      // 文字按钮
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colorScheme.primary,
          textStyle: AppTypography.lightTextTheme.labelLarge,
        ),
      ),

      // 输入框主题 —— M3 填充式（surfaceContainerHighest 底）
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest,
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
          borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
        ),
        hintStyle: AppTypography.lightTextTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),

      // ListTile 主题 —— M3 规格（图标 onSurfaceVariant）
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        iconColor: colorScheme.onSurfaceVariant,
        textColor: colorScheme.onSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_controlRadius),
        ),
      ),

      // 分割线主题 —— M3 outlineVariant 1px
      dividerTheme: DividerThemeData(
        color: separator,
        thickness: 1,
        space: 1,
      ),

      // FloatingActionButton 主题
      // [LAYOUT_MOTION_AUDIT L1] 前景走 primary（HapeLee container=primaryContainer,
      // content=primary，非 M3 默认 onPrimaryContainer）
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.primaryContainer,
        foregroundColor: colorScheme.primary,
        elevation: 3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),

      // Dialog 主题 —— Expressive extraLarge 大圆角
      // [LAYOUT_MOTION_AUDIT L1] 容器走 surfaceContainer（原 High 错一层）
      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_extraLargeRadius),
        ),
      ),

      // BottomSheet 主题 —— Expressive 顶部大圆角
      // [LAYOUT_MOTION_AUDIT L1] 背景走 surfaceContainer + 抓手 onSurfaceVariant
      //（原 Low 错一层且 showDragHandle=false 关掉抓手）
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        showDragHandle: true,
        dragHandleColor: colorScheme.onSurfaceVariant,
      ),

      // TabBar 主题 —— M3 主色指示器
      tabBarTheme: TabBarThemeData(
        labelColor: colorScheme.primary,
        unselectedLabelColor: colorScheme.onSurfaceVariant,
        indicatorColor: colorScheme.primary,
        indicatorSize: TabBarIndicatorSize.label,
        labelStyle: AppTypography.lightTextTheme.titleSmall,
        unselectedLabelStyle: AppTypography.lightTextTheme.titleSmall,
        tabAlignment: TabAlignment.start,
      ),

      // PopupMenu 主题 —— tonal 容器 + Expressive 圆角
      // [LAYOUT_MOTION_AUDIT L1] 容器 surfaceContainerLow + elev4
      //（原 surfaceContainer+elev3 各差一级）
      popupMenuTheme: PopupMenuThemeData(
        color: colorScheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),

      // DropdownMenu 主题
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStateProperty.all(
            colorScheme.surfaceContainerLow,
          ),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      ),

      // Snackbar 主题 —— M3 inverseSurface 反色
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colorScheme.inverseSurface,
        contentTextStyle: TextStyle(color: colorScheme.onInverseSurface),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_controlRadius),
        ),
      ),

      // Tooltip 主题
      // [LAYOUT_MOTION_AUDIT L1] PlainTooltip 走 surfaceContainerLow/onSurface
      //（原 inverseSurface 为 Flutter 单方追加，原生无依据）
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(4),
        ),
        textStyle: TextStyle(
          color: colorScheme.onSurface,
          fontSize: 12,
        ),
      ),

      // Chip 主题 —— M3 默认（选中态 secondaryContainer 落地）
      // [LAYOUT_MOTION_AUDIT L1] 新增：此前完全无 chip 主题
      // [FIX 2026-09-04] label 色显式声明：未选中 onSurfaceVariant，
      // 选中 onSecondaryContainer。否则 FilterChip 未选中态回退黑色，
      // 暗色下对比度仅 1.1（发现页顶部“全部”看不清实锤）
      chipTheme: ChipThemeData(
        backgroundColor: colorScheme.surfaceContainerLow,
        selectedColor: colorScheme.secondaryContainer,
        secondarySelectedColor: colorScheme.secondaryContainer,
        labelStyle: AppTypography.lightTextTheme.labelLarge?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
        secondaryLabelStyle: AppTypography.lightTextTheme.labelLarge?.copyWith(
          color: colorScheme.onSecondaryContainer,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        side: BorderSide(color: colorScheme.outline),
      ),

      // Switch 主题 —— 跟随 primary（M3 默认，显式声明防回归）
      // [LAYOUT_MOTION_AUDIT L1] 新增
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.onPrimary;
          }
          return colorScheme.outline;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return colorScheme.surfaceContainerHighest;
        }),
      ),

      // Checkbox 主题 —— 跟随 primary（M3 默认，显式声明）
      // [LAYOUT_MOTION_AUDIT L1] 新增
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return null;
        }),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(2),
        ),
      ),

      // Radio 主题 —— 跟随 primary（M3 默认，显式声明）
      // [LAYOUT_MOTION_AUDIT L1] 新增
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return null;
        }),
      ),

      // Slider 主题 —— 跟随 primary（M3 默认，显式声明）
      // [LAYOUT_MOTION_AUDIT L1] 新增
      sliderTheme: SliderThemeData(
        activeTrackColor: colorScheme.primary,
        inactiveTrackColor: colorScheme.surfaceContainerHighest,
        thumbColor: colorScheme.primary,
        overlayColor: colorScheme.primary.withValues(alpha: 0.12),
      ),

      // IconButton 主题 —— M3 标准形状
      // [LAYOUT_MOTION_AUDIT L1] 新增
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: colorScheme.onSurfaceVariant,
        ),
      ),

      // SearchBar 主题 —— 容器 surfaceContainerLow（HapeLee M3 分支）
      // [LAYOUT_MOTION_AUDIT L1] 新增
      searchBarTheme: SearchBarThemeData(
        backgroundColor: WidgetStateProperty.all(
          colorScheme.surfaceContainerLow,
        ),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(32),
          ),
        ),
        hintStyle: WidgetStateProperty.all(
          AppTypography.lightTextTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ),

      // Menu 主题 —— MenuItem 行规（48 高 + 选中 primary）
      // [LAYOUT_MOTION_AUDIT L1] 新增
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStateProperty.all(
            colorScheme.surfaceContainerLow,
          ),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
    );
  }
}
