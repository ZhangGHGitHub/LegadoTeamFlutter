import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/home_screen.dart';

/// Legado 统一顶栏
///
/// 对齐 Android [TitleBar] / 子 Activity `displayHomeAsUp` 语义，并符合 iOS
/// 子页 leading 返回习惯：
///
/// - **主 Tab 内页**（[HomeScreen] 子树）：不显示返回（原版 Fragment 无 Up）
/// - **独立 push 子页**：左侧 iOS 风格返回（[Icons.arrow_back_ios_new]）
/// - **禁止** Material 默认 `automaticallyImplyLeading` 误注入返回
///
/// 传入 [leading] 时完全尊重调用方（批量模式关闭钮、文件浏览上级等）。
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
      icon: const Icon(Icons.arrow_back_ios_new),
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      onPressed: () => Navigator.maybePop(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppBar(
      leading: _buildLeading(context),
      automaticallyImplyLeading: false,
      title: title,
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
      systemOverlayStyle: systemOverlayStyle,
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
