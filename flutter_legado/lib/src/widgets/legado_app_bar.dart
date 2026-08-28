import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/home_screen.dart';

/// Legado 统一顶栏
///
/// 对齐 Android [TitleBar] / 子 Activity `displayHomeAsUp` 语义：
///
/// - **主 Tab 内页**（[HomeScreen] 子树）：不显示返回（原版 Fragment 无 Up）
/// - **独立 push 子页**：左侧 M3 返回（[Icons.arrow_back]）
/// - **禁止** Material 默认 `automaticallyImplyLeading` 误注入返回
///
/// 传入 [leading] 时完全尊重调用方（批量模式关闭钮、文件浏览上级等）。
/// [MD3 Batch 1] 视觉随 appTheme M3 化（tonal 抬升/前景 onSurface），
/// LargeTitle 折叠顶栏随各主 Tab 根页所在批次落地。
class LegadoAppBar extends StatelessWidget implements PreferredSizeWidget {
  const LegadoAppBar({
    super.key,
    this.leading,
    this.title,
    this.actions,
    this.flexibleSpace,
    this.bottom,
    this.elevation,
    this.scrolledUnderElevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.shape,
    this.backgroundColor,
    this.foregroundColor,
    this.iconTheme,
    this.actionsIconTheme,
    this.primary = true,
    this.centerTitle,
    this.excludeHeaderSemantics = false,
    this.titleSpacing,
    this.toolbarOpacity = 1.0,
    this.bottomOpacity = 1.0,
    this.toolbarHeight,
    this.leadingWidth,
    this.toolbarTextStyle,
    this.titleTextStyle,
    this.systemOverlayStyle,
    this.forceMaterialTransparency,
    /// 显式控制返回；null 时按 Tab 根 / Navigator.canPop 推断
    this.showBack,
  });

  final Widget? leading;
  final Widget? title;
  final List<Widget>? actions;
  final Widget? flexibleSpace;
  final PreferredSizeWidget? bottom;
  final double? elevation;
  final double? scrolledUnderElevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final ShapeBorder? shape;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final IconThemeData? iconTheme;
  final IconThemeData? actionsIconTheme;
  final bool primary;
  final bool? centerTitle;
  final bool excludeHeaderSemantics;
  final double? titleSpacing;
  final double toolbarOpacity;
  final double bottomOpacity;
  final double? toolbarHeight;
  final double? leadingWidth;
  final TextStyle? toolbarTextStyle;
  final TextStyle? titleTextStyle;
  final SystemUiOverlayStyle? systemOverlayStyle;
  final bool? forceMaterialTransparency;
  final bool? showBack;

  /// 是否应在 leading 区展示返回（Tab 根页 false；可 pop 子页 true）
  static bool shouldShowBack(BuildContext context, {bool? showBack}) {
    if (showBack != null) return showBack;
    if (context.findAncestorWidgetOfExactType<HomeScreen>() != null) {
      return false;
    }
    return Navigator.of(context).canPop();
  }

  Widget? _buildLeading(BuildContext context) {
    if (leading != null) return leading;
    if (!shouldShowBack(context, showBack: showBack)) return null;
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      onPressed: () => Navigator.maybePop(context),
    );
  }

  /// 标题防截断保护：Text 标题单行 + FittedBox 自适应缩放，
  /// 窄屏/系统字体放大时完整显示标题（不出现半个字/省略号）；
  /// 空间充足时字号不变（20sp 与原版一致）
  Widget? _safeTitle(Widget? title) {
    if (title is Text) {
      return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          title.data ?? '',
          style: title.style,
          textAlign: title.textAlign,
          maxLines: 1,
        ),
      );
    }
    return title;
  }

  @override
  Widget build(BuildContext context) {
    final bg = backgroundColor ??
        Theme.of(context).appBarTheme.backgroundColor ??
        Theme.of(context).colorScheme.surface;
    final isLight =
        ThemeData.estimateBrightnessForColor(bg) == Brightness.light;
    final effectiveOverlay = systemOverlayStyle ??
        SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness:
              isLight ? Brightness.dark : Brightness.light,
          statusBarBrightness: isLight ? Brightness.light : Brightness.dark,
        );

    return AppBar(
      leading: _buildLeading(context),
      automaticallyImplyLeading: false,
      title: _safeTitle(title),
      actions: actions,
      flexibleSpace: flexibleSpace,
      bottom: bottom,
      elevation: elevation,
      scrolledUnderElevation: scrolledUnderElevation,
      shadowColor: shadowColor,
      surfaceTintColor: surfaceTintColor,
      shape: shape,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      iconTheme: iconTheme,
      actionsIconTheme: actionsIconTheme,
      primary: primary,
      centerTitle: centerTitle,
      excludeHeaderSemantics: excludeHeaderSemantics,
      titleSpacing: titleSpacing,
      toolbarOpacity: toolbarOpacity,
      bottomOpacity: bottomOpacity,
      toolbarHeight: toolbarHeight,
      leadingWidth: leadingWidth,
      toolbarTextStyle: toolbarTextStyle,
      titleTextStyle: titleTextStyle,
      systemOverlayStyle: effectiveOverlay,
      forceMaterialTransparency: forceMaterialTransparency ?? false,
    );
  }

  @override
  Size get preferredSize {
    final h = toolbarHeight ?? kToolbarHeight;
    if (bottom != null) {
      return Size.fromHeight(h + bottom!.preferredSize.height);
    }
    return Size.fromHeight(h);
  }
}

/// 系统栏样式：按 AppBar 背景明暗计算（浅底深图标 / 深底浅图标）
SystemUiOverlayStyle _legadoSystemOverlay(BuildContext context) {
  final bg = Theme.of(context).appBarTheme.backgroundColor ??
      Theme.of(context).colorScheme.surface;
  final isLight = ThemeData.estimateBrightnessForColor(bg) == Brightness.light;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: isLight ? Brightness.dark : Brightness.light,
    statusBarBrightness: isLight ? Brightness.light : Brightness.dark,
  );
}

/// 主 Tab 根页可折叠 LargeTitle 头部 sliver（UI_MD3_PLAN.md Batch 1 顶栏决策）
///
/// - [large] 为 true（页面有文字标题，如「书架」无分组、「我的」）时使用
///   SliverAppBar.large：展开 152dp 大标题，滚动折叠为标准 M3 AppBar（tonal
///   抬升），跳顶/复位时随滚动位置自然展开；
/// - 为 false（title 槽为分组 TabBar 等功能控件，保持原版嵌入结构）时使用
///   pinned SliverAppBar，工具栏高度与交互不变。
///
/// 发现/订阅两根页的顶栏为原版 view_search 嵌入式搜索框（无标题文字），
/// 不适用 LargeTitle，继续使用 [LegadoAppBar]；子页同样用 [LegadoAppBar]。
class LegadoTabRootHeaderSliver extends StatelessWidget {
  final Widget title;
  final List<Widget>? actions;
  final bool large;
  final double? titleSpacing;

  const LegadoTabRootHeaderSliver({
    super.key,
    required this.title,
    this.actions,
    required this.large,
    this.titleSpacing,
  });

  @override
  Widget build(BuildContext context) {
    final overlay = _legadoSystemOverlay(context);
    if (large) {
      return SliverAppBar.large(
        automaticallyImplyLeading: false,
        title: title,
        actions: actions,
        titleSpacing: titleSpacing,
        systemOverlayStyle: overlay,
      );
    }
    return SliverAppBar(
      pinned: true,
      automaticallyImplyLeading: false,
      title: title,
      actions: actions,
      titleSpacing: titleSpacing,
      systemOverlayStyle: overlay,
    );
  }
}

/// 静态标题根页的可折叠 LargeTitle 装配（NestedScrollView）
///
/// body 保持原滚动结构不变（内层 ListView/CustomScrollView 均可），
/// 头部为 SliverAppBar.large。用于「我的」等无复杂顶栏状态的根页。
class LegadoLargeTitleScroll extends StatelessWidget {
  final Widget title;
  final List<Widget>? actions;
  final Widget body;

  const LegadoLargeTitleScroll({
    super.key,
    required this.title,
    this.actions,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return NestedScrollView(
      headerSliverBuilder: (context, innerBoxIsScrolled) => [
        SliverAppBar.large(
          automaticallyImplyLeading: false,
          title: title,
          actions: actions,
          systemOverlayStyle: _legadoSystemOverlay(context),
        ),
      ],
      body: body,
    );
  }
}
