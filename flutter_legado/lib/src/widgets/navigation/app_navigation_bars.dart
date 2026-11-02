import 'dart:io' show File;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/main_tab.dart';
import '../../services/bottom_bar_skin_service.dart';
import '../../services/nav_icon_store.dart';
/// [UI_SYNC_REFACTOR S1c] 主框架导航组件族（对齐参考仓 ShortNavigationBar/
/// AppNavigationBar/FloatingBottomBar/Rail）
///
/// 三态统一消费底栏皮肤图标：标准栏/悬浮胶囊/Rail 全部走 [SkinNavIcon]；
/// Rail 头部对齐参考：搜索钮（折叠态 ExpandedFAB 等效）+ 书架分组菜单
///（参考为 Rail 项长按菜单，本地交互等效为入口钮，登记差异）+ 展开切换
///（railExtended 持久化）。

/// 导航项规格（图标/文案/皮肤槽位/自定义图标）
///
/// [customIconPath] / [customSelectedIconPath] 对齐参考版 navIcon* /
/// navIcon*Selected：非空时优先渲染用户选择的本地图片，缺文件回退皮肤/
/// 内置 symbol（参考版 AsyncImage→AppIcons 回退同口径）。
class AppNavSpec {
  final IconData symbol;
  final String label;
  final String? skinSlot;
  final String customIconPath;
  final String customSelectedIconPath;

  const AppNavSpec({
    required this.symbol,
    required this.label,
    this.skinSlot,
    this.customIconPath = '',
    this.customSelectedIconPath = '',
  });
}

/// 选中态图标路径优先级（参考版 `selectedCustomIconPath.ifEmpty { custom }`）
String navSpecIconPath(AppNavSpec spec, {required bool selected}) =>
    selected && spec.customSelectedIconPath.isNotEmpty
        ? spec.customSelectedIconPath
        : spec.customIconPath;

/// 导航图标（自定义图片 > 底栏皮肤 > 内置 symbol）
class NavSpecIcon extends StatelessWidget {
  final AppNavSpec spec;
  final bool selected;
  final String activeSkin;

  const NavSpecIcon({
    super.key,
    required this.spec,
    required this.selected,
    required this.activeSkin,
  });

  @override
  Widget build(BuildContext context) {
    final custom = navSpecIconPath(spec, selected: selected);
    // [复核 P2-6] 偏好值可能是相对标识 `nav_icons/<sha1>.<ext>`（新）或
    // 旧绝对路径；缺失/未预热时直接回退内置图标，避免 Image.file 反复报错。
    if (custom.isNotEmpty && NavIconStore.isUsableSync(custom)) {
      return Image.file(
        // ignore: avoid_slow_placeholder_io
        File(NavIconStore.resolveSync(custom)),
        width: 24,
        height: 24,
        fit: BoxFit.contain,
        // 读取/解码失败（文件被清理/格式不支持）→ 回退内置图标
        errorBuilder: (_, _, _) => _fallback(),
      );
    }
    return _fallback();
  }

  Widget _fallback() {
    Widget glyph() => Icon(spec.symbol, size: 24, fill: selected ? 1 : 0);
    if (spec.skinSlot == null || activeSkin.isEmpty) return glyph();
    return SkinNavIcon(
      skin: activeSkin,
      slot: spec.skinSlot!,
      selected: selected,
      fallback: glyph(),
    );
  }
}

/// 主导航页签内置图标（参考版 AppIcons.mainDestination 对应项）
IconData mainTabSymbol(MainTab tab) => switch (tab) {
      // [UI_SYNC_REFACTOR S6] 首页页签底栏项（新皮肤槽位，无皮肤回退 symbol）
      MainTab.home => Symbols.home_rounded,
      MainTab.bookshelf => Symbols.menu_book_rounded,
      MainTab.explore => Symbols.explore_rounded,
      // [parity C3 B5] 订阅页签图标改 RSS 选形：参考底栏第 4 项为经典 RSS
      //（左下圆点 + 双弧，量测 ref 01 底栏），原 feed_rounded 为报纸/文档
      // 版式（参考判为「文档图标」），改 rss_feed_rounded 对齐
      MainTab.rss => Symbols.rss_feed_rounded,
      MainTab.my => Symbols.person_rounded,
    };

/// 主导航页签底栏皮肤槽位（沿用既有映射）
String mainTabSkinSlot(MainTab tab) => switch (tab) {
      MainTab.home => 'home_page',
      MainTab.bookshelf => 'bookshelf',
      MainTab.explore => 'home',
      MainTab.rss => 'notes',
      MainTab.my => 'settings',
    };

/// 构造主导航项规格（首页/设置页共用，避免图标与槽位映射两处漂移）
AppNavSpec mainTabNavSpec(
  MainTab tab, {
  String customIconPath = '',
  String customSelectedIconPath = '',
}) =>
    AppNavSpec(
      symbol: mainTabSymbol(tab),
      label: mainTabLabel(tab),
      skinSlot: mainTabSkinSlot(tab),
      customIconPath: customIconPath,
      customSelectedIconPath: customSelectedIconPath,
    );

/// 底栏皮肤图标（缺图回退系统 glyph；原 home_screen 私有件公共化）
class SkinNavIcon extends StatelessWidget {
  final String skin;
  final String slot;
  final bool selected;
  final Widget fallback;

  const SkinNavIcon({
    super.key,
    required this.skin,
    required this.slot,
    required this.selected,
    required this.fallback,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<BottomBarSkinIcons>(
      future: BottomBarSkinService.instance.iconsForSlot(skin, slot),
      builder: (context, snap) {
        final icons = snap.data;
        final path = selected
            ? (icons?.selected ?? icons?.normal)
            : (icons?.normal ?? icons?.selected);
        if (path == null) return fallback;
        final child = Image.file(
          // ignore: avoid_slow_placeholder_io
          File(path),
          width: 24,
          height: 24,
          errorBuilder: (_, _, _) => fallback,
        );
        return child;
      },
    );
  }
}

/// 标准底栏（ShortNavigationBar 等效：label 三档+透明度+皮肤图标）
class AppShortNavigationBar extends StatelessWidget {
  final List<AppNavSpec> specs;
  final int currentIndex;
  final String activeSkin;
  final NavigationDestinationLabelBehavior labelBehavior;
  final double opacity;
  final ValueChanged<int> onSelect;

  const AppShortNavigationBar({
    super.key,
    required this.specs,
    required this.currentIndex,
    required this.activeSkin,
    required this.labelBehavior,
    required this.opacity,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    // Flutter NavigationBar 断言至少 2 项；单页配置不渲染导航栏
    if (specs.length < 2) return const SizedBox.shrink();
    return Opacity(
      opacity: opacity,
      child: NavigationBar(
        labelBehavior: labelBehavior,
        selectedIndex: currentIndex,
        onDestinationSelected: onSelect,
        destinations: [
          for (final spec in specs)
            NavigationDestination(
              icon: _icon(spec, selected: false),
              selectedIcon: _icon(spec, selected: true),
              label: spec.label,
            ),
        ],
      ),
    );
  }

  Widget _icon(AppNavSpec spec, {required bool selected}) {
    return NavSpecIcon(
      spec: spec,
      selected: selected,
      activeSkin: activeSkin,
    );
  }
}

/// 悬浮底栏（64dp Stadium 胶囊；对齐参考 FloatingBottomBar 实色版）
class AppFloatingBottomBar extends StatefulWidget {
  final List<AppNavSpec> specs;
  final int currentIndex;
  final String activeSkin;
  final ValueChanged<int> onSelect;
  final bool useBlur;
  final int blurRadius;
  final int blurAlpha;

  /// 文字档位（对齐参考版 FloatingBottomBarItem：
  /// `showLabel && (alwaysShowLabel || selected)`）。
  /// [NavigationDestinationLabelBehavior.alwaysShow] 全部显示，
  /// [NavigationDestinationLabelBehavior.onlyShowSelected] 仅选中显示，
  /// [NavigationDestinationLabelBehavior.alwaysHide] 纯图标。
  final NavigationDestinationLabelBehavior labelBehavior;

  const AppFloatingBottomBar({
    super.key,
    required this.specs,
    required this.currentIndex,
    required this.activeSkin,
    required this.onSelect,
    required this.useBlur,
    required this.blurRadius,
    required this.blurAlpha,
    required this.labelBehavior,
  });

  @override
  State<AppFloatingBottomBar> createState() => _AppFloatingBottomBarState();
}

class _AppFloatingBottomBarState extends State<AppFloatingBottomBar> {
  int _pressedIndex = -1;

  Widget _icon(int index, {required bool selected}) {
    return NavSpecIcon(
      spec: widget.specs[index],
      selected: selected,
      activeSkin: widget.activeSkin,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.specs.length < 2) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final capsule = Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      height: 64,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(
          alpha: widget.useBlur ? widget.blurAlpha / 255 : 0.85,
        ),
        borderRadius: BorderRadius.circular(32),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.1),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          for (var i = 0; i < widget.specs.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) => setState(() => _pressedIndex = i),
                onTapCancel: () => setState(() => _pressedIndex = -1),
                onTapUp: (_) {
                  setState(() => _pressedIndex = -1);
                  widget.onSelect(i);
                },
                child: Center(
                  child: AnimatedScale(
                    scale: _pressedIndex == i ? 1.08 : 1.0,
                    duration: const Duration(milliseconds: 120),
                    curve: Curves.fastOutSlowIn,
                    child: Builder(
                      builder: (context) {
                        final selected = widget.currentIndex == i;
                        final showLabel = switch (widget.labelBehavior) {
                          NavigationDestinationLabelBehavior.alwaysShow => true,
                          NavigationDestinationLabelBehavior.alwaysHide => false,
                          NavigationDestinationLabelBehavior.onlyShowSelected =>
                            selected,
                        };
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.fastOutSlowIn,
                          width: selected ? 64 : 48,
                          // 文字行需要额外高度；纯图标保持胶囊内 32dp
                          height: showLabel ? 46 : 32,
                          decoration: BoxDecoration(
                            color: selected
                                ? cs.secondaryContainer
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          alignment: Alignment.center,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              AnimatedScale(
                                scale: selected ? 1.15 : 1.0,
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.fastOutSlowIn,
                                child: _icon(i, selected: selected),
                              ),
                              if (showLabel) ...[
                                const SizedBox(height: 1),
                                Text(
                                  widget.specs[i].label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(
                                        fontSize: 10,
                                        height: 1.1,
                                        color: selected
                                            ? cs.onSecondaryContainer
                                            : cs.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    if (widget.useBlur) {
      return SafeArea(
        top: false,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: widget.blurRadius.toDouble(),
              sigmaY: widget.blurRadius.toDouble(),
            ),
            child: capsule,
          ),
        ),
      );
    }
    return SafeArea(top: false, child: capsule);
  }
}

/// 大屏侧栏（WideNavigationRail 简版等效：皮肤图标+头部搜索钮+书架分组
/// 菜单+展开切换 railExtended 持久化）
class AppRailBar extends StatelessWidget {
  final List<AppNavSpec> specs;
  final int currentIndex;
  final String activeSkin;
  final bool extended;
  final ValueChanged<int> onSelect;
  final VoidCallback onToggleExtended;
  final VoidCallback onSearch;

  /// 是否显示导航文字（底栏文字档位=纯图标时隐藏；对齐参考版 Rail
  /// labelVisibilityMode=unlabeled 时 label=null）
  final bool showLabel;

  /// 书架分组菜单（参考 Rail 项长按菜单的入口钮等效；null 隐藏）
  final List<String>? groups;
  final int? selectedGroupIndex;
  final ValueChanged<int>? onGroupSelected;

  const AppRailBar({
    super.key,
    required this.specs,
    required this.currentIndex,
    required this.activeSkin,
    required this.extended,
    required this.onSelect,
    required this.onToggleExtended,
    required this.onSearch,
    this.showLabel = true,
    this.groups,
    this.selectedGroupIndex,
    this.onGroupSelected,
  });

  @override
  Widget build(BuildContext context) {
    // NavigationRail 同样要求 ≥2 项；单页配置不渲染侧栏
    if (specs.length < 2) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    // [复核 P2-4] Flutter 的 `NavigationRail.extended` 强制显示文字标签，
    // 无法在展开态隐藏；文字档位=纯图标时强制折叠（宽度差异已登记），
    // 并隐藏展开切换钮避免无效操作。参考版展开态仍是 label=null 的图标栏。
    final effectiveExtended = showLabel && extended;
    Widget railIcon(AppNavSpec spec, {required bool selected}) {
      return NavSpecIcon(
        spec: spec,
        selected: selected,
        activeSkin: activeSkin,
      );
    }

    return NavigationRail(
      selectedIndex: currentIndex,
      onDestinationSelected: onSelect,
      // 展开态走 extended 侧栏形态；折叠态按文字档位显示 label
      extended: effectiveExtended,
      labelType: !showLabel
          ? NavigationRailLabelType.none
          : (effectiveExtended
              ? NavigationRailLabelType.none
              : NavigationRailLabelType.all),
      leading: Column(
        children: [
          const SizedBox(height: 8),
          // 展开切换（railExtended 持久化；纯图标档位强制折叠，隐藏切换钮）
          if (showLabel)
            IconButton(
              tooltip: effectiveExtended ? '收起侧栏' : '展开侧栏',
              icon: Icon(effectiveExtended
                  ? Symbols.menu_open_rounded
                  : Symbols.menu_rounded),
              onPressed: onToggleExtended,
            ),
          // 头部搜索钮（对齐参考 Rail header 搜索入口）
          IconButton(
            tooltip: '搜索',
            icon: Icon(
              Symbols.search_rounded,
              color: cs.onSurfaceVariant,
            ),
            onPressed: onSearch,
          ),
          // 书架分组菜单（对齐参考 BookshelfRailGroupMenu）
          if (groups != null && groups!.isNotEmpty)
            PopupMenuButton<int>(
              tooltip: '书架分组',
              icon: Icon(
                Symbols.folder_copy_rounded,
                color: cs.onSurfaceVariant,
              ),
              onSelected: onGroupSelected,
              itemBuilder: (context) => [
                for (var i = 0; i < groups!.length; i++)
                  CheckedPopupMenuItem<int>(
                    value: i,
                    checked: selectedGroupIndex == i,
                    child: Text(groups![i]),
                  ),
              ],
            ),
          const SizedBox(height: 8),
        ],
      ),
      destinations: [
        for (final spec in specs)
          NavigationRailDestination(
            icon: railIcon(spec, selected: false),
            selectedIcon: railIcon(spec, selected: true),
            label: Text(spec.label),
          ),
      ],
    );
  }
}
