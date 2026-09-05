import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';

import '../providers/ui_settings/ui_settings_notifier.dart';
import '../screens/home_screen.dart';
import 'top_bar_button.dart';

/// Legado 统一顶栏
///
/// 对齐 Android [TitleBar] / 子 Activity `displayHomeAsUp` 语义：
///
/// - **主 Tab 内页**（[HomeScreen] 子树）：不显示返回（原版 Fragment 无 Up）
/// - **独立 push 子页**：左侧 M3 返回（[Symbols.arrow_back_rounded]）
/// - **禁止** Material 默认 `automaticallyImplyLeading` 误注入返回
///
/// 传入 [leading] 时完全尊重调用方（批量模式关闭钮、文件浏览上级等）。
/// [MD3 Batch 1] 视觉随 appTheme M3 化（tonal 抬升/前景 onSurface），
/// LargeTitle 折叠顶栏随各主 Tab 根页所在批次落地。
/// [UI_SYNC_REFACTOR B2] actions/leading 统一经 TopBarActionStyler 注入
/// 5 档按钮样式与 merge 胶囊（设置即时全局生效）；背景按 topBarOpacity
/// 混入透明度；显式 [actionsStyle]/[mergeActions] 参数可覆盖全局设置。
/// 设置读取走全局 [uiSettingsListenable]（组件不依赖 Riverpod scope，
/// 58+ 使用点与既有无 ProviderScope 测试保持兼容），变化时经
/// ValueListenableBuilder 原位重建。
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
    /// 覆盖全局顶栏按钮样式（null = 跟随主题设置）
    this.actionsStyle,
    /// 覆盖全局 merge 胶囊开关（null = 跟随主题设置）
    this.mergeActions,
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
  final TopBarButtonStyle? actionsStyle;
  final bool? mergeActions;

  /// 是否应在 leading 区展示返回（Tab 根页 false；可 pop 子页 true）
  static bool shouldShowBack(BuildContext context, {bool? showBack}) {
    if (showBack != null) return showBack;
    if (context.findAncestorWidgetOfExactType<HomeScreen>() != null) {
      return false;
    }
    return Navigator.of(context).canPop();
  }

  Widget? _buildLeading(
    BuildContext context, {
    required TopBarButtonStyle style,
    required bool merge,
  }) {
    if (leading != null) {
      return TopBarActionStyler.styleActions(
        context,
        [leading!],
        style: style,
        merge: false,
      ).first;
    }
    if (!shouldShowBack(context, showBack: showBack)) return null;
    return TopBarActionStyler.styleActions(
      context,
      [
        IconButton(
          icon: const Icon(Symbols.arrow_back_rounded),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () => Navigator.maybePop(context),
        ),
      ],
      style: style,
      merge: merge,
    ).first;
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
    return ValueListenableBuilder<UiSettingsState>(
      valueListenable: uiSettingsListenable,
      builder: (context, ui, _) {
        final style = actionsStyle ?? ui.topBarButtonStyle;
        final merge = mergeActions ?? ui.mergeTopBarActions;
        var bg = backgroundColor ??
            Theme.of(context).appBarTheme.backgroundColor ??
            Theme.of(context).colorScheme.surface;
        // [UI_SYNC_REFACTOR B2] 顶栏不透明度（0-100，100=不变）
        if (ui.topBarOpacity < 100 && bg != Colors.transparent) {
          bg = bg.withValues(alpha: ui.topBarOpacity / 100);
        }
        // [UI_SYNC_REFACTOR R1] 毛玻璃：enableBlur 开启且非透明背景时，
        // 半透明底（topBarBlurAlpha/255）+ BackdropFilter（topBarBlurRadius）
        final useBlur = ui.enableBlur && bg != Colors.transparent;
        if (useBlur) {
          bg = bg.withValues(alpha: ui.topBarBlurAlpha / 255);
        }
        final isLight =
            ThemeData.estimateBrightnessForColor(bg) == Brightness.light;
        final effectiveOverlay = systemOverlayStyle ??
            SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness:
                  isLight ? Brightness.dark : Brightness.light,
              statusBarBrightness: isLight ? Brightness.light : Brightness.dark,
            );

        Widget bar = AppBar(
          leading: _buildLeading(context, style: style, merge: merge),
          automaticallyImplyLeading: false,
          title: _safeTitle(title),
          actions: TopBarActionStyler.styleActions(
            context,
            actions,
            style: style,
            merge: merge,
          ),
          flexibleSpace: flexibleSpace,
          bottom: bottom,
          elevation: elevation,
          scrolledUnderElevation: scrolledUnderElevation,
          shadowColor: shadowColor,
          surfaceTintColor: surfaceTintColor,
          shape: shape,
          backgroundColor: bg,
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
        // [UI_SYNC_REFACTOR R1] 毛玻璃包裹（实色半透明底 + 背后内容模糊）
        if (useBlur) {
          bar = ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: ui.topBarBlurRadius.toDouble(),
                sigmaY: ui.topBarBlurRadius.toDouble(),
              ),
              child: bar,
            ),
          );
        }
        return bar;
      },
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

/// LargeTitle 子树字阶覆写（P1：对齐参考风格 24dp）
///
/// Flutter 的 SliverAppBar.large 展开态硬编码取 textTheme.headlineMedium
/// （28dp），参考仓库 Compose M3 LargeTopAppBar 为 headlineSmall（24dp）。
/// 此处以子树级 Theme 把 headlineMedium 映射为 headlineSmall——仅影响
/// 头部 sliver 内部（工具栏走 titleLarge 不受影响），展开/折叠动画完整。
Widget _largeTitleThemeOverride(BuildContext context, Widget child) {
  final theme = Theme.of(context);
  return Theme(
    data: theme.copyWith(
      textTheme: theme.textTheme.copyWith(
        headlineMedium: theme.textTheme.headlineSmall
            ?.apply(color: theme.colorScheme.onSurface),
      ),
    ),
    child: child,
  );
}

/// 顶栏设置监听 State 基类：uiSettings 变化时重建（sliver 场景无法用
/// ValueListenableBuilder 直包，经 setState 原位重建）
mixin _UiSettingsListener<T extends StatefulWidget> on State<T> {
  @override
  void initState() {
    super.initState();
    uiSettingsListenable.addListener(_onUiSettingsChanged);
  }

  @override
  void dispose() {
    uiSettingsListenable.removeListener(_onUiSettingsChanged);
    super.dispose();
  }

  void _onUiSettingsChanged() {
    if (mounted) setState(() {});
  }
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
/// [UI_SYNC_REFACTOR B2] useFlexibleTopAppBar=false 时 large 回退 pinned
/// 标准栏；滚动色插值经 surfaceTint→surfaceContainer 等效（对齐参考仓
/// scrolledContainerColor）。
class LegadoTabRootHeaderSliver extends StatefulWidget {
  final Widget title;
  final List<Widget>? actions;
  final bool large;
  final double? titleSpacing;

  /// 顶栏 bottomContent（对齐参考仓 DynamicTopAppBar 搜索行；pinned 常驻）
  final PreferredSizeWidget? bottom;

  const LegadoTabRootHeaderSliver({
    super.key,
    required this.title,
    this.actions,
    required this.large,
    this.titleSpacing,
    this.bottom,
  });

  @override
  State<LegadoTabRootHeaderSliver> createState() =>
      _LegadoTabRootHeaderSliverState();
}

class _LegadoTabRootHeaderSliverState extends State<LegadoTabRootHeaderSliver>
    with _UiSettingsListener {
  @override
  Widget build(BuildContext context) {
    final ui = uiSettingsListenable.value;
    final overlay = _legadoSystemOverlay(context);
    final cs = Theme.of(context).colorScheme;
    final styledActions = TopBarActionStyler.styleActions(
      context,
      widget.actions,
      style: ui.topBarButtonStyle,
      merge: ui.mergeTopBarActions,
    );
    if (widget.large && ui.useFlexibleTopAppBar) {
      // [P1] headlineMedium→headlineSmall 子树覆写：展开大标题 28→24dp
      return _largeTitleThemeOverride(
        context,
        SliverAppBar.large(
          automaticallyImplyLeading: false,
          title: widget.title,
          actions: styledActions,
          titleSpacing: widget.titleSpacing,
          bottom: widget.bottom,
          surfaceTintColor: cs.surfaceContainer,
          systemOverlayStyle: overlay,
        ),
      );
    }
    return SliverAppBar(
      pinned: true,
      automaticallyImplyLeading: false,
      title: widget.title,
      actions: styledActions,
      titleSpacing: widget.titleSpacing,
      bottom: widget.bottom,
      surfaceTintColor: cs.surfaceContainer,
      systemOverlayStyle: overlay,
    );
  }
}

/// 静态标题根页的可折叠 LargeTitle 装配（NestedScrollView）
///
/// body 保持原滚动结构不变（内层 ListView/CustomScrollView 均可），
/// 头部为 SliverAppBar.large。用于「我的」等无复杂顶栏状态的根页。
class LegadoLargeTitleScroll extends StatefulWidget {
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
  State<LegadoLargeTitleScroll> createState() => _LegadoLargeTitleScrollState();
}

class _LegadoLargeTitleScrollState extends State<LegadoLargeTitleScroll>
    with _UiSettingsListener {
  @override
  Widget build(BuildContext context) {
    final ui = uiSettingsListenable.value;
    final cs = Theme.of(context).colorScheme;
    final styledActions = TopBarActionStyler.styleActions(
      context,
      widget.actions,
      style: ui.topBarButtonStyle,
      merge: ui.mergeTopBarActions,
    );
    // [P1] headlineMedium→headlineSmall 子树覆写：展开大标题 28→24dp
    return _largeTitleThemeOverride(
      context,
      NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) => [
          if (ui.useFlexibleTopAppBar)
            SliverAppBar.large(
              automaticallyImplyLeading: false,
              title: widget.title,
              actions: styledActions,
              surfaceTintColor: cs.surfaceContainer,
              systemOverlayStyle: _legadoSystemOverlay(context),
            )
          else
            SliverAppBar(
              pinned: true,
              automaticallyImplyLeading: false,
              title: widget.title,
              actions: styledActions,
              surfaceTintColor: cs.surfaceContainer,
              systemOverlayStyle: _legadoSystemOverlay(context),
            ),
        ],
        body: widget.body,
      ),
    );
  }
}
